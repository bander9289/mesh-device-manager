import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../managers/device_manager.dart';
import '../managers/real_mesh_client.dart';
import '../models/mesh_device.dart';
import 'device_details_screen.dart';
import '../models/mesh_group.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  static const int _kUnknownGroupId = -1;
  static const int _kDefaultGroupId = 0xC000;
  @override
  void initState() {
    super.initState();
    // Delay starting BLE scanning until after first frame to avoid build-time notifications
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final dm = context.read<DeviceManager>();
      // Request permissions for Bluetooth and location before scanning
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse
      ].request();
      if (kDebugMode) {
        debugPrint('Permission results: $statuses');
      }
      final ok = statuses.values.every((s) => s.isGranted || s.isLimited);
      if (ok) {
        if (kDebugMode) {
          debugPrint('Permissions ok — starting BLE scan');
        }
        // Ensure we are in real BLE mode on mobile.
        dm.setUseMock(false);
        // Startup behavior:
        // - Scan immediately
        // - Connect to first discovered proxy
        // - Discover group membership for Default + any user-created groups
        // - Then begin periodic scan cycles
        await dm.runStartupDiscovery(
          budget: const Duration(seconds: 10),
          initialScan: const Duration(seconds: 8),
          perGroupDiscoveryWindow: const Duration(milliseconds: 900),
        );
        dm.startPeriodicScanCycles(
            interval: const Duration(minutes: 1),
            scanDuration: const Duration(seconds: 5));
      } else {
        if (kDebugMode) {
          debugPrint('Permissions not ok — starting mock scan');
        }
        // fall back to mock scanning for now
        dm.startMockScanning();
      }
    });
  }

  int _selectedGroupId =
      _kDefaultGroupId; // default to Default (0xC000) on startup
  bool _selectionMode = false;
  final Set<String> _selectedMacs = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // Scan controls: Scan/Stop button
          // Header: group dropdown + trigger + scanning indicator
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: Consumer<DeviceManager>(
                    builder: (context, mgr, _) {
                      if (kDebugMode) {
                        debugPrint(
                            'Dropdown builder groups: ${mgr.groups.map((g) => g.name).join(', ')}');
                      }
                      return DropdownButton<int>(
                        isExpanded: true,
                        hint: const Text('Select group'),
                        value: _selectedGroupId,
                        items: [
                          const DropdownMenuItem<int>(
                              value: _kUnknownGroupId, child: Text('Unknown')),
                          ...mgr.groups.map(
                            (g) => DropdownMenuItem<int>(
                              value: g.id,
                              child: Row(children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Color(g.colorValue),
                                  ),
                                ),
                                Text(
                                    '${g.name} (0x${g.id.toRadixString(16).toUpperCase()})'),
                              ]),
                            ),
                          ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _selectedGroupId = value;
                            _selectionMode = false;
                            _selectedMacs.clear();
                          });
                        },
                      );
                    },
                  ),
                ),
                Consumer<DeviceManager>(builder: (context, mgr, _) {
                  final selectedCount =
                      _selectionMode ? _selectedMacs.length : 0;

                  // Check if at least one device in the target group is ready for mesh operations
                  final targetDevices = _selectionMode
                      ? mgr.devices
                          .where((d) => _selectedMacs.contains(d.macAddress))
                      : mgr.devices.where((d) => d.groupId == _selectedGroupId);

                  // With native mesh plugin, we don't need device connections - just check if plugin is available
                  final hasNativePlugin = mgr.meshClient
                          is PlatformMeshClient &&
                      (mgr.meshClient as PlatformMeshClient).isPluginAvailable;
                  final anyReady = hasNativePlugin ||
                      targetDevices.any((d) =>
                          d.connectionStatus == ConnectionStatus.ready ||
                          d.connectionStatus == ConnectionStatus.connected);

                  final enabled = (_selectionMode
                          ? selectedCount > 0
                          : _selectedGroupId != _kUnknownGroupId) &&
                      anyReady;
                  final tooltip = _selectionMode
                      ? (anyReady
                          ? 'Trigger selected ($selectedCount)'
                          : 'Connecting devices...')
                      : (anyReady
                          ? 'Trigger group (devices may auto-OFF after ~20s)'
                          : 'Waiting for devices to connect...');
                  return IconButton(
                    icon: const Icon(Icons.flash_on),
                    tooltip: tooltip,
                    onPressed: !enabled
                        ? null
                        : () async {
                            if (kDebugMode) {
                              debugPrint(
                                  'DevicesScreen: Trigger pressed - selectionMode=$_selectionMode, selectedCount=${_selectedMacs.length}');
                            }

                            if (_selectionMode) {
                              // SPECIAL CASE: If exactly one device selected, send unicast to test status responses
                              if (_selectedMacs.length == 1) {
                                final mgr = context.read<DeviceManager>();
                                if (mgr.meshClient is PlatformMeshClient) {
                                  // Get the selected device and calculate its unicast address
                                  final device = mgr.devices.firstWhere((d) =>
                                      _selectedMacs.contains(d.macAddress));
                                  final unicastAddr = device.unicastAddress;

                                  if (kDebugMode) {
                                    debugPrint(
                                        'DevicesScreen: UNICAST MODE - Sending to ${device.identifier} (${device.macAddress})');
                                    debugPrint(
                                        '  Calculated unicast address: 0x${unicastAddr.toRadixString(16)}');
                                  }

                                  final success = await (mgr.meshClient
                                          as PlatformMeshClient)
                                      .sendUnicastMessage(unicastAddr, true);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(success
                                          ? 'Unicast to 0x${unicastAddr.toRadixString(16)} - check logs for GenericOnOffStatus'
                                          : 'Failed to send unicast'),
                                      duration: const Duration(seconds: 3),
                                    ),
                                  );
                                  setState(() {
                                    _selectionMode = false;
                                    _selectedMacs.clear();
                                  });
                                  return;
                                }
                              }

                              // Multiple devices: trigger as before
                              final mgr = context.read<DeviceManager>();
                              final macs = mgr.devices
                                  .where((d) =>
                                      _selectedMacs.contains(d.macAddress))
                                  .map((d) => d.macAddress)
                                  .toList();
                              final affected = await mgr.triggerDevices(macs);
                              if (!context.mounted) return;
                              if (affected < 0) {
                                await showDialog<void>(
                                  context: context,
                                  barrierDismissible: true,
                                  builder: (ctx) => AlertDialog(
                                      content: const Text(
                                          'No native mesh plugin found and GATT fallback failed; install the native plugin or test on a desktop with Mock enabled.')),
                                );
                                Future.delayed(
                                    const Duration(milliseconds: 1500), () {
                                  if (context.mounted &&
                                      Navigator.of(context).canPop()) {
                                    Navigator.of(context).pop();
                                  }
                                });
                              } else {
                                await showDialog<void>(
                                  context: context,
                                  barrierDismissible: true,
                                  builder: (ctx) => AlertDialog(
                                      content:
                                          Text('Triggered $affected devices')),
                                );
                                Future.delayed(
                                    const Duration(milliseconds: 1200), () {
                                  if (context.mounted &&
                                      Navigator.of(context).canPop()) {
                                    Navigator.of(context).pop();
                                  }
                                });
                              }
                              setState(() {
                                _selectionMode = false;
                                _selectedMacs.clear();
                              });
                            } else {
                              // Trigger the group as before
                              final mgr = context.read<DeviceManager>();
                              final groupId = _selectedGroupId;
                              final affected = await mgr.triggerGroup(groupId);
                              if (!context.mounted) {
                                return;
                              }
                              if (affected < 0) {
                                await showDialog<void>(
                                  context: context,
                                  barrierDismissible: true,
                                  builder: (ctx) => AlertDialog(
                                      content: const Text(
                                          'No native mesh plugin found and GATT fallback failed; install the native plugin or test on a desktop with Mock enabled.')),
                                );
                                Future.delayed(
                                    const Duration(milliseconds: 1500), () {
                                  if (context.mounted &&
                                      Navigator.of(context).canPop()) {
                                    Navigator.of(context).pop();
                                  }
                                });
                              } else {
                                // Show dialog in the middle for triggered count (group)
                                await showDialog<void>(
                                  context: context,
                                  barrierDismissible: true,
                                  builder: (ctx) => AlertDialog(
                                    content: Text(
                                      '$affected devices confirmed',
                                    ),
                                  ),
                                );
                                Future.delayed(
                                    const Duration(milliseconds: 1200), () {
                                  if (context.mounted &&
                                      Navigator.of(context).canPop()) {
                                    Navigator.of(context).pop();
                                  }
                                });
                              }
                            }
                          },
                  );
                }),
                const SizedBox(width: 8),
                // Active target indicator (group name / selected count)
                Builder(builder: (context2) {
                  final mgr2 = context2.watch<DeviceManager>();
                  final targetLabel = _selectionMode
                      ? 'Selected: ${_selectedMacs.length}'
                      : (_selectedGroupId == _kUnknownGroupId
                          ? 'Unknown'
                          : (() {
                              final matches = mgr2.groups
                                  .where((g) => g.id == _selectedGroupId)
                                  .toList();
                              return matches.isNotEmpty
                                  ? matches.first.name
                                  : 'Group: ${_selectedGroupId.toRadixString(16).toUpperCase()}';
                            })());
                  return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(targetLabel));
                }),
                // Scanning indicator or rescan button
                Consumer<DeviceManager>(builder: (context, mgr, _) {
                  if (mgr.isScanning) {
                    return const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2));
                  }
                  if (mgr.usingMock) return const SizedBox.shrink();
                  return IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Scan now',
                    onPressed: () async {
                      await mgr.scanAndDiscoverGroups(
                        scanDuration: const Duration(seconds: 5),
                        perGroupDiscoveryWindow:
                            const Duration(milliseconds: 1500),
                      );
                    },
                  );
                }),
              ],
            ),
          ),
          Expanded(
            child: Consumer<DeviceManager>(
              builder: (context, manager, _) {
                final devices = (_selectedGroupId == _kUnknownGroupId)
                    ? manager.devices.where((d) => d.groupId == null).toList()
                    : (() {
                        final confirmed = manager
                                .confirmedMembersForGroup(_selectedGroupId) ??
                            <String>{};
                        // Show devices assigned to the group OR confirmed via mesh discovery.
                        return manager.devices
                            .where((d) =>
                                d.groupId == _selectedGroupId ||
                                confirmed.contains(d.macAddress))
                            .toList();
                      })();
                if (devices.isEmpty) {
                  return const Center(child: Text('No devices found'));
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    final mgr = context.read<DeviceManager>();
                    await mgr.scanAndDiscoverGroups(
                      scanDuration: const Duration(seconds: 5),
                      perGroupDiscoveryWindow:
                          const Duration(milliseconds: 1500),
                    );
                    // give the scan a moment to run
                    await Future.delayed(const Duration(milliseconds: 300));
                  },
                  child: ListView.builder(
                    itemCount: devices.length,
                    itemBuilder: (context, i) {
                      final device = devices[i];
                      return ListTile(
                        onLongPress: () {
                          setState(() {
                            _selectionMode = true;
                            _selectedMacs.add(device.macAddress);
                          });
                        },
                        leading: _selectionMode
                            ? Checkbox(
                                value:
                                    _selectedMacs.contains(device.macAddress),
                                onChanged: (v) {
                                  setState(() {
                                    if (v == true) {
                                      _selectedMacs.add(device.macAddress);
                                    } else {
                                      _selectedMacs.remove(device.macAddress);
                                    }
                                  });
                                })
                            : Builder(builder: (context2) {
                                final mgr2 = context2.read<DeviceManager>();
                                int? colorVal;
                                if (device.groupId != null) {
                                  try {
                                    colorVal = mgr2.groups
                                        .firstWhere(
                                            (gg) => gg.id == device.groupId)
                                        .colorValue;
                                  } catch (_) {
                                    colorVal = null;
                                  }
                                }
                                if (colorVal == null &&
                                    _selectedGroupId != _kUnknownGroupId &&
                                    mgr2.isGroupConfirmed(_selectedGroupId)) {
                                  final members = mgr2.confirmedMembersForGroup(
                                      _selectedGroupId);
                                  if (members != null &&
                                      members.contains(device.macAddress)) {
                                    try {
                                      colorVal = mgr2.groups
                                          .firstWhere(
                                              (gg) => gg.id == _selectedGroupId)
                                          .colorValue;
                                    } catch (_) {
                                      colorVal = null;
                                    }
                                  }
                                }
                                final bg = colorVal != null
                                    ? Color(colorVal)
                                    : Colors.grey[400]!;
                                return Stack(children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    margin: const EdgeInsets.only(right: 8),
                                    decoration: BoxDecoration(
                                        shape: BoxShape.circle, color: bg),
                                  ),
                                  if (device.lightOn == true)
                                    Positioned(
                                        right: 0,
                                        bottom: 0,
                                        child: Icon(Icons.lightbulb,
                                            size: 10,
                                            color: Colors.yellow[700])),
                                ]);
                              }),
                        title: Text(device.identifier),
                        subtitle: Text(
                            '${device.hardwareId == 'unknown' ? device.macAddress : device.hardwareId} • ${device.version} • ${device.rssi}dBm'),
                        trailing:
                            Row(mainAxisSize: MainAxisSize.min, children: [
                          if (device.lightOn == true)
                            const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 8),
                          Icon(Icons.battery_std,
                              color: device.batteryPercent == 0
                                  ? Colors.grey
                                  : (device.batteryPercent >= 50
                                      ? Colors.green
                                      : (device.batteryPercent >= 25
                                          ? Colors.orange
                                          : Colors.red))),
                        ]),
                        onTap: () {
                          if (_selectionMode) {
                            setState(() {
                              if (_selectedMacs.contains(device.macAddress)) {
                                _selectedMacs.remove(device.macAddress);
                              } else {
                                _selectedMacs.add(device.macAddress);
                              }
                            });
                            return;
                          }
                          final dm = context.read<DeviceManager>();
                          if (dm.isScanning) {
                            dm.stopScanning(schedulePostScanRefresh: false);
                          }
                          Navigator.of(context).push(MaterialPageRoute(
                              builder: (ctx) =>
                                  DeviceDetailsScreen(device: device)));
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
          if (_selectionMode) _multiSelectBar(context),
        ],
      ),
    );
  }

  Widget _multiSelectBar(BuildContext context) {
    final manager = context.read<DeviceManager>();
    final selected = manager.devices
        .where((d) => _selectedMacs.contains(d.macAddress))
        .toList();
    return Container(
      color: Colors.grey[200],
      padding: const EdgeInsets.all(8),
      child: Row(children: [
        Text('${selected.length} selected'),
        const Spacer(),
        IconButton(
            onPressed: () {
              setState(() {
                _selectionMode = false;
                _selectedMacs.clear();
              });
            },
            icon: const Icon(Icons.close)),
        Row(children: [
          IconButton(
              onPressed: selected.isEmpty
                  ? null
                  : () async {
                      // Create a new group from selected devices
                      if (kDebugMode) {
                        debugPrint(
                            'UI: Create Group pressed; selected=${selected.map((d) => d.macAddress).join(', ')}');
                      }
                      final name = await showDialog<String?>(
                        context: context,
                        builder: (context) {
                          String? value;
                          return AlertDialog(
                            title: const Text('Create Group'),
                            content: TextField(
                                onChanged: (v) => value = v,
                                decoration: const InputDecoration(
                                    hintText: 'Group name (optional)')),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(context, null),
                                  child: const Text('Cancel')),
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, value),
                                  child: const Text('Create')),
                            ],
                          );
                        },
                      );
                      if (name == null) {
                        return;
                      }
                      final created = manager.createGroupFromDevices(selected,
                          name: name.isEmpty ? null : name);
                      setState(() {
                        _selectionMode = false;
                        _selectedMacs.clear();
                      });
                      if (!context.mounted) {
                        return;
                      }
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Group "${created.name}" created')));
                    },
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Create Group'),
          const SizedBox(width: 8),
          IconButton(
              onPressed: selected.isEmpty
                  ? null
                  : () async {
                      // Assign selected devices to the Default group (0xC000)
                      if (selected.isEmpty) {
                        return;
                      }
                      if (kDebugMode) {
                        debugPrint(
                            'UI: Assign Selected to Group ${_selectedGroupId != _kUnknownGroupId ? _selectedGroupId.toRadixString(16) : 'Default'}; selected=${selected.map((d) => d.macAddress).join(', ')}');
                      }
                      // Assign to currently selected group if it's not Unknown; otherwise default group
                      final targetGroupId = _selectedGroupId != _kUnknownGroupId
                          ? _selectedGroupId
                          : 0xC000;
                      MeshGroup? targetGroup;
                      try {
                        targetGroup = manager.groups
                            .firstWhere((g) => g.id == targetGroupId);
                      } catch (_) {
                        targetGroup = null;
                      }
                      targetGroup ??= manager.createGroupFromDevices([],
                          name: targetGroupId == 0xC000 ? 'Default' : null,
                          groupAddress: targetGroupId);
                      manager.moveDevicesToGroup(selected, targetGroup.id);
                      setState(() {
                        _selectionMode = false;
                        _selectedMacs.clear();
                      });
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(
                                'Assigned ${selected.length} devices to ${targetGroup.name}')));
                      }
                    },
              icon: const Icon(Icons.group_add),
              tooltip: 'Assign Selected to Group'),
          const SizedBox(width: 8),
          IconButton(
              onPressed: selected.isEmpty
                  ? null
                  : () async {
                      final mgr = context.read<DeviceManager>();

                      // SPECIAL CASE: If exactly one device selected, send unicast to test status responses
                      if (selected.length == 1 &&
                          mgr.meshClient is PlatformMeshClient) {
                        final device = selected.first;
                        final unicastAddr = device.unicastAddress;

                        if (kDebugMode) {
                          debugPrint(
                              'DevicesScreen: UNICAST MODE - Sending to ${device.identifier} (${device.macAddress})');
                          debugPrint(
                              '  Calculated unicast address: 0x${unicastAddr.toRadixString(16)}');
                        }

                        final success =
                            await (mgr.meshClient as PlatformMeshClient)
                                .sendUnicastMessage(
                          unicastAddr,
                          true,
                          proxyMac:
                              device.macAddress, // Use this device as proxy
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(success
                                ? 'Unicast to 0x${unicastAddr.toRadixString(16)} sent - check logs for GenericOnOffStatus'
                                : 'Failed to send unicast'),
                            duration: const Duration(seconds: 3),
                          ),
                        );
                        setState(() {
                          _selectionMode = false;
                          _selectedMacs.clear();
                        });
                        return;
                      }

                      // Multiple devices: trigger as before
                      final macs = selected.map((d) => d.macAddress).toList();
                      final affected = await mgr.triggerDevices(macs);
                      if (!context.mounted) return;
                      if (affected < 0) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text(
                                'Trigger failed: native plugin not present and GATT fallback failed')));
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('Triggered $affected devices')));
                      }
                      setState(() {
                        _selectionMode = false;
                        _selectedMacs.clear();
                      });
                    },
              icon: const Icon(Icons.flash_on),
              tooltip: 'Trigger Selected'),
          const SizedBox(width: 8),
          if (manager.groups.isNotEmpty)
            PopupMenuButton<int>(
              enabled: selected.isNotEmpty,
              onSelected: (groupId) async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Move Devices'),
                    content: Text(
                        'Move ${selected.length} devices to Group $groupId?'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Move')),
                    ],
                  ),
                );
                if (!context.mounted) {
                  return;
                }
                if (confirmed == true) {
                  manager.moveDevicesToGroup(selected, groupId);
                  setState(() {
                    _selectionMode = false;
                    _selectedMacs.clear();
                  });
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Devices moved')));
                  }
                }
              },
              itemBuilder: (context) {
                final mgr = context.read<DeviceManager>();
                return mgr.groups
                    .map((g) => PopupMenuItem<int>(
                        value: g.id,
                        child: Row(children: [
                          Container(
                              width: 12,
                              height: 12,
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Color(g.colorValue))),
                          Text(
                              'Move to ${g.name} (0x${g.id.toRadixString(16).toUpperCase()})')
                        ])))
                    .toList();
              },
            ),
        ]),
      ]),
    );
  }
}

class DeviceListTile extends StatelessWidget {
  final MeshDevice device;
  const DeviceListTile({required this.device, super.key});
  @override
  Widget build(BuildContext context) {
    // Show connection status with different icons/colors
    Widget statusIcon;
    switch (device.connectionStatus) {
      case ConnectionStatus.connecting:
        statusIcon = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.orange)),
        );
        break;
      case ConnectionStatus.connected:
        statusIcon = const Icon(Icons.sync, color: Colors.blue, size: 20);
        break;
      case ConnectionStatus.ready:
        final batteryColor = device.batteryPercent >= 50
            ? Colors.green
            : device.batteryPercent >= 25
                ? Colors.orange
                : Colors.red;
        statusIcon = Icon(Icons.battery_std, color: batteryColor);
        break;
      case ConnectionStatus.disconnected:
        statusIcon = const Icon(Icons.battery_std, color: Colors.grey);
        break;
    }

    return ListTile(
      title: Text(device.identifier),
      subtitle: Text(
          'HW: ${device.hardwareId} • ${device.version} • RSSI ${device.rssi}dBm'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        statusIcon,
      ]),
    );
  }
}
