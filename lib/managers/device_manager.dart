import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/mesh_device.dart';
import '../models/mesh_group.dart';
import 'mesh_client.dart';
import 'real_mesh_client.dart';
import 'gatt_mesh_client.dart';

class DeviceManager extends ChangeNotifier {
  final List<MeshDevice> _devices = [];
  final List<MeshGroup> _groups = [];
  List<MeshGroup> get groups => List.unmodifiable(_groups);
  List<MeshDevice> get devices => List.unmodifiable(_devices);

  Timer? _timer;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  bool _usingMock = true;
  bool filterMeshOnly = true; // default: only include mesh devices
  Set<String> hardwareIdWhitelist = {}; // optional: only include these hardware IDs (empty => no filter)
  int _nextGroupAddress = 0xC000; // default base group address

  // Simple palette we cycle through for new groups
  static const List<int> _colorPalette = [
    0xFF1E88E5,
    0xFF43A047,
    0xFFF4511E,
    0xFF6A1B9A,
    0xFF00897B,
    0xFFFDD835,
  ];

  late final MeshClient meshClient;
  final Map<int, Set<String>> _confirmedGroupMembers = {};
  Map<String, String>? meshCredentials;

  DeviceManager() {
    meshClient = PlatformMeshClient(
      fallback: GattMeshClient(deviceProvider: () => _devices, fallback: MockMeshClient(() => [])),
    );

    // Ensure a Default group exists at startup so the UI dropdown shows it
    createGroupFromDevices([], name: 'Default', groupAddress: 0xC000);
    if (kDebugMode) {
      debugPrint('DeviceManager initialized: default group ensured');
    }

    // Hard-coded mesh credentials -- replace these with your network/app keys
    // NOTE: This is intentionally hard-coded for field testing. If you need different credentials,
    // update the values here or provide a mechanism to inject them during initialization.
    // Replace these with your provided keys (hex string, lowercase or uppercase allowed)
    final creds = <String, String>{
      'netKey': '78806728531AE9EDC4241E68749219AC',
      'appKey': '5AC5425AA36136F2513436EA29C358D5'
    };
    setMeshCredentials(creds);
  }

  Future<void> setMeshCredentials(Map<String, String> creds) async {
    meshCredentials = creds;
    await meshClient.initialize(creds);
  }

  void startMockScanning() {
    if (_timer != null) { return; }
    // Add some mock devices every second
    if (kDebugMode) debugPrint('startMockScanning: adding mock devices');
    _devices.addAll([
      MeshDevice(
        macAddress: '00:11:22:33:44:55',
        identifier: '33:44:55',
        hardwareId: 'HW-0A3F',
        batteryPercent: 80,
        rssi: -40,
        version: '2.1.3',
        lightOn: false,
      ),
      MeshDevice(
        macAddress: 'AA:BB:CC:DD:EE:FF',
        identifier: 'DD:EE:FF',
        hardwareId: 'HW-0B12',
        batteryPercent: 32,
        rssi: -60,
        version: '1.8.1',
        lightOn: false,
      ),
    ]);
    // Assign Default group only to the first mock device; leave others unassigned
    final defaultGroupId = _groups.isNotEmpty ? _groups.first.id : _nextGroupAddress;
    if (_devices.isNotEmpty) {
      _devices[0].groupId = defaultGroupId; // first device assigned to Default
      // others intentionally left with groupId == null to be visible under 'Unknown'
    }
    if (kDebugMode) debugPrint('startMockScanning: added ${_devices.length} mock devices');
    notifyListeners();
    refreshDeviceLightStates();
  }

  void stopMockScanning() {
    _timer?.cancel();
    _timer = null;
  }

  bool isGroupConfirmed(int groupId) => _confirmedGroupMembers.containsKey(groupId);
  Set<String>? confirmedMembersForGroup(int groupId) => _confirmedGroupMembers[groupId];
  void clearConfirmedGroupMembership(int groupId) {
    _confirmedGroupMembers.remove(groupId);
  }

  void setUseMock(bool useMock) {
    if (_usingMock == useMock) { return; }
    _usingMock = useMock;
    if (_usingMock) {
      stopScanning();
      startMockScanning();
    } else {
      stopMockScanning();
      startBLEScanning();
    }
  }

  bool get usingMock => _usingMock;

