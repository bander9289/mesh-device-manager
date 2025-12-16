import 'dart:async';
import 'dart:io';
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
  final Map<String, BluetoothDevice> _deviceCache = {}; // Cache BluetoothDevice objects from scans
  int _refreshFailureCount = 0; // Track failures for exponential backoff
  bool _isRefreshing = false; // Prevent overlapping refresh operations
  List<MeshGroup> get groups => List.unmodifiable(_groups);
  List<MeshDevice> get devices => List.unmodifiable(_devices);

  Timer? _timer;
  Timer? _stateRefreshTimer;
  final Map<String, DateTime> _lastAdvertLogTimes = {};
  DateTime? _lastScanResultsLog;
  Timer? _scanCancelTimer;
  bool verboseLogging = false; // toggle to reduce noisy debug output
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
  // subscription throttle: do not attempt to subscribe more often than this per-device
  static const Duration _subscribeCooldown = Duration(seconds: 60);
  final Map<String, DateTime> _lastSubscriptionAttempt = {};
  final Set<String> _subscriptionInProgress = {};
  final Set<String> _pluginSubscribedMacs = {};
  // characteristic UUIDs to subscribe for notifications by default
  static const List<String> _autoSubscribeUuids = [
    '00002a19-0000-1000-8000-00805f9b34fb', // battery
    '0000ff01-0000-1000-8000-00805f9b34fb',
    '0000fff3-0000-1000-8000-00805f9b34fb',
    '0000ff02-0000-1000-8000-00805f9b34fb',
  ];

  DeviceManager() {
    // **IMPORTANT**: BLE Mesh devices don't support direct GATT connections.
    // Use platform mesh client with GATT fallback for BLE mesh communication
    final platformClient = PlatformMeshClient(
      fallback: GattMeshClient(
        deviceProvider: () => _devices,
        isAppScanning: () => FlutterBluePlus.isScanningNow,
      ),
    );
    
    // Set up callbacks for battery updates and subscription ready notifications
    platformClient.setBatteryUpdateCallback((mac, battery) {
      final device = _devices.where((d) => d.macAddress.toLowerCase().replaceAll('-', ':') == mac.toLowerCase().replaceAll('-', ':')).firstOrNull;
      if (device != null) {
        device.batteryPercent = battery;
        device.connectionStatus = ConnectionStatus.ready; // Battery read means device is fully ready
        notifyListeners();
        if (kDebugMode) debugPrint('DeviceManager: updated battery for $mac to $battery% (device ready)');
      }
    });
    
    platformClient.setSubscriptionReadyCallback((mac) {
      final device = _devices.where((d) => d.macAddress.toLowerCase().replaceAll('-', ':') == mac.toLowerCase().replaceAll('-', ':')).firstOrNull;
      if (device != null) {
        device.connectionStatus = ConnectionStatus.connected; // Mark as connected
        notifyListeners();
        if (kDebugMode) debugPrint('DeviceManager: subscription ready for $mac (waiting for battery)');
      }
      // Refresh device states when subscription is ready
      refreshDeviceLightStates();
    });
    
    meshClient = platformClient;
    
    // Set up callback to receive GenericOnOffStatus messages from devices
    if (platformClient is PlatformMeshClient) {
      platformClient.setDeviceStatusCallback((unicastAddress, state, targetState) {
        if (kDebugMode) {
          debugPrint('DeviceManager: Status from device 0x${unicastAddress.toRadixString(16)}: state=$state');
        }
        // Update or create device based on unicast address
        _updateDeviceFromStatus(unicastAddress, state);
        notifyListeners();
      });
    }
    
    if (kDebugMode) {
      debugPrint('DeviceManager: Using PlatformMeshClient with GattMeshClient fallback');
    }

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
    // Notify listeners after initialization to trigger UI rebuild with updated plugin availability
    notifyListeners();
    if (kDebugMode) {
      if (meshClient is PlatformMeshClient) {
        final available = (meshClient as PlatformMeshClient).isPluginAvailable;
        debugPrint('DeviceManager.setMeshCredentials: mesh initialized, plugin available=$available');
      }
    }
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
    _stateRefreshTimer?.cancel();
    _stateRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await refreshDeviceLightStates();
    });
  }

  void stopMockScanning() {
    _timer?.cancel();
    _timer = null;
    _stateRefreshTimer?.cancel();
    _stateRefreshTimer = null;
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

  /// Get cached BluetoothDevice by MAC address
  BluetoothDevice? getCachedDevice(String mac) {
    final normalized = mac.toLowerCase().replaceAll(':', '-');
    return _deviceCache[normalized];
  }

  void startBLEScanning({Duration? timeout}) {
    if (_scanSubscription != null) { return; }
    // Clear current devices but keep cache
    _devices.clear();
    if (kDebugMode) debugPrint('startBLEScanning: starting, cleared devices');
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      if (kDebugMode && results.isNotEmpty) {
        final now = DateTime.now();
        if (_lastScanResultsLog == null || now.difference(_lastScanResultsLog!).inSeconds > 10) {
          _lastScanResultsLog = now;
          debugPrint('startBLEScanning: got ${results.length} scan results');
        }
      }
      var changed = false;
      for (final r in results) {
        if (filterMeshOnly && !_isMeshAdvertisement(r)) {
          continue;
        }
        final mac = r.device.remoteId.toString().toLowerCase().replaceAll('-', ':');
        // Cache the BluetoothDevice object for later use
        final cacheKey = mac.replaceAll(':', '-');
        _deviceCache[cacheKey] = r.device;
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
            if (kDebugMode && verboseLogging) debugPrint('Updated device $mac rssi=${device.rssi} battery=${device.batteryPercent}');
          }
        } else {
          _devices.add(device);
          if (kDebugMode && verboseLogging) debugPrint('Added new device $mac id=$identifier hw=$hw rssi=${r.rssi}');
          changed = true;
        }
      }
      if (changed) notifyListeners();
    });
    final dur = timeout ?? const Duration(seconds: 20);
    FlutterBluePlus.startScan(timeout: dur);
    // Ensure we stop scanning after the duration in case the plugin doesn't automatically
    _scanCancelTimer?.cancel();
    _scanCancelTimer = Timer(dur, () {
      try {
        stopScanning();
      } catch (_) {}
    });
    // start periodic state refresh to detect On/Off states via GATT/native
    _stateRefreshTimer?.cancel();
    _stateRefreshTimer = Timer.periodic(_getRefreshInterval(), (_) async {
      try {
        await refreshDeviceLightStates();
        _refreshFailureCount = 0; // Reset on success
      } catch (e) {
        _refreshFailureCount++;
        if (kDebugMode) debugPrint('State refresh failed (${_refreshFailureCount}x): $e');
      }
    });
    notifyListeners(); // Update UI to show scanning indicator after setup complete
  }

  /// Get refresh interval with exponential backoff on failures
  Duration _getRefreshInterval() {
    // Exponential backoff: 5s, 10s, 20s, 30s (max)
    final seconds = (5 * (1 << _refreshFailureCount.clamp(0, 2))).clamp(5, 30);
    return Duration(seconds: seconds);
  }

  bool _isMeshAdvertisement(ScanResult r) {
    final mac = r.device.remoteId.toString().toLowerCase().replaceAll('-', ':');
    // 1) Mesh Proxy / Provisioning service UUIDs (provisioned/unprovisioned)
    final uuids = r.advertisementData.serviceUuids.map((u) => u.toString().toLowerCase()).toList();
    if (uuids.any((u) => u.contains('00001828') || u.contains('00001827') || u.contains('1828') || u.contains('1827'))) {
      if (_shouldLogAdvert(mac) && kDebugMode && verboseLogging) {
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
        if (_shouldLogAdvert(mac) && kDebugMode && verboseLogging) { debugPrint('Mesh advertisement: name starts with KMv: $name'); }
        return true;
      }
      // also match the hw-version-hash pattern
      final nameRegex = RegExp(r'^[A-Z0-9\-]+-\d+\.\d+\.\d+-[a-f0-9]+\b', caseSensitive: false);
      if (nameRegex.hasMatch(name)) {
        if (_shouldLogAdvert(mac) && kDebugMode && verboseLogging) { debugPrint('Mesh advertisement: matches firmware pattern: $name'); }
        return true;
      }
    }

    // 3) Manufacturer data heuristic - fallback: some mesh devices include private bytes
    // Only accept this fallback if it matches a hardware whitelist entry explicitly.
    if (r.advertisementData.manufacturerData.isNotEmpty) {
      try {
        final entry = r.advertisementData.manufacturerData.entries.first;
        final hw = entry.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        if (_shouldLogAdvert(mac) && kDebugMode && verboseLogging) { debugPrint('Mesh advertisement: manufacturer data present hw=$hw'); }
        if (hardwareIdWhitelist.isNotEmpty && hardwareIdWhitelist.contains(hw)) {
          return true;
        }
      } catch (_) {}
    }

    // otherwise, not a mesh device
    return false;
  }

    bool _shouldLogAdvert(String mac) {
      final now = DateTime.now();
      final last = _lastAdvertLogTimes[mac];
      if (last == null || now.difference(last).inSeconds > 10) {
        _lastAdvertLogTimes[mac] = now;
        return true;
      }
      return false;
    }

  void stopScanning() {
    _scanSubscription?.cancel();
    _scanSubscription = null;
    FlutterBluePlus.stopScan();
    _stateRefreshTimer?.cancel();
    _scanCancelTimer?.cancel();
    _scanCancelTimer = null;
    _stateRefreshTimer = null;
    notifyListeners(); // Update UI to remove scanning indicator
  }

  bool get isScanning => _scanSubscription != null;

  // move devices to group
  void moveDevicesToGroup(List<MeshDevice> devices, int targetGroupId) {
    for (final d in devices) {
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
    notifyListeners();
  }

  // Trigger group action (mock sending mesh message)
  Future<int> triggerGroup(int groupId) async {
    if (kDebugMode) debugPrint('DeviceManager.triggerGroup: using meshClient=${meshClient.runtimeType} for group $groupId');
    
    // CRITICAL: Stop scanning to free up BLE resources for connection attempts
    final wasScanning = isScanning;
    if (wasScanning) {
      if (kDebugMode) debugPrint('DeviceManager.triggerGroup: stopping scan to free BLE resources');
      stopScanning();
      await Future.delayed(const Duration(milliseconds: 500)); // Allow BLE stack to cleanup
    }
    
    try {
      if (meshClient is PlatformMeshClient) {
        final pm = meshClient as PlatformMeshClient;
        if (!pm.isPluginAvailable && (Platform.isAndroid || Platform.isIOS)) {
          if (kDebugMode) debugPrint('DeviceManager.triggerGroup: no native mesh plugin available on mobile; GATT fallback will be used');
        }
      }
      // Gather all device macs
      final macs = _devices.map((d) => d.macAddress).toList();
      final before = await meshClient.getLightStates(macs);
      // send the group message for members of the group. Pass specific MACs so native
      // implementation can target toggles reliably.
      final groupMemberMacs = _devices.where((d) => d.groupId == groupId).map((d) => d.macAddress).toList();
      if (kDebugMode) debugPrint('DeviceManager.triggerGroup: group $groupId members=${groupMemberMacs.length} macs=${groupMemberMacs.join(',')}');
      bool pluginHandled = false;
      if (meshClient is PlatformMeshClient) {
        try {
          pluginHandled = await (meshClient as PlatformMeshClient).sendGroupMessageWithStatus(groupId, groupMemberMacs);
        } catch (_) {
          try { await meshClient.sendGroupMessage(groupId, groupMemberMacs); } catch (_) {}
        }
      } else {
        await meshClient.sendGroupMessage(groupId, groupMemberMacs);
      }
      
      // If native mesh plugin handled the PDU, optimistically toggle the group members
      // BLE Mesh is command-based - we can't query state, so trust the command succeeded
      if (pluginHandled) {
        if (kDebugMode) debugPrint('DeviceManager.triggerGroup: native mesh PDU sent, optimistically toggling ${groupMemberMacs.length} devices');
        for (var i = 0; i < _devices.length; i++) {
          final d = _devices[i];
          if (groupMemberMacs.contains(d.macAddress)) {
            _devices[i] = MeshDevice(
              macAddress: d.macAddress,
              identifier: d.identifier,
              hardwareId: d.hardwareId,
              batteryPercent: d.batteryPercent,
              rssi: d.rssi,
              version: d.version,
              groupId: d.groupId,
              lightOn: !(d.lightOn ?? false), // Toggle state
            );
          }
        }
        _confirmedGroupMembers[groupId] = groupMemberMacs.toSet();
        notifyListeners();
        if (kDebugMode) debugPrint('DeviceManager.triggerGroup: toggled ${groupMemberMacs.length} devices in group $groupId');
        return groupMemberMacs.length;
      }
      
      // For fallback (GATT), check state changes
      // wait a bit for state to change
      await Future.delayed(const Duration(seconds: 1));
      final after = await meshClient.getLightStates(macs);

    final changedMacs = <String>{};
    if (kDebugMode) debugPrint('DeviceManager.triggerGroup: before states=${before.entries.map((e) => '${e.key}:${e.value}').join(',')}');
    if (kDebugMode) debugPrint('DeviceManager.triggerGroup: after states=${after.entries.map((e) => '${e.key}:${e.value}').join(',')}');
    for (final mac in macs) {
      final b = before[mac] ?? false;
      final a = after[mac] ?? false;
      if (b != a) changedMacs.add(mac);
    }

    if (changedMacs.isEmpty) {
      if (kDebugMode) {
        debugPrint('Triggered group $groupId but no devices changed state');
      }
      // If we are on mobile and platform mesh plugin isn't available, return -1
      if (meshClient is PlatformMeshClient) {
        final pm = meshClient as PlatformMeshClient;
        if (!pm.isPluginAvailable && (Platform.isAndroid || Platform.isIOS)) {
          if (kDebugMode) debugPrint('triggerGroup: platform native plugin unavailable and fallback produced no changes');
          return -1; // signal that group trigger did not succeed due to missing native implementation
        }
        // Plugin was available and handled PDU, but no devices changed state — attempt plugin-side GATT writes
        if (pluginHandled && (Platform.isAndroid || Platform.isIOS)) {
          if (kDebugMode) debugPrint('triggerGroup: plugin handled PDU but no state change observed — trying plugin GATT writes then GATT fallback');
          final pluginWroteMacs = <String>{};
          final candidateUuids = [
            '0000ff01-0000-1000-8000-00805f9b34fb',
            '0000fff3-0000-1000-8000-00805f9b34fb',
            '0000ff02-0000-1000-8000-00805f9b34fb',
            '00002a19-0000-1000-8000-00805f9b34fb',
          ];
          for (final mac in groupMemberMacs) {
            try {
              final connected = await pm.isDeviceConnectedNative(mac);
              if (!connected) continue;
              // discover services and pick a candidate characteristic
              final svc = await pm.discoverServices(mac);
              if (svc == null || svc['services'] == null) continue;
              String? targetUuid;
              final services = (svc['services'] as List).cast<Map<String, dynamic>>();
              // 1) match vendor candidates
              for (final s in services) {
                final chars = (s['characteristics'] as List).cast<Map<String, dynamic>>();
                for (final c in chars) {
                  final uuid = (c['uuid'] as String).toLowerCase();
                  for (final cand in candidateUuids) {
                    if (uuid.contains(cand.replaceAll('-', '').toLowerCase()) || uuid == cand.toLowerCase()) {
                      targetUuid = uuid;
                      break;
                    }
                  }
                  if (targetUuid != null) break;
                }
                if (targetUuid != null) break;
              }
              // 2) fallback: pick a writable characteristic
              if (targetUuid == null) {
                for (final s in services) {
                  final chars = (s['characteristics'] as List).cast<Map<String, dynamic>>();
                  for (final c in chars) {
                    if (c['write'] == true) {
                      targetUuid = (c['uuid'] as String).toLowerCase();
                      break;
                    }
                  }
                  if (targetUuid != null) break;
                }
              }
              // 3) fallback: pick a readable characteristic if no writable found
              if (targetUuid == null) {
                for (final s in services) {
                  final chars = (s['characteristics'] as List).cast<Map<String, dynamic>>();
                  for (final c in chars) {
                    if (c['read'] == true) {
                      targetUuid = (c['uuid'] as String).toLowerCase();
                      break;
                    }
                  }
                  if (targetUuid != null) break;
                }
              }
              if (targetUuid == null) continue;
              // read current value if supported
              List<int>? cur;
              try { cur = await pm.readCharacteristic(mac, targetUuid); } catch (_) { cur = null; }
              final isOn = cur != null && cur.isNotEmpty && cur.first == 0x01;
              final newVal = [isOn ? 0x00 : 0x01];
              final ok = await pm.writeCharacteristic(mac, targetUuid, newVal, withResponse: true);
              if (ok) {
                pluginWroteMacs.add(mac);
                if (kDebugMode) debugPrint('triggerGroup: plugin wrote characteristic $targetUuid for $mac');
              }
            } catch (e) {
              if (kDebugMode) debugPrint('triggerGroup: plugin char write failed for $mac -> $e');
            }
          }
          // If the plugin couldn't perform writes for some members, fallback to direct GATT fallback for those MACs
          final macsToFallback = groupMemberMacs.where((m) => !pluginWroteMacs.contains(m)).toList();
          if (macsToFallback.isNotEmpty) {
            try {
              await pm.forceGATTFallbackSend(groupId, macsToFallback);
            } catch (_) {}
          }
          // wait and re-poll states
          await Future.delayed(const Duration(seconds: 1));
          final after2 = await meshClient.getLightStates(macs);
          final changedMacs2 = <String>{};
          for (final mac in macs) {
            final b = before[mac] ?? false;
            final a = after2[mac] ?? false;
            if (b != a) changedMacs2.add(mac);
          }
          if (changedMacs2.isNotEmpty) {
            changedMacs.addAll(changedMacs2);
          }
          if (changedMacs.isEmpty) {
            if (kDebugMode) debugPrint('triggerGroup: GATT fallback also did not change device states');
          }
        }
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
    // Auto-subscribe confirmed devices in the group
    try { await subscribeGroupDevices(groupId, scanIfDisconnected: false); } catch (_) {}
    return count;
    } finally {
      // Restart scanning if it was running before
      if (wasScanning) {
        if (kDebugMode) debugPrint('DeviceManager.triggerGroup: restarting scan');
        startBLEScanning(timeout: const Duration(seconds: 20));
      }
    }
  }

  Future<int> triggerDevices(List<String> macAddresses) async {
    if (kDebugMode) debugPrint('DeviceManager.triggerDevices: triggering ${macAddresses.length} devices');
    final macs = _devices.map((d) => d.macAddress).toList();
    final before = await meshClient.getLightStates(macs);
    await meshClient.sendGroupMessage(0, macAddresses);
    await Future.delayed(const Duration(seconds: 1));
    final after = await meshClient.getLightStates(macs);
    final changedMacs = <String>{};
    for (final mac in macs) {
      final b = before[mac] ?? false;
      final a = after[mac] ?? false;
      if (b != a && macAddresses.contains(mac)) changedMacs.add(mac);
    }
    if (changedMacs.isEmpty) {
      if (kDebugMode) debugPrint('Triggered devices but no devices changed state');
      if (meshClient is PlatformMeshClient) {
        final pm = meshClient as PlatformMeshClient;
        if (!pm.isPluginAvailable && (Platform.isAndroid || Platform.isIOS)) {
          if (kDebugMode) debugPrint('triggerDevices: platform native plugin unavailable and fallback produced no changes');
          return -1;
        }
      }
      return 0;
    }

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
          groupId: d.groupId,
          lightOn: after[d.macAddress],
        );
        count++;
      } else {
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
    _confirmedGroupMembers[0] = changedMacs; // treat 0 as transient group
    notifyListeners();
    if (kDebugMode) debugPrint('Triggered devices: confirmed ${changedMacs.length} devices');
    // Auto-subscribe confirmed transient devices (0 group)
    try { await subscribeGroupDevices(0, scanIfDisconnected: false); } catch (_) {}
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
    // Skip if already refreshing to prevent overlapping operations
    if (_isRefreshing) {
      if (kDebugMode) debugPrint('refreshDeviceLightStates: skipping (already in progress)');
      return;
    }
    
    _isRefreshing = true;
    try {
      final macs = _devices.map((d) => d.macAddress).toList();
      if (macs.isEmpty) return;
      
      final states = await meshClient.getLightStates(macs);
      final batteryLevels = await meshClient.getBatteryLevels(macs);
      for (var i = 0; i < _devices.length; i++) {
        final d = _devices[i];
        _devices[i] = MeshDevice(
          macAddress: d.macAddress,
          identifier: d.identifier,
          hardwareId: d.hardwareId,
          batteryPercent: batteryLevels[d.macAddress] ?? d.batteryPercent,
          rssi: d.rssi,
          version: d.version,
          groupId: d.groupId,
          lightOn: states[d.macAddress] ?? d.lightOn,
        );
      }
      notifyListeners();
    } finally {
      _isRefreshing = false;
    }
  }

  /// Subscribe to candidate characteristics and Battery for all members of the group.
  /// Uses a cooldown to avoid repeated connect attempts.
  Future<void> subscribeGroupDevices(int groupId, {bool scanIfDisconnected = false}) async {
    final devicesToSub = _devices.where((d) => d.groupId == groupId).toList();
    if (devicesToSub.isEmpty) return;
    if (kDebugMode) debugPrint('subscribeGroupDevices: subscribing ${devicesToSub.length} devices in group $groupId');
    for (final d in devicesToSub) {
      final mac = d.macAddress.toLowerCase().replaceAll('-', ':');
      final last = _lastSubscriptionAttempt[mac];
      final now = DateTime.now();
      if (last != null && now.difference(last) < _subscribeCooldown) {
        if (kDebugMode) debugPrint('subscribeGroupDevices: skipping $mac (cooldown)');
        continue;
      }
      if (_subscriptionInProgress.contains(mac)) {
        if (kDebugMode) debugPrint('subscribeGroupDevices: skipping $mac (already in progress)');
        continue;
      }
      // Set device status to connecting
      d.connectionStatus = ConnectionStatus.connecting;
      notifyListeners();
      
      // check connected devices; attempt subscribe directly if device is already connected
      bool isConnected = false;
        try {
            final dynamic con = FlutterBluePlus.connectedDevices;
            List<BluetoothDevice> devicesList = [];
            if (con is Future<List<BluetoothDevice>>) {
              devicesList = await con;
            } else if (con is List<BluetoothDevice>) {
              devicesList = con;
            }
        for (final cd in devicesList) {
          final rid = cd.remoteId.toString().toLowerCase().replaceAll('-', ':');
          if (rid == mac) { isConnected = true; break; }
        }
      } catch (_) {}
      // Determine if native platform plugin is available which can connect by MAC.
      bool pluginAvailable = false;
      try {
        if (meshClient is PlatformMeshClient) {
          pluginAvailable = (meshClient as PlatformMeshClient).isPluginAvailable;
        }
      } catch (_) {}

      if (!isConnected && !scanIfDisconnected && !pluginAvailable) {
        if (kDebugMode) debugPrint('subscribeGroupDevices: skipping $mac (not connected; no plugin and scan prevented)');
        continue;
      }
      _subscriptionInProgress.add(mac);
      _lastSubscriptionAttempt[mac] = now;
      try {
        // prefer native plugin subscription when available, which connects by MAC and doesn't require scanning
        if (pluginAvailable) {
          if (kDebugMode) debugPrint('subscribeGroupDevices: plugin available — attempting native subscribe for $mac');
          final ok = await meshClient.subscribeToDeviceCharacteristics(d.macAddress, _autoSubscribeUuids, onNotify: (macAddr, uuid, val) {
            // battery
            if (uuid.toLowerCase().contains('2a19') && val.isNotEmpty) {
              final percent = val.first & 0xff;
              updateDeviceState(macAddr, batteryPercent: percent);
              return;
            }
            // vendor candidate - if first byte == 0x01 it's on
            if (val.isNotEmpty) {
              final on = val.first == 0x01;
              updateDeviceState(macAddr, lightOn: on);
            }
          }, allowScan: false);
          if (ok && meshClient is PlatformMeshClient) {
            _pluginSubscribedMacs.add(mac);
          }
        } else {
          if (kDebugMode) debugPrint('subscribeGroupDevices: plugin not available — attempting GATT subscribe for $mac (scanIfDisconnected=$scanIfDisconnected)');
          final ok = await meshClient.subscribeToDeviceCharacteristics(d.macAddress, _autoSubscribeUuids, onNotify: (macAddr, uuid, val) {
          // battery
            if (uuid.toLowerCase().contains('2a19') && val.isNotEmpty) {
            final percent = val.first & 0xff;
            updateDeviceState(macAddr, batteryPercent: percent);
            return;
          }
          // vendor candidate - if first byte == 0x01 it's on
          if (val.isNotEmpty) {
            final on = val.first == 0x01;
            updateDeviceState(macAddr, lightOn: on);
          }
          }, allowScan: scanIfDisconnected);
          if (ok && meshClient is PlatformMeshClient) {
            _pluginSubscribedMacs.add(mac);
          }
        }
      } catch (e) {
        if (kDebugMode) debugPrint('subscribeGroupDevices: subscribe failed for $mac -> $e');
      }
      _subscriptionInProgress.remove(mac);
      // stagger to avoid starting many connections simultaneously
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // keep the app scanning state as it was; do not start or stop scans here.
  }

  /// Unsubscribe and close any plugin-managed subscriptions for the given MAC.
  Future<void> unsubscribeDeviceByMac(String mac) async {
    final normalized = mac.toLowerCase().replaceAll('-', ':');
    if (_pluginSubscribedMacs.contains(normalized)) {
      try {
        if (meshClient is PlatformMeshClient) {
          final pm = meshClient as PlatformMeshClient;
          try { pm.removeNativeCharListenersForMac(normalized); } catch (_) {}
          try { await pm.disconnectDeviceNative(normalized); } catch (_) {}
        }
      } catch (_) {}
      _pluginSubscribedMacs.remove(normalized);
    }
  }

  /// Update a device's dynamic state (battery/light) by MAC and notify listeners.
  void updateDeviceState(String mac, {int? batteryPercent, bool? lightOn}) {
    final idx = _devices.indexWhere((d) => d.macAddress == mac);
    if (idx < 0) return;
    final d = _devices[idx];
    _devices[idx] = MeshDevice(
      macAddress: d.macAddress,
      identifier: d.identifier,
      hardwareId: d.hardwareId,
      batteryPercent: batteryPercent ?? d.batteryPercent,
      rssi: d.rssi,
      version: d.version,
      groupId: d.groupId,
      lightOn: lightOn ?? d.lightOn,
    );
    notifyListeners();
  }
  
  /// Update or create device based on GenericOnOffStatus message received from mesh
  void _updateDeviceFromStatus(int unicastAddress, bool state) {
    if (kDebugMode) {
      debugPrint('DeviceManager: Received status from 0x${unicastAddress.toRadixString(16)}: state=$state');
    }
    
    // Find device by matching calculated unicast address
    final deviceIndex = _devices.indexWhere((d) => d.unicastAddress == unicastAddress);
    
    if (deviceIndex >= 0) {
      // Update existing device
      final device = _devices[deviceIndex];
      if (kDebugMode) {
        debugPrint('DeviceManager: Matched unicast 0x${unicastAddress.toRadixString(16)} to device ${device.identifier} (${device.macAddress})');
      }
      _devices[deviceIndex] = MeshDevice(
        macAddress: device.macAddress,
        identifier: device.identifier,
        hardwareId: device.hardwareId,
        batteryPercent: device.batteryPercent,
        rssi: device.rssi,
        version: device.version,
        groupId: device.groupId,
        lightOn: state,
        connectionStatus: device.connectionStatus,
      );
      notifyListeners();
    } else {
      if (kDebugMode) {
        debugPrint('DeviceManager: No device found with unicast 0x${unicastAddress.toRadixString(16)}');
      }
    }
  }
}
