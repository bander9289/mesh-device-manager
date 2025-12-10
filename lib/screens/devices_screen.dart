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
  @override
  void initState() {
    super.initState();
    // Delay starting BLE scanning until after first frame to avoid build-time notifications
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final dm = context.read<DeviceManager>();
      // Request permissions for Bluetooth and location before scanning
      final statuses = await [Permission.bluetoothScan, Permission.bluetoothConnect, Permission.locationWhenInUse].request();
      final ok = statuses.values.every((s) => s.isGranted || s.isLimited);
      if (ok) {
        dm.startBLEScanning(timeout: const Duration(seconds: 30));
      } else {
        // fall back to mock scanning for now
        dm.startMockScanning();
      }
    });
  }

  int? _selectedGroupId;
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
                    if (kDebugMode) debugPrint('Dropdown builder groups: ${mgr.groups.map((g) => g.name).join(', ')}');
                    return DropdownButton<int?>(
                      isExpanded: true,
                      hint: const Text('Select group'),
                      value: _selectedGroupId,
                      items: [
                        const DropdownMenuItem<int?>(value: null, child: Text('All')),
                        ...mgr.groups.map((g) => DropdownMenuItem<int?>(
                            value: g.id,
                            child: Row(children: [
                              Container(width: 12, height: 12, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(shape: BoxShape.circle, color: Color(g.colorValue))),
                              Text('${g.name} (0x${g.id.toRadixString(16).toUpperCase()})')
                            ]))),
                      ],
                      onChanged: (int? v) {
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
                  onPressed: _selectedGroupId == null
                    ? null
                    : () async {
                        final mgr = context.read<DeviceManager>();
                        final groupId = _selectedGroupId!;
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Trigger Group'),
                            content: Text('Trigger all devices in Group $groupId?'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Trigger')),
                            ],
                          ),
                        );
                        if (!mounted) return;
                        if (confirmed == true) {
                          final affected = await mgr.triggerGroup(groupId);
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Triggered $affected devices')));
                        }
                      },
                ),
                const SizedBox(width: 8),
                // Scanning indicator
                Consumer<DeviceManager>(builder: (context, mgr, _) {
                  if (!mgr.isScanning) return const SizedBox.shrink();
                  return const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2));
                }),
              ],
            ),
          ),
          Expanded(
            child: Consumer<DeviceManager>(
              builder: (context, manager, _) {
                final devices = manager.devices.where((d) => _selectedGroupId == null ? true : d.groupId == _selectedGroupId).toList();
                if (devices.isEmpty) {
                  return const Center(child: Text('No devices found'));
                }
                return ListView.builder(
                  itemCount: devices.length,
                  itemBuilder: (context, i) => GestureDetector(
                    onLongPress: () => setState(() {
                      _selectionMode = true;
                      _selectedMacs.add(devices[i].macAddress);
                    }),
                    child: ListTile(
                      leading: _selectionMode
                          ? Checkbox(
                              value: _selectedMacs.contains(devices[i].macAddress),
                              onChanged: (v) => setState(() {
                                if (v == true) _selectedMacs.add(devices[i].macAddress); else _selectedMacs.remove(devices[i].macAddress);
                              }),
                            )
                          : (devices[i].groupId != null
                              ? Builder(builder: (context2) {
                                  final mgr2 = context2.read<DeviceManager>();
                                  int? colorVal;
                                  try {
                                    colorVal = mgr2.groups.firstWhere((gg) => gg.id == devices[i].groupId).colorValue;
                                  } catch (_) {
                                    colorVal = null;
                                  }
                                  if (colorVal == null) return const SizedBox.shrink();
                                  return Container(width: 24, height: 24, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(shape: BoxShape.circle, color: Color(colorVal)),);
                                })
                              : null),
                      title: Text(devices[i].identifier),
                      subtitle: Text('HW: ${devices[i].hardwareId} • ${devices[i].version} • RSSI ${devices[i].rssi}dBm'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.battery_std, color: devices[i].batteryPercent >= 50 ? Colors.green : (devices[i].batteryPercent >= 25 ? Colors.orange : Colors.red)),
                      ]),
                      onTap: () {
                        if (_selectionMode) {
                          setState(() {
                            if (_selectedMacs.contains(devices[i].macAddress)) _selectedMacs.remove(devices[i].macAddress); else _selectedMacs.add(devices[i].macAddress);
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
          ElevatedButton(onPressed: selected.isEmpty ? null : () async {
            // Create a new group from selected devices
            if (kDebugMode) debugPrint('UI: Create Group pressed; selected=${selected.map((d) => d.macAddress).join(', ')}');
            final created = manager.createGroupFromDevices(selected);
            setState(() { _selectionMode = false; _selectedMacs.clear(); });
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Group "${created.name}" created')));
          }, child: const Text('Create Group')),
          const SizedBox(width: 8),
          ElevatedButton(onPressed: selected.isEmpty ? null : () async {
            // Assign selected devices to the Default group (0xC000)
            if (selected.isEmpty) return;
            if (kDebugMode) debugPrint('UI: Assign Selected to Default; selected=${selected.map((d) => d.macAddress).join(', ')}');
            // find or create default
            MeshGroup? defaultGroup;
            try { defaultGroup = manager.groups.firstWhere((g) => g.id == 0xC000); } catch (_) { defaultGroup = null; }
            if (defaultGroup == null) defaultGroup = manager.createGroupFromDevices([], name: 'Default', groupAddress: 0xC000);
            manager.moveDevicesToGroup(selected, defaultGroup.id);
            setState(() { _selectionMode = false; _selectedMacs.clear(); });
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Assigned ${selected.length} devices to ${defaultGroup.name}')));
          }, child: const Text('Assign to Default')),
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
              if (!mounted) return;
              if (confirmed == true) {
                manager.moveDevicesToGroup(selected, groupId);
                setState(() { _selectionMode = false; _selectedMacs.clear(); });
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Devices moved')));
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
