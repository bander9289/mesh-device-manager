import 'package:flutter/foundation.dart';

import '../../models/mesh_device.dart';
import '../../models/mesh_group.dart';

class GroupStore {
  GroupStore({
    required List<MeshGroup> groups,
    required List<MeshDevice> devices,
    int nextGroupAddress = 0xC000,
  })  : _groups = groups,
        _devices = devices,
        _nextGroupAddress = nextGroupAddress;

  final List<MeshGroup> _groups;
  final List<MeshDevice> _devices;
  int _nextGroupAddress;

  int get nextGroupAddress => _nextGroupAddress;

  // Simple palette we cycle through for new groups
  static const List<int> colorPalette = <int>[
    0xFF1E88E5,
    0xFF43A047,
    0xFFF4511E,
    0xFF6A1B9A,
    0xFF00897B,
    0xFFFDD835,
  ];

  bool isGroupAddress(int address) {
    // Standard group address range (0xC000–0xFEFF).
    return address >= 0xC000 && address <= 0xFEFF;
  }

  void ensureGroupExists(int groupId) {
    if (_groups.any((g) => g.id == groupId)) return;

    final groupName = groupId == 0xC000
        ? 'Default'
        : 'Group 0x${groupId.toRadixString(16).toUpperCase()}';
    final color = colorPalette[_groups.length % colorPalette.length];
    _groups.add(MeshGroup(id: groupId, name: groupName, colorValue: color));

    _nextGroupAddress =
        (groupId >= _nextGroupAddress) ? groupId + 1 : _nextGroupAddress;
  }

  List<MeshGroup> orderedGroupsForDiscovery() {
    // Default group (0xC000) first, then all others by creation order.
    final def = _groups.where((g) => g.id == 0xC000).toList();
    final rest = _groups.where((g) => g.id != 0xC000).toList();
    return <MeshGroup>[...def, ...rest];
  }

  MeshGroup createGroupFromDevices(
    List<MeshDevice> devicesToAssign, {
    String? name,
    int? groupAddress,
    int? colorValue,
  }) {
    final id = groupAddress ?? _nextGroupAddress;
    final groupName = name ?? (id == 0xC000 ? 'Default' : 'Group-${_groups.length + 1}');
    final color = colorValue ?? colorPalette[_groups.length % colorPalette.length];

    final g = MeshGroup(id: id, name: groupName, colorValue: color);
    _groups.add(g);

    if (kDebugMode) {
      debugPrint(
        'createGroupFromDevices: created group ${g.name} id=${g.id} color=0x${g.colorValue.toRadixString(16)} assigned ${devicesToAssign.length} devices',
      );
    }

    _nextGroupAddress = (id >= _nextGroupAddress) ? id + 1 : _nextGroupAddress;

    for (final d in devicesToAssign) {
      final idx = _devices.indexWhere((x) => x.macAddress == d.macAddress);
      if (idx >= 0) {
        _devices[idx].groupId = g.id;
      }
    }

    return g;
  }

  void moveDevicesToGroup(List<MeshDevice> devicesToMove, int targetGroupId) {
    for (final d in devicesToMove) {
      final idx = _devices.indexWhere((x) => x.macAddress == d.macAddress);
      if (idx >= 0) {
        final existing = _devices[idx];
        _devices[idx] = MeshDevice(
          macAddress: existing.macAddress,
          identifier: existing.identifier,
          hardwareId: existing.hardwareId,
          batteryPercent: existing.batteryPercent,
          rssi: existing.rssi,
          version: existing.version,
          groupId: targetGroupId,
          lightOn: existing.lightOn,
        );
      }
    }
  }
}