  MeshGroup createGroupFromDevices(List<MeshDevice> devices, {String? name, int? groupAddress, int? colorValue}) {
    final id = groupAddress ?? _nextGroupAddress;
    final groupName = name ?? (id == 0xC000 ? 'Default' : 'Group-${_groups.length + 1}');
    final color = colorValue ?? _colorPalette[_groups.length % _colorPalette.length];
    final g = MeshGroup(id: id, name: groupName, colorValue: color);
    _groups.add(g);
    if (kDebugMode) {
      debugPrint('createGroupFromDevices: created group ${g.name} id=${g.id} color=0x${g.colorValue.toRadixString(16)} assigned ${devices.length} devices');
    }
    _nextGroupAddress = (id >= _nextGroupAddress) ? id + 1 : _nextGroupAddress;
    for (final d in devices) {
      final idx = _devices.indexWhere((x) => x.macAddress == d.macAddress);
      if (idx >= 0) {
        _devices[idx].groupId = g.id;
      }
    }
    notifyListeners();
    return g;
  }

  void startBLEScanning({Duration? timeout}) {
    if (_scanSubscription != null) { return; }
    // Clear current devices
    _devices.clear();
    if (kDebugMode) debugPrint('startBLEScanning: starting, cleared devices');
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (kDebugMode) debugPrint('startBLEScanning: got ${results.length} scan results');
      var changed = false;
      for (final r in results) {
        if (filterMeshOnly && !_isMeshAdvertisement(r)) {
          continue;
        }
        final mac = r.device.remoteId.toString();
        final identifier = (r.device.platformName.isNotEmpty)
          ? r.device.platformName
          : (mac.length >= 8 ? mac.substring(mac.length - 8) : mac);
        // Extract hardwareId from manufacturerData if present
        String hw = 'unknown';
        int battery = -1;
        if (r.advertisementData.manufacturerData.isNotEmpty) {
          final entry = r.advertisementData.manufacturerData.entries.first;
          hw = entry.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
          // try to decode a battery byte if length >=1
          if (entry.value.isNotEmpty) {
            battery = entry.value.first;
          }
        }
        final version = r.advertisementData.serviceUuids.isNotEmpty
            ? r.advertisementData.serviceUuids.join(',')
            : '';
        final device = MeshDevice(
          macAddress: mac,
          identifier: identifier,
          hardwareId: hw,
          batteryPercent: battery < 0 ? 0 : battery,
          rssi: r.rssi,
          version: version,
          lightOn: false,
        );
        // Apply optional hardware whitelist filter
        if (hardwareIdWhitelist.isNotEmpty && !hardwareIdWhitelist.contains(device.hardwareId)) {
          continue;
        }
        final idx = _devices.indexWhere((d) => d.macAddress == mac);
        if (idx >= 0) {
          final existing = _devices[idx];
          // update rssi and battery
          if (existing.rssi != device.rssi || existing.batteryPercent != device.batteryPercent) {
            _devices[idx] = MeshDevice(
              macAddress: existing.macAddress,
              identifier: existing.identifier,
              hardwareId: device.hardwareId,
              batteryPercent: device.batteryPercent,
              rssi: device.rssi,
              version: device.version,
              groupId: existing.groupId,
              lightOn: existing.lightOn,
            );
            changed = true;
            if (kDebugMode) {
              debugPrint('Updated device $mac rssi=${device.rssi} battery=${device.batteryPercent}');
            }
          }
        } else {
          _devices.add(device);
          if (kDebugMode) {
            debugPrint('Added new device $mac id=$identifier hw=$hw rssi=${r.rssi}');
          }
          changed = true;
        }
      }
      if (changed) notifyListeners();
    });
    FlutterBluePlus.startScan(timeout: timeout ?? const Duration(seconds: 10));
  }

  bool _isMeshAdvertisement(ScanResult r) {
    // 1) Mesh Proxy / Provisioning service UUIDs (provisioned/unprovisioned)
    final uuids = r.advertisementData.serviceUuids.map((u) => u.toString().toLowerCase()).toList();
    if (uuids.any((u) => u.contains('00001828') || u.contains('00001827') || u.contains('1828') || u.contains('1827'))) {
      if (kDebugMode) {
        debugPrint('Mesh advertisement: service uuid present (${uuids.join(',')})');
      }
      return true;
    }

    // 2) Name heuristic - we brand our devices 'KMv' at the start of the advertised name
    String name = '';
    try {
      final adv = r.advertisementData.advName;
      name = adv.isNotEmpty ? adv : r.device.platformName;
    } catch (_) {
      name = r.device.platformName;
    }
    if (name.isNotEmpty) {
      final nm = name.toLowerCase();
      if (nm.startsWith('kmv')) {
        if (kDebugMode) {
          debugPrint('Mesh advertisement: name starts with KMv: $name');
        }
        return true;
      }
      // also match the hw-version-hash pattern
      final nameRegex = RegExp(r'^[A-Z0-9\-]+-\d+\.\d+\.\d+-[a-f0-9]+\b', caseSensitive: false);
      if (nameRegex.hasMatch(name)) {
        if (kDebugMode) {
          debugPrint('Mesh advertisement: matches firmware pattern: $name');
        }
        return true;
      }
    }

    // 3) Manufacturer data heuristic - fallback: some mesh devices include private bytes
    // Only accept this fallback if it matches a hardware whitelist entry explicitly.
    if (r.advertisementData.manufacturerData.isNotEmpty) {
      try {
        final entry = r.advertisementData.manufacturerData.entries.first;
        final hw = entry.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (kDebugMode) {
          debugPrint('Mesh advertisement: manufacturer data present hw=$hw');
        }
        if (hardwareIdWhitelist.isNotEmpty && hardwareIdWhitelist.contains(hw)) {
          return true;
        }
      } catch (_) {}
    }

    // otherwise, not a mesh device
    return false;
  }

  void stopScanning() {
    _scanSubscription?.cancel();
    _scanSubscription = null;
    FlutterBluePlus.stopScan();
  }

  bool get isScanning => _scanSubscription != null;

  // move devices to group
  void moveDevicesToGroup(List<MeshDevice> devices, int targetGroupId) {
    for (final d in devices) {
      d.groupId = targetGroupId;
    }
    notifyListeners();
  }

  // Trigger group action (mock sending mesh message)
  Future<int> triggerGroup(int groupId) async {
    // Gather all device macs
    final macs = _devices.map((d) => d.macAddress).toList();
    final before = await meshClient.getLightStates(macs);
    // send the group message
    await meshClient.sendGroupMessage(groupId);
    // wait a bit for state to change
    await Future.delayed(const Duration(milliseconds: 600));
    final after = await meshClient.getLightStates(macs);

    final changedMacs = <String>{};
    for (final mac in macs) {
      final b = before[mac] ?? false;
      final a = after[mac] ?? false;
      if (b != a) changedMacs.add(mac);
    }

    if (changedMacs.isEmpty) {
      if (kDebugMode) {
        debugPrint('Triggered group $groupId but no devices changed state');
      }
      return 0;
    }

    // Update device models with new light state and assign group membership
    int count = 0;
    for (var i = 0; i < _devices.length; i++) {
      final d = _devices[i];
      if (changedMacs.contains(d.macAddress)) {
        _devices[i] = MeshDevice(
          macAddress: d.macAddress,
          identifier: d.identifier,
          hardwareId: d.hardwareId,
          batteryPercent: d.batteryPercent,
          rssi: d.rssi,
          version: d.version,
          groupId: groupId,
          lightOn: after[d.macAddress],
        );
        count++;
      } else {
        // Update only light state
        _devices[i] = MeshDevice(
          macAddress: d.macAddress,
          identifier: d.identifier,
          hardwareId: d.hardwareId,
          batteryPercent: d.batteryPercent,
          rssi: d.rssi,
          version: d.version,
          groupId: d.groupId,
          lightOn: after[d.macAddress] ?? d.lightOn,
        );
      }
    }

    // Store confirmed membership
    _confirmedGroupMembers[groupId] = changedMacs;
    notifyListeners();
    if (kDebugMode) {
      debugPrint('Triggered group $groupId: confirmed ${changedMacs.length} devices');
    }
    return count;
  }

  // Probe group membership by triggering and observing responses
  // NOTE: Passive BLE scanning doesn't expose mesh subscription lists.
  // This method is a scaffold: integrate a mesh client to send a Config Model Subscription Get
  // or a Group message and observe model state changes to reliably detect membership.
  Future<List<MeshDevice>> probeGroupMembers(int groupId, {Duration timeout = const Duration(seconds: 3)}) async {
    // Placeholder: in a real implementation, send a mesh group message and observe state changes.
    // For now, return devices that are currently assigned to the group.
    await Future.delayed(timeout);
    final members = _devices.where((d) => d.groupId == groupId).toList();
    if (kDebugMode) {
      debugPrint('probeGroupMembers: found ${members.length} local members for group $groupId (placeholder)');
    }
    return members;
  }

  Future<void> refreshDeviceLightStates() async {
    final macs = _devices.map((d) => d.macAddress).toList();
    final states = await meshClient.getLightStates(macs);
    for (var i = 0; i < _devices.length; i++) {
      final d = _devices[i];
      _devices[i] = MeshDevice(
        macAddress: d.macAddress,
        identifier: d.identifier,
        hardwareId: d.hardwareId,
        batteryPercent: d.batteryPercent,
        rssi: d.rssi,
        version: d.version,
        groupId: d.groupId,
        lightOn: states[d.macAddress] ?? d.lightOn,
      );
    }
    notifyListeners();
  }
}
