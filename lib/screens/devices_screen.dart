import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../managers/device_manager.dart';
import '../models/mesh_device.dart';
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
      final statuses = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
      if (kDebugMode) debugPrint('Permission results: $statuses');
      final ok = statuses.values.every((s) => s.isGranted || s.isLimited);
      if (ok) {
        if (kDebugMode) debugPrint('Permissions ok — starting BLE scan');
        dm.startBLEScanning(timeout: const Duration(seconds: 30));
      } else {
        if (kDebugMode) debugPrint('Permissions not ok — starting mock scan');
        // fall back to mock scanning for now
        dm.startMockScanning();
      }
    });
  }

  int _selectedGroupId = _kDefaultGroupId; // default to Default group
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
                Expanded(child: Consumer<DeviceManager>(
                  builder: (context, mgr, _) {
                    if (kDebugMode) {
                      debugPrint('Dropdown builder groups: ${mgr.groups.map((g) => g.name).join(', ')}');
                    }
                    return DropdownButton<int>(
                      isExpanded: true,
                          hint: const Text('Select group'),
                          value: _selectedGroupId,
                      items: [
                            const DropdownMenuItem<int>(value: _kUnknownGroupId, child: Text('Unknown')),
                        ...mgr.groups.map((g) => DropdownMenuItem<int>(
                                value: g.id,
                            child: Row(children: [
                              Container(width: 12, height: 12, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(shape: BoxShape.circle, color: Color(g.colorValue))),
                              Text('${g.name} (0x${g.id.toRadixString(16).toUpperCase()})')
                            ]))),
                      ],
                              onChanged: (int? v) {
                                if (v == null) { return; }
                            setState(() => _selectedGroupId = v);
                      },
                    );
                  },
                )),
                const SizedBox(width: 8),
                // Trigger group (icon) - only enabled when a group is selected
                IconButton(
                  icon: const Icon(Icons.flash_on),
                  tooltip: 'Trigger group',
                  onPressed: _selectedGroupId == _kUnknownGroupId
                    ? null
                    : () async {
                        final mgr = context.read<DeviceManager>();
                        final groupId = _selectedGroupId;
                        final affected = await mgr.triggerGroup(groupId);
                        if (!context.mounted) { return; }
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Triggered $affected devices')));
                      },
                ),
                const SizedBox(width: 8),
                // Scanning indicator
                Consumer<DeviceManager>(builder: (context, mgr, _) {
                  if (!mgr.isScanning) {
                    return const SizedBox.shrink();
                  }
                  return const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
                }),
              ],
            ),
          ),
          Expanded(
            child: Consumer<DeviceManager>(
              builder: (context, manager, _) {
                final devices = (_selectedGroupId == _kUnknownGroupId)
                  ? manager.devices.where((d) => d.groupId == null).toList()
                  : (manager.isGroupConfirmed(_selectedGroupId)
                    ? manager.devices.where((d) => manager.confirmedMembersForGroup(_selectedGroupId)?.contains(d.macAddress) ?? false).toList()
                    : manager.devices);
                if (devices.isEmpty) {
                  return const Center(child: Text('No devices found'));
                }
                return ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, i) => GestureDetector(
                    onLongPress: () {
                      setState(() {
                        _selectionMode = true;
                        _selectedMacs.add(devices[i].macAddress);
                      });
                    },
                    child: ListTile(
                      leading: _selectionMode
                          ? Checkbox(
                              value: _selectedMacs.contains(devices[i].macAddress),
                              onChanged: (v) {
                                setState(() {
                                  if (v == true) {
                                    _selectedMacs.add(devices[i].macAddress);
                                  } else {
                                    _selectedMacs.remove(devices[i].macAddress);
                                  }
                                });
                              },
                            )
                          : Builder(builder: (context2) {
                              final mgr2 = context2.read<DeviceManager>();
                              // find group's color if any (favor device.groupId)
                              int? colorVal;
                              if (devices[i].groupId != null) {
                                try { colorVal = mgr2.groups.firstWhere((gg) => gg.id == devices[i].groupId).colorValue; } catch (_) { colorVal = null; }
                              }
                              // if the selected group is confirmed and contains this device, use that group's color
                              if (colorVal == null && _selectedGroupId != _kUnknownGroupId && mgr2.isGroupConfirmed(_selectedGroupId)) {
                                final members = mgr2.confirmedMembersForGroup(_selectedGroupId);
                                if (members != null && members.contains(devices[i].macAddress)) {
                                  try { colorVal = mgr2.groups.firstWhere((gg) => gg.id == _selectedGroupId).colorValue; } catch (_) { colorVal = null; }
                                }
                              }
                              final bg = colorVal != null ? Color(colorVal) : Colors.grey[400]!
                              ;
                              return Stack(children: [
                                Container(width: 28, height: 28, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(shape: BoxShape.circle, color: bg),),
                                if (devices[i].lightOn == true) Positioned(right: 0, bottom: 0, child: Icon(Icons.lightbulb, size: 10, color: Colors.yellow[700])),
                              ]);
                            }),
                      title: Text(devices[i].identifier),
                      subtitle: Text('HW: ${devices[i].hardwareId} • ${devices[i].version} • RSSI ${devices[i].rssi}dBm'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.battery_std, color: devices[i].batteryPercent >= 50 ? Colors.green : (devices[i].batteryPercent >= 25 ? Colors.orange : Colors.red)),
                      ]),
                      onTap: () {
                        if (_selectionMode) {
                          setState(() {
                            if (_selectedMacs.contains(devices[i].macAddress)) {
                              _selectedMacs.remove(devices[i].macAddress);
                            } else {
                              _selectedMacs.add(devices[i].macAddress);
                            }
                          });
                          return;
                        }
                        // Could expand UI
                      },
                    ),
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
    final selected = manager.devices.where((d) => _selectedMacs.contains(d.macAddress)).toList();
    return Container(
      color: Colors.grey[200],
      padding: const EdgeInsets.all(8),
      child: Row(children: [
        Text('${selected.length} selected'),
        const Spacer(),
        IconButton(onPressed: () { setState(() { _selectionMode = false; _selectedMacs.clear(); }); }, icon: const Icon(Icons.close)),
        Row(children: [
          IconButton(onPressed: selected.isEmpty ? null : () async {
            // Create a new group from selected devices
            if (kDebugMode) {
              debugPrint('UI: Create Group pressed; selected=${selected.map((d) => d.macAddress).join(', ')}');
            }
            final name = await showDialog<String?>(
                      context: context,
                      builder: (context) {
                        String? value;
                        return AlertDialog(
                          title: const Text('Create Group'),
                          content: TextField(onChanged: (v) => value = v, decoration: const InputDecoration(hintText: 'Group name (optional)')),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
                            TextButton(onPressed: () => Navigator.pop(context, value), child: const Text('Create')),
                          ],
                        );
                      },
                    );
            if (name == null) { return; }
            final created = manager.createGroupFromDevices(selected, name: name.isEmpty ? null : name);
            setState(() { _selectionMode = false; _selectedMacs.clear(); });
            if (!context.mounted) { return; }
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Group "${created.name}" created')));
          }, icon: const Icon(Icons.add_circle_outline), tooltip: 'Create Group'),
          const SizedBox(width: 8),
          IconButton(onPressed: selected.isEmpty ? null : () async {
            // Assign selected devices to the Default group (0xC000)
            if (selected.isEmpty) { return; }
            if (kDebugMode) {
              debugPrint('UI: Assign Selected to Default; selected=${selected.map((d) => d.macAddress).join(', ')}');
            }
            // find or create default
            MeshGroup? defaultGroup;
            try {
              defaultGroup = manager.groups.firstWhere((g) => g.id == 0xC000);
            } catch (_) {
              defaultGroup = null;
            }
            defaultGroup ??= manager.createGroupFromDevices([], name: 'Default', groupAddress: 0xC000);
            manager.moveDevicesToGroup(selected, defaultGroup.id);
            setState(() { _selectionMode = false; _selectedMacs.clear(); });
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Assigned ${selected.length} devices to ${defaultGroup.name}')));
            }
          }, icon: const Icon(Icons.group_add), tooltip: 'Assign Selected to Default'),
          const SizedBox(width: 8),
          if (manager.groups.isNotEmpty) PopupMenuButton<int>(
            enabled: selected.isNotEmpty,
            onSelected: (groupId) async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Move Devices'),
                  content: Text('Move ${selected.length} devices to Group $groupId?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Move')),
                  ],
                ),
              );
              if (!context.mounted) { return; }
                if (confirmed == true) {
                  manager.moveDevicesToGroup(selected, groupId);
                  setState(() { _selectionMode = false; _selectedMacs.clear(); });
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Devices moved')));
                  }
                }
            },
            itemBuilder: (context) {
              final mgr = context.read<DeviceManager>();
              return mgr.groups.map((g) => PopupMenuItem<int>(value: g.id, child: Row(children: [
                Container(width: 12, height: 12, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(shape: BoxShape.circle, color: Color(g.colorValue))),
                Text('Move to ${g.name} (0x${g.id.toRadixString(16).toUpperCase()})')
              ]))).toList();
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
    final batteryColor = device.batteryPercent >= 50
        ? Colors.green
        : device.batteryPercent >= 25
            ? Colors.orange
            : Colors.red;
    return ListTile(
      title: Text(device.identifier),
      subtitle: Text('HW: ${device.hardwareId} • ${device.version} • RSSI ${device.rssi}dBm'),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.battery_std, color: batteryColor),
      ]),
    );
  }
}
