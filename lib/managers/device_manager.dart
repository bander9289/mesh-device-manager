import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/mesh_device.dart';
import '../models/mesh_group.dart';
import 'mesh_client.dart';
import 'real_mesh_client.dart';
import 'gatt_mesh_client.dart';
import 'services/ble_scanning_service.dart';
import 'services/group_store.dart';

class DeviceManager extends ChangeNotifier {
  final List<MeshDevice> _devices = [];
  final List<MeshGroup> _groups = [];
  final Map<String, BluetoothDevice> _deviceCache =
      {}; // Cache BluetoothDevice objects from scans
  int _refreshFailureCount = 0; // Track failures for exponential backoff
  bool _isRefreshing = false; // Prevent overlapping refresh operations
  List<MeshGroup> get groups => List.unmodifiable(_groups);
  List<MeshDevice> get devices => List.unmodifiable(_devices);

  Timer? _timer;
  Timer? _stateRefreshTimer;
  Timer? _periodicScanTimer;
  late final BleScanningService _scanningService;
  late final GroupStore _groupStore;
  // Default to real BLE scanning on Android/iOS. Keep mock default elsewhere (desktop/tests).
  bool _usingMock = !(Platform.isAndroid || Platform.isIOS);
  // Scanning filters are stored on _scanningService.

  // Startup discovery + group scan orchestration
  bool _startupDiscoveryCompleted = false;
  bool get startupDiscoveryCompleted => _startupDiscoveryCompleted;
  int? _activeGroupDiscoveryId;
  DateTime? _activeGroupDiscoveryDeadline;
  bool _startupDiscoveryInProgress = false;
  bool _groupDiscoveryInProgress = false;

  late final MeshClient meshClient;
  final Map<int, Set<String>> _confirmedGroupMembers = {};
  // Broadcast stream for mesh GenericOnOffStatus updates (from the native plugin).
  // Used to implement trigger/listen windows without polling.
  final StreamController<_OnOffStatusEvent> _onOffStatusStream =
      StreamController.broadcast();
  StreamSubscription<_OnOffStatusEvent>? _activeTriggerStatusSubscription;
  Timer? _activeTriggerStatusTimer;

  static const Duration _kTriggerStatusMonitorTimeout = Duration(seconds: 40);
  static const Duration _kTriggerQuickAckTimeout = Duration(seconds: 2);

  // UI-selected group id (used for post-scan mesh refresh).
  int _activeUiGroupId = 0xC000;
  bool _postScanMeshRefreshInProgress = false;
  List<int>? _meshDbUnicastsCache;
  DateTime? _meshDbUnicastsCacheTime;
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
    _groupStore = GroupStore(groups: _groups, devices: _devices);
    _scanningService = BleScanningService(
      devices: _devices,
      groups: _groups,
      deviceCache: _deviceCache,
    );

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
      final device = _devices
          .where((d) =>
              d.macAddress.toLowerCase().replaceAll('-', ':') ==
              mac.toLowerCase().replaceAll('-', ':'))
          .firstOrNull;
      if (device != null) {
        device.batteryPercent = battery;
        device.connectionStatus =
            ConnectionStatus.ready; // Battery read means device is fully ready
        notifyListeners();
        if (kDebugMode)
          debugPrint(
              'DeviceManager: updated battery for $mac to $battery% (device ready)');
      }
    });

    platformClient.setSubscriptionReadyCallback((mac) {
      final device = _devices
          .where((d) =>
              d.macAddress.toLowerCase().replaceAll('-', ':') ==
              mac.toLowerCase().replaceAll('-', ':'))
          .firstOrNull;
      if (device != null) {
        device.connectionStatus =
            ConnectionStatus.connected; // Mark as connected
        notifyListeners();
        if (kDebugMode)
          debugPrint(
              'DeviceManager: subscription ready for $mac (waiting for battery)');
      }
      // Refresh device states when subscription is ready
      refreshDeviceLightStates();
    });

    meshClient = platformClient;

    // Set up callback to receive GenericOnOffStatus messages from devices
    platformClient
        .setDeviceStatusCallback((unicastAddress, state, targetState) {
      if (kDebugMode) {
        debugPrint(
            'DeviceManager: Status from device 0x${unicastAddress.toRadixString(16)}: state=$state');
      }
      // Update or create device based on unicast address
      _updateDeviceFromStatus(unicastAddress, state);
      _onOffStatusStream
          .add(_OnOffStatusEvent(unicastAddress: unicastAddress, state: state));
      notifyListeners();
    });

    if (kDebugMode) {
      debugPrint(
          'DeviceManager: Using PlatformMeshClient with GattMeshClient fallback');
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

  /// Called by UI when the user selects a different active group.
  void setActiveUiGroupId(int groupId) {
    _activeUiGroupId = groupId;
  }

  /// Run a short startup discovery phase:
  /// 1) BLE scan until at least one mesh device is found
  /// 2) Connect to that device's Mesh Proxy
  /// 3) For each configured group (Default + user-created), send a GenericOnOffGet
  ///    and treat responders as confirmed members. If a responder is unassigned,
  ///    assign it to the discovered group.
  ///
  /// Total runtime is capped by [budget] (default ~8s).
  Future<void> runStartupDiscovery({
    Duration budget = const Duration(seconds: 10),
    Duration initialScan = const Duration(seconds: 8),
    Duration perGroupDiscoveryWindow = const Duration(milliseconds: 1500),
  }) async {
    if (_usingMock) {
      _startupDiscoveryCompleted = true;
      notifyListeners();
      return;
    }
    if (_startupDiscoveryInProgress) return;
    _startupDiscoveryInProgress = true;

    final deadline = DateTime.now().add(budget);
    try {
      // Start scanning (do not clear devices; we want to preserve assignments across cycles).
      if (!isScanning) {
        startBLEScanning(timeout: initialScan, clearExisting: false);
      }

      // Wait briefly for the first device.
      final firstFound = await _waitForFirstMeshDevice(deadline: deadline);
      if (!firstFound) {
        if (kDebugMode)
          debugPrint(
              'runStartupDiscovery: no devices found before budget expired');
        return;
      }

      // Don't stop scanning immediately on the first match.
      // On busy radios it can take a couple seconds to observe all devices,
      // and stopping early makes it look like only 1/N devices exist.
      if (isScanning) {
        final extra = const Duration(seconds: 2);
        final remaining = deadline.difference(DateTime.now());
        final wait = remaining > extra ? extra : remaining;
        if (wait.inMilliseconds > 0) {
          await Future.delayed(wait);
        }
      }

      // Stop scanning before attempting proxy connection.
      final wasScanning = isScanning;
      if (wasScanning) {
        stopScanning(schedulePostScanRefresh: false);
        await Future.delayed(const Duration(milliseconds: 250));
      }

      // Connect to proxy using the first good candidate.
      final proxyCandidate = _pickProxyCandidateMac();
      if (proxyCandidate == null) {
        if (wasScanning)
          startBLEScanning(
              timeout: const Duration(seconds: 5), clearExisting: false);
        return;
      }
      final proxyOk = await _ensureProxyConnected(proxyCandidate);
      if (!proxyOk) {
        if (wasScanning)
          startBLEScanning(
              timeout: const Duration(seconds: 5), clearExisting: false);
        return;
      }

      // Pull group subscriptions from the mesh database. This is more reliable than
      // waiting for runtime status responses (some nodes may not respond).
      await _refreshGroupMembershipFromMeshDatabase();

      // After proxy is connected, do a brief scan burst to pick up other devices.
      // This prevents us from configuring the proxy filter with only the first device.
      if (!isScanning) {
        startBLEScanning(
            timeout: const Duration(seconds: 2), clearExisting: false);
      }
      await Future.delayed(const Duration(seconds: 2));
      if (isScanning) stopScanning(schedulePostScanRefresh: false);

      // Discover members for each configured group. Default group always first.
      final orderedGroups = _orderedGroupsForDiscovery();
      final multiGroup = orderedGroups.length > 1;
      for (final group in orderedGroups) {
        if (DateTime.now().isAfter(deadline)) break;

        // If user has multiple groups configured, do a brief scan burst before each
        // group discovery to refresh device list / adv data.
        if (multiGroup) {
          if (!isScanning) {
            startBLEScanning(
                timeout: const Duration(seconds: 2), clearExisting: false);
          }
          await Future.delayed(const Duration(milliseconds: 500));
          if (isScanning) stopScanning(schedulePostScanRefresh: false);
          await Future.delayed(const Duration(milliseconds: 150));
        }

        await _discoverAndAssignGroup(group.id,
            window: perGroupDiscoveryWindow);
      }
    } finally {
      _startupDiscoveryInProgress = false;
      _startupDiscoveryCompleted = true;
      notifyListeners();
    }
  }

  /// Start periodic scan cycles (defaults: every minute, scan for 5 seconds).
  void startPeriodicScanCycles({
    Duration interval = const Duration(minutes: 1),
    Duration scanDuration = const Duration(seconds: 5),
  }) {
    if (_usingMock) return;
    _periodicScanTimer?.cancel();
    _periodicScanTimer = Timer.periodic(interval, (_) {
      // Avoid running during the startup discovery window or if a scan is already active.
      if (_startupDiscoveryInProgress) return;
      if (isScanning) return;
      startBLEScanning(timeout: scanDuration, clearExisting: false);
    });
  }

  void stopPeriodicScanCycles() {
    _periodicScanTimer?.cancel();
    _periodicScanTimer = null;
  }

  /// User-triggered rescan that also runs mesh group discovery so devices can be
  /// automatically assigned to groups.
  Future<void> scanAndDiscoverGroups({
    Duration scanDuration = const Duration(seconds: 5),
    Duration perGroupDiscoveryWindow = const Duration(milliseconds: 1500),
  }) async {
    if (_usingMock) return;
    if (_startupDiscoveryInProgress) return;
    if (_groupDiscoveryInProgress) return;
    _groupDiscoveryInProgress = true;

    try {
      // Scan burst to refresh device list/advertisements.
      if (isScanning) stopScanning(schedulePostScanRefresh: false);
      startBLEScanning(timeout: scanDuration, clearExisting: false);
      await Future.delayed(scanDuration);
      if (isScanning) stopScanning(schedulePostScanRefresh: false);

      final proxyCandidate = _pickProxyCandidateMac();
      if (proxyCandidate == null) {
        return;
      }

      // Ensure proxy connection and refresh proxy filter based on all known devices.
      final proxyOk = await _ensureProxyConnected(proxyCandidate);
      if (!proxyOk) {
        return;
      }

      // Sync group membership from mesh DB before doing active discovery.
      await _refreshGroupMembershipFromMeshDatabase();

      final orderedGroups = _orderedGroupsForDiscovery();
      for (final group in orderedGroups) {
        await _discoverAndAssignGroup(group.id,
            window: perGroupDiscoveryWindow);
      }
    } finally {
      _groupDiscoveryInProgress = false;
      notifyListeners();
    }
  }

  bool _isGroupAddress(int address) {
    return _groupStore.isGroupAddress(address);
  }

  void _ensureGroupExists(int groupId) {
    _groupStore.ensureGroupExists(groupId);
  }

  Future<void> _refreshGroupMembershipFromMeshDatabase() async {
    if (meshClient is! PlatformMeshClient) return;
    final pm = meshClient as PlatformMeshClient;
    if (!pm.isPluginAvailable) return;

    final nodes = await pm.getNodeSubscriptions();
    if (nodes.isEmpty) return;

    // Cache mesh DB unicasts so we can configure proxy filter even if a node
    // wasn't seen in the most recent scan burst.
    final dbUnicasts = <int>[];

    final subsByUnicast = <int, Set<int>>{};
    final allGroupsSeen = <int>{};

    for (final n in nodes) {
      final unicast = n['unicastAddress'];
      if (unicast is! int || unicast <= 0) continue;

      dbUnicasts.add(unicast);

      final subsRaw = n['subscriptions'];
      final subs = <int>{};
      if (subsRaw is List) {
        for (final v in subsRaw) {
          if (v is int) subs.add(v);
        }
      }
      subsByUnicast[unicast] = subs;
      allGroupsSeen.addAll(subs.where(_isGroupAddress));
    }

    _meshDbUnicastsCache = dbUnicasts.toSet().toList();
    _meshDbUnicastsCacheTime = DateTime.now();

    // Ensure group definitions exist for all subscribed groups.
    for (final gid in allGroupsSeen) {
      _ensureGroupExists(gid);
    }

    // Apply membership + best-effort primary group assignment.
    for (final d in _devices) {
      final subs = subsByUnicast[d.unicastAddress];
      if (subs == null || subs.isEmpty) continue;

      for (final gid in subs) {
        if (!_isGroupAddress(gid)) continue;
        _confirmedGroupMembers
            .putIfAbsent(gid, () => <String>{})
            .add(d.macAddress);
      }

      if (d.groupId == null) {
        if (subs.contains(0xC000)) {
          d.groupId = 0xC000;
        } else {
          final firstGroup = subs.firstWhere(_isGroupAddress, orElse: () => 0);
          if (firstGroup != 0) d.groupId = firstGroup;
        }
      }
    }

    notifyListeners();
  }

  Future<List<int>> _collectKnownUnicasts(PlatformMeshClient pm) async {
    final fromScan =
        _devices.map((d) => d.unicastAddress).where((u) => u > 0).toList();

    // Prefer cached DB unicasts if fresh; otherwise refresh once.
    final now = DateTime.now();
    final cacheFresh = _meshDbUnicastsCache != null &&
        _meshDbUnicastsCacheTime != null &&
        now.difference(_meshDbUnicastsCacheTime!).inSeconds < 30;

    if (!cacheFresh) {
      try {
        await _refreshGroupMembershipFromMeshDatabase();
      } catch (_) {
        // best-effort
      }
    }

    final fromDb = _meshDbUnicastsCache ?? const <int>[];
    return {...fromScan, ...fromDb}.toList();
  }

  Future<bool> _waitForFirstMeshDevice({required DateTime deadline}) async {
    // Important: FlutterBluePlus scanning stops automatically after the timeout.
    // Keep scanning in short bursts until we see at least one device or budget expires.
    while (DateTime.now().isBefore(deadline)) {
      if (_devices.isNotEmpty) return true;

      // If scan already stopped (timeout elapsed), restart a short burst.
      if (!isScanning) {
        final remainingMs = deadline.difference(DateTime.now()).inMilliseconds;
        final burst = Duration(milliseconds: remainingMs.clamp(500, 2000));
        startBLEScanning(timeout: burst, clearExisting: false);
      }

      await Future.delayed(const Duration(milliseconds: 150));
    }
    return _devices.isNotEmpty;
  }

  String? _pickProxyCandidateMac() {
    if (_devices.isEmpty) return null;
    // Prefer devices whose advertisement suggests Mesh Proxy service.
    final proxy = _devices.firstWhere(
      (d) =>
          d.version.toLowerCase().contains('1828') ||
          d.version.toLowerCase().contains('00001828'),
      orElse: () => _devices.first,
    );
    return proxy.macAddress;
  }

  List<MeshGroup> _orderedGroupsForDiscovery() {
    return _groupStore.orderedGroupsForDiscovery();
  }

  Future<bool> _ensureProxyConnected(String mac) async {
    try {
      if (meshClient is! PlatformMeshClient) return false;
      final pm = meshClient as PlatformMeshClient;
      final allUnicasts = await _collectKnownUnicasts(pm);
      return await pm.ensureProxyConnection(mac, deviceUnicasts: allUnicasts);
    } catch (_) {
      return false;
    }
  }

  Future<void> _discoverAndAssignGroup(int groupId,
      {required Duration window}) async {
    if (meshClient is! PlatformMeshClient) return;
    final pm = meshClient as PlatformMeshClient;

    final allUnicasts = await _collectKnownUnicasts(pm);

    _activeGroupDiscoveryId = groupId;
    _activeGroupDiscoveryDeadline = DateTime.now().add(window);
    _confirmedGroupMembers.putIfAbsent(groupId, () => <String>{});
    notifyListeners();

    try {
      await pm.discoverGroupMembers(groupId, deviceUnicasts: allUnicasts);
      // Wait for status callbacks to arrive.
      await Future.delayed(window);
    } catch (_) {
      // best-effort
    } finally {
      _activeGroupDiscoveryId = null;
      _activeGroupDiscoveryDeadline = null;
      notifyListeners();
    }
  }

  Future<void> setMeshCredentials(Map<String, String> creds) async {
    meshCredentials = creds;
    await meshClient.initialize(creds);
    // Notify listeners after initialization to trigger UI rebuild with updated plugin availability
    notifyListeners();
    if (kDebugMode) {
      if (meshClient is PlatformMeshClient) {
        final available = (meshClient as PlatformMeshClient).isPluginAvailable;
        debugPrint(
            'DeviceManager.setMeshCredentials: mesh initialized, plugin available=$available');
      }
    }
  }

  void startMockScanning() {
    if (_timer != null) {
      return;
    }
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
    final defaultGroupId =
      _groups.isNotEmpty ? _groups.first.id : _groupStore.nextGroupAddress;
    if (_devices.isNotEmpty) {
      _devices[0].groupId = defaultGroupId; // first device assigned to Default
      // others intentionally left with groupId == null to be visible under 'Unknown'
    }
    if (kDebugMode)
      debugPrint('startMockScanning: added ${_devices.length} mock devices');
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

  bool isGroupConfirmed(int groupId) =>
      _confirmedGroupMembers.containsKey(groupId);
  Set<String>? confirmedMembersForGroup(int groupId) =>
      _confirmedGroupMembers[groupId];
  void clearConfirmedGroupMembership(int groupId) {
    _confirmedGroupMembers.remove(groupId);
  }

  void setUseMock(bool useMock) {
    if (_usingMock == useMock) {
      return;
    }
    _usingMock = useMock;
    if (_usingMock) {
      stopPeriodicScanCycles();
      stopScanning(schedulePostScanRefresh: false);
      startMockScanning();
    } else {
      stopMockScanning();
      startBLEScanning();
    }
  }

  bool get usingMock => _usingMock;

  MeshGroup createGroupFromDevices(List<MeshDevice> devices,
      {String? name, int? groupAddress, int? colorValue}) {
    final g = _groupStore.createGroupFromDevices(
      devices,
      name: name,
      groupAddress: groupAddress,
      colorValue: colorValue,
    );
    notifyListeners();
    return g;
  }

  /// Get cached BluetoothDevice by MAC address
  BluetoothDevice? getCachedDevice(String mac) {
    return _scanningService.getCachedDevice(mac);
  }

  void startBLEScanning({Duration? timeout, bool clearExisting = false}) {
    if (_scanningService.isScanning) {
      return;
    }
    _scanningService.start(
      timeout: timeout,
      clearExisting: clearExisting,
      onDevicesChanged: notifyListeners,
    );

    // start periodic state refresh to detect On/Off states via GATT/native
    _stateRefreshTimer?.cancel();
    _stateRefreshTimer = Timer.periodic(_getRefreshInterval(), (_) async {
      try {
        await refreshDeviceLightStates();
        _refreshFailureCount = 0; // Reset on success
      } catch (e) {
        _refreshFailureCount++;
        if (kDebugMode)
          debugPrint('State refresh failed (${_refreshFailureCount}x): $e');
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

  void stopScanning({bool schedulePostScanRefresh = true}) {
    _stateRefreshTimer?.cancel();
    _stateRefreshTimer = null;
    if (_scanningService.isScanning) {
      _scanningService.stop(onDevicesChanged: notifyListeners);
    } else {
      notifyListeners(); // Update UI to remove scanning indicator
    }

    // After each scan cycle, refresh UI state via mesh GenericOnOffGet for the active group.
    // Avoid doing this for internal scan pauses (trigger operations pass schedulePostScanRefresh=false).
    if (schedulePostScanRefresh) {
      _schedulePostScanMeshStateRefresh();
    }
  }

  bool get isScanning => _scanningService.isScanning;

  // move devices to group
  void moveDevicesToGroup(List<MeshDevice> devices, int targetGroupId) {
    _groupStore.moveDevicesToGroup(devices, targetGroupId);
    notifyListeners();
  }

  // Trigger group action (mock sending mesh message)
  Future<int> triggerGroup(int groupId) async {
    // If the user triggers a group, treat it as the active UI group so the next
    // post-scan refresh targets the right devices.
    setActiveUiGroupId(groupId);
    if (kDebugMode)
      debugPrint(
          'DeviceManager.triggerGroup: using meshClient=${meshClient.runtimeType} for group $groupId');

    // CRITICAL: Stop scanning to free up BLE resources for connection attempts
    final wasScanning = isScanning;
    if (wasScanning) {
      if (kDebugMode)
        debugPrint(
            'DeviceManager.triggerGroup: stopping scan to free BLE resources');
      stopScanning(schedulePostScanRefresh: false);
      await Future.delayed(
          const Duration(milliseconds: 500)); // Allow BLE stack to cleanup
    }

    try {
      if (meshClient is PlatformMeshClient) {
        final pm = meshClient as PlatformMeshClient;
        if (!pm.isPluginAvailable && (Platform.isAndroid || Platform.isIOS)) {
          if (kDebugMode)
            debugPrint(
                'DeviceManager.triggerGroup: no native mesh plugin available on mobile; GATT fallback will be used');
        }
      }
      // Gather all device macs
      final macs = _devices.map((d) => d.macAddress).toList();
      // send the group message for members of the group. Pass specific MACs so native
      // implementation can target toggles reliably.
      final groupMemberMacs = _devices
          .where((d) => d.groupId == groupId)
          .map((d) => d.macAddress)
          .toList();
      if (kDebugMode)
        debugPrint(
            'DeviceManager.triggerGroup: group $groupId members=${groupMemberMacs.length} macs=${groupMemberMacs.join(',')}');
      bool pluginHandled = false;
      if (meshClient is PlatformMeshClient) {
        try {
          pluginHandled = await (meshClient as PlatformMeshClient)
              .sendGroupMessageWithStatus(groupId, groupMemberMacs);
        } catch (_) {
          try {
            await meshClient.sendGroupMessage(groupId, groupMemberMacs);
          } catch (_) {}
        }
      } else {
        await meshClient.sendGroupMessage(groupId, groupMemberMacs);
      }

      // If native mesh plugin handled the PDU, do NOT poll via GenericOnOffGet.
      // Instead listen for GenericOnOffStatus for up to 30s (or until all targets
      // have reported ON then OFF).
      if (pluginHandled && meshClient is PlatformMeshClient) {
        if (kDebugMode)
          debugPrint(
              'DeviceManager.triggerGroup: native mesh PDU sent, listening for status callbacks');
        final targetMacs = groupMemberMacs.toSet();

        // Keep a background monitor window for ON->OFF completion without blocking the UI.
        unawaited(_awaitOnOffStatusWindow(
          targetMacs: targetMacs,
          timeout: _kTriggerStatusMonitorTimeout,
          completion: _OnOffWindowCompletion.onThenOff,
          exclusive: false,
        ).then((res) {
          if (kDebugMode) {
            debugPrint(
                'DeviceManager.triggerGroup: monitor done responded=${res.responded.length}/${targetMacs.length}, completedAll=${res.completedAllTargets}');
          }
        }));

        // For UX: wait briefly for any first status responses, then return.
        final quick = await _awaitOnOffStatusWindow(
          targetMacs: targetMacs,
          timeout: _kTriggerQuickAckTimeout,
          completion: _OnOffWindowCompletion.anyStatus,
          exclusive: true,
        );
        if (quick.responded.isNotEmpty) {
          return quick.responded.length;
        }
        // No quick status responses yet; still consider the trigger sent.
        return targetMacs.length;
      }

      // For fallback (GATT), check state changes
      // wait a bit for state to change
      final before = await meshClient.getLightStates(macs);
      await Future.delayed(const Duration(seconds: 1));
      final after = await meshClient.getLightStates(macs);

      final changedMacs = <String>{};
      if (kDebugMode)
        debugPrint(
            'DeviceManager.triggerGroup: before states=${before.entries.map((e) => '${e.key}:${e.value}').join(',')}');
      if (kDebugMode)
        debugPrint(
            'DeviceManager.triggerGroup: after states=${after.entries.map((e) => '${e.key}:${e.value}').join(',')}');
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
            if (kDebugMode)
              debugPrint(
                  'triggerGroup: platform native plugin unavailable and fallback produced no changes');
            return -1; // signal that group trigger did not succeed due to missing native implementation
          }
          // Plugin was available and handled PDU, but no devices changed state — attempt plugin-side GATT writes
          if (pluginHandled && (Platform.isAndroid || Platform.isIOS)) {
            if (kDebugMode)
              debugPrint(
                  'triggerGroup: plugin handled PDU but no state change observed — trying plugin GATT writes then GATT fallback');
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
                final services =
                    (svc['services'] as List).cast<Map<String, dynamic>>();
                // 1) match vendor candidates
                for (final s in services) {
                  final chars = (s['characteristics'] as List)
                      .cast<Map<String, dynamic>>();
                  for (final c in chars) {
                    final uuid = (c['uuid'] as String).toLowerCase();
                    for (final cand in candidateUuids) {
                      if (uuid.contains(
                              cand.replaceAll('-', '').toLowerCase()) ||
                          uuid == cand.toLowerCase()) {
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
                    final chars = (s['characteristics'] as List)
                        .cast<Map<String, dynamic>>();
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
                    final chars = (s['characteristics'] as List)
                        .cast<Map<String, dynamic>>();
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
                try {
                  cur = await pm.readCharacteristic(mac, targetUuid);
                } catch (_) {
                  cur = null;
                }
                final isOn = cur != null && cur.isNotEmpty && cur.first == 0x01;
                final newVal = [isOn ? 0x00 : 0x01];
                final ok = await pm.writeCharacteristic(mac, targetUuid, newVal,
                    withResponse: true);
                if (ok) {
                  pluginWroteMacs.add(mac);
                  if (kDebugMode)
                    debugPrint(
                        'triggerGroup: plugin wrote characteristic $targetUuid for $mac');
                }
              } catch (e) {
                if (kDebugMode)
                  debugPrint(
                      'triggerGroup: plugin char write failed for $mac -> $e');
              }
            }
            // If the plugin couldn't perform writes for some members, fallback to direct GATT fallback for those MACs
            final macsToFallback = groupMemberMacs
                .where((m) => !pluginWroteMacs.contains(m))
                .toList();
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
              if (kDebugMode)
                debugPrint(
                    'triggerGroup: GATT fallback also did not change device states');
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
        debugPrint(
            'Triggered group $groupId: confirmed ${changedMacs.length} devices');
      }
      // Auto-subscribe confirmed devices in the group
      try {
        await subscribeGroupDevices(groupId, scanIfDisconnected: false);
      } catch (_) {}
      return count;
    } finally {
      // Restart scanning if it was running before
      if (wasScanning) {
        if (kDebugMode)
          debugPrint('DeviceManager.triggerGroup: restarting scan');
        startBLEScanning(timeout: const Duration(seconds: 20));
      }
    }
  }

  Future<int> triggerDevices(List<String> macAddresses) async {
    if (kDebugMode)
      debugPrint(
          'DeviceManager.triggerDevices: triggering ${macAddresses.length} devices');
    // Similar to triggerGroup: prefer native mesh + status listening when available.
    // Fallback continues to use GATT polling.
    final wasScanning = isScanning;
    if (wasScanning) {
      stopScanning(schedulePostScanRefresh: false);
      await Future.delayed(const Duration(milliseconds: 500));
    }

    try {
      if (meshClient is PlatformMeshClient) {
        final pm = meshClient as PlatformMeshClient;
        if (pm.isPluginAvailable && (Platform.isAndroid || Platform.isIOS)) {
          // Ensure proxy connection using first target MAC.
          final first = macAddresses.first;
          final deviceUnicasts = _devices
              .where((d) => macAddresses.contains(d.macAddress))
              .map((d) => d.unicastAddress)
              .where((u) => u > 0)
              .toList();
          await pm.ensureProxyConnection(first, deviceUnicasts: deviceUnicasts);

          // Send unicast ON; devices are expected to publish ON then OFF.
          for (final mac in macAddresses) {
            final d = _devices.firstWhere((x) => x.macAddress == mac,
                orElse: () => MeshDevice(
                    macAddress: mac,
                    identifier: mac,
                    hardwareId: 'unknown',
                    batteryPercent: 0,
                    rssi: 0,
                    version: '',
                    lightOn: false));
            final ok = await pm.sendUnicastMessage(d.unicastAddress, true);
            if (kDebugMode)
              debugPrint(
                  'DeviceManager.triggerDevices: unicast set to 0x${d.unicastAddress.toRadixString(16)} ok=$ok');
            await Future.delayed(const Duration(milliseconds: 50));
          }

          final targetMacs = macAddresses.toSet();

          unawaited(_awaitOnOffStatusWindow(
            targetMacs: targetMacs,
            timeout: _kTriggerStatusMonitorTimeout,
            completion: _OnOffWindowCompletion.onThenOff,
            exclusive: false,
          ));

          final quick = await _awaitOnOffStatusWindow(
            targetMacs: targetMacs,
            timeout: _kTriggerQuickAckTimeout,
            completion: _OnOffWindowCompletion.anyStatus,
            exclusive: true,
          );
          return quick.responded.isNotEmpty ? quick.responded.length : targetMacs.length;
        }
      }

      // Fallback path (GATT/polling)
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
        if (kDebugMode)
          debugPrint('Triggered devices but no devices changed state');
        if (meshClient is PlatformMeshClient) {
          final pm = meshClient as PlatformMeshClient;
          if (!pm.isPluginAvailable && (Platform.isAndroid || Platform.isIOS)) {
            if (kDebugMode)
              debugPrint(
                  'triggerDevices: platform native plugin unavailable and fallback produced no changes');
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
      if (kDebugMode)
        debugPrint(
            'Triggered devices: confirmed ${changedMacs.length} devices');
      // Auto-subscribe confirmed transient devices (0 group)
      try {
        await subscribeGroupDevices(0, scanIfDisconnected: false);
      } catch (_) {}
      return count;
    } finally {
      if (wasScanning) {
        startBLEScanning(timeout: const Duration(seconds: 20));
      }
    }
  }

  void _schedulePostScanMeshStateRefresh() {
    if (_usingMock) return;
    if (_postScanMeshRefreshInProgress) return;
    // Only meaningful on mobile with native mesh plugin.
    if (!(meshClient is PlatformMeshClient)) return;
    final pm = meshClient as PlatformMeshClient;
    if (!pm.isPluginAvailable) return;

    // Schedule async work without blocking UI thread.
    Future<void>(() async {
      _postScanMeshRefreshInProgress = true;
      try {
        final groupId = _activeUiGroupId;
        if (groupId == -1) return; // Unknown
        final groupDevices =
            _devices.where((d) => d.groupId == groupId).toList();
        if (groupDevices.isEmpty) return;

        // Pick a proxy candidate MAC (prefer confirmed members).
        final confirmed = _confirmedGroupMembers[groupId];
        String proxyMac = groupDevices.first.macAddress;
        if (confirmed != null && confirmed.isNotEmpty) {
          final found = groupDevices.firstWhere(
              (d) => confirmed.contains(d.macAddress),
              orElse: () => groupDevices.first);
          proxyMac = found.macAddress;
        }

        // Ensure proxy connection (and proxy filter) before sending gets.
        final allUnicasts = _devices
            .where((d) => d.unicastAddress > 0)
            .map((d) => d.unicastAddress)
            .toList();
        final proxyOk = await pm.ensureProxyConnection(proxyMac,
            deviceUnicasts: allUnicasts);
        if (!proxyOk) return;
        // Give the BLE stack a brief moment to settle.
        await Future.delayed(const Duration(milliseconds: 250));

        final targetMacs = groupDevices.map((d) => d.macAddress).toSet();
        // Send GenericOnOffGet per device (unicast).
        for (final d in groupDevices) {
          try {
            final ok = await pm.sendUnicastGet(d.unicastAddress, proxyMac: proxyMac);
            if (!ok) {
              // One retry: proxy can drop between ensureProxyConnection and send.
              final reOk = await pm.ensureProxyConnection(proxyMac,
                  deviceUnicasts: allUnicasts);
              if (reOk) {
                await Future.delayed(const Duration(milliseconds: 150));
                await pm.sendUnicastGet(d.unicastAddress, proxyMac: proxyMac);
              }
            }
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 60));
        }

        // Wait briefly for statuses to update the UI; stop early when all responded at least once.
        await _awaitOnOffStatusWindow(
          targetMacs: targetMacs,
          timeout: const Duration(seconds: 8),
          completion: _OnOffWindowCompletion.anyStatus,
        );
      } catch (e) {
        if (kDebugMode) debugPrint('post-scan mesh refresh failed: $e');
      } finally {
        _postScanMeshRefreshInProgress = false;
      }
    });
  }

  Future<_OnOffWindowResult> _awaitOnOffStatusWindow({
    required Set<String> targetMacs,
    required Duration timeout,
    required _OnOffWindowCompletion completion,
    bool exclusive = true,
  }) async {
    StreamSubscription<_OnOffStatusEvent>? subscription;
    Timer? timer;

    // Optionally cancel any existing trigger listener to avoid overlapping windows.
    if (exclusive) {
      await _activeTriggerStatusSubscription?.cancel();
      _activeTriggerStatusTimer?.cancel();
    }

    final progress = <String, _OnOffProgress>{
      for (final mac in targetMacs) mac: _OnOffProgress(),
    };
    final responded = <String>{};
    final completer = Completer<_OnOffWindowResult>();

    bool isDone() {
      switch (completion) {
        case _OnOffWindowCompletion.onThenOff:
          return progress.values.every((p) => p.sawOffAfterOn);
        case _OnOffWindowCompletion.anyStatus:
          return progress.values.every((p) => p.seenAny);
      }
    }

    void finish() {
      if (completer.isCompleted) return;
      final completedAll = isDone();
      completer.complete(_OnOffWindowResult(
          responded: responded, completedAllTargets: completedAll));
    }

    subscription = _onOffStatusStream.stream.listen((evt) {
      // Map status to a device MAC via unicast.
      final idx =
          _devices.indexWhere((d) => d.unicastAddress == evt.unicastAddress);
      if (idx < 0) return;
      final mac = _devices[idx].macAddress;
      if (!targetMacs.contains(mac)) return;

      responded.add(mac);
      final p = progress[mac];
      if (p == null) return;
      p.seenAny = true;
      if (evt.state) {
        p.sawOn = true;
      } else {
        if (p.sawOn) p.sawOffAfterOn = true;
      }
      if (isDone()) {
        finish();
      }
    });

    timer = Timer(timeout, () {
      finish();
    });

    if (exclusive) {
      _activeTriggerStatusSubscription = subscription;
      _activeTriggerStatusTimer = timer;
    }

    final res = await completer.future;
    await subscription.cancel();
    timer.cancel();

    if (exclusive) {
      _activeTriggerStatusSubscription = null;
      _activeTriggerStatusTimer = null;
    }
    return res;
  }

  Future<void> refreshDeviceLightStates() async {
    // Skip if already refreshing to prevent overlapping operations
    if (_isRefreshing) {
      if (kDebugMode)
        debugPrint('refreshDeviceLightStates: skipping (already in progress)');
      return;
    }

    _isRefreshing = true;
    try {
      final macs = _devices.map((d) => d.macAddress).toList();
      if (macs.isEmpty) return;

      // On mobile with the native mesh plugin, avoid periodic GenericOnOffGet polling.
      // It can race with status callbacks / post-scan refresh and overwrite UI state.
      final bool skipLightPolling = (meshClient is PlatformMeshClient) &&
          (meshClient as PlatformMeshClient).isPluginAvailable;
      final Map<String, bool> states =
          skipLightPolling ? <String, bool>{} : await meshClient.getLightStates(macs);
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
  Future<void> subscribeGroupDevices(int groupId,
      {bool scanIfDisconnected = false}) async {
    final devicesToSub = _devices.where((d) => d.groupId == groupId).toList();
    if (devicesToSub.isEmpty) return;
    if (kDebugMode)
      debugPrint(
          'subscribeGroupDevices: subscribing ${devicesToSub.length} devices in group $groupId');
    for (final d in devicesToSub) {
      final mac = d.macAddress.toLowerCase().replaceAll('-', ':');
      final last = _lastSubscriptionAttempt[mac];
      final now = DateTime.now();
      if (last != null && now.difference(last) < _subscribeCooldown) {
        if (kDebugMode)
          debugPrint('subscribeGroupDevices: skipping $mac (cooldown)');
        continue;
      }
      if (_subscriptionInProgress.contains(mac)) {
        if (kDebugMode)
          debugPrint(
              'subscribeGroupDevices: skipping $mac (already in progress)');
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
          if (rid == mac) {
            isConnected = true;
            break;
          }
        }
      } catch (_) {}
      // Determine if native platform plugin is available which can connect by MAC.
      bool pluginAvailable = false;
      try {
        if (meshClient is PlatformMeshClient) {
          pluginAvailable =
              (meshClient as PlatformMeshClient).isPluginAvailable;
        }
      } catch (_) {}

      if (!isConnected && !scanIfDisconnected && !pluginAvailable) {
        if (kDebugMode)
          debugPrint(
              'subscribeGroupDevices: skipping $mac (not connected; no plugin and scan prevented)');
        continue;
      }
      _subscriptionInProgress.add(mac);
      _lastSubscriptionAttempt[mac] = now;
      try {
        // prefer native plugin subscription when available, which connects by MAC and doesn't require scanning
        if (pluginAvailable) {
          if (kDebugMode)
            debugPrint(
                'subscribeGroupDevices: plugin available — attempting native subscribe for $mac');
          final ok = await meshClient.subscribeToDeviceCharacteristics(
              d.macAddress, _autoSubscribeUuids,
              onNotify: (macAddr, uuid, val) {
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
          if (kDebugMode)
            debugPrint(
                'subscribeGroupDevices: plugin not available — attempting GATT subscribe for $mac (scanIfDisconnected=$scanIfDisconnected)');
          final ok = await meshClient.subscribeToDeviceCharacteristics(
              d.macAddress, _autoSubscribeUuids,
              onNotify: (macAddr, uuid, val) {
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
        if (kDebugMode)
          debugPrint('subscribeGroupDevices: subscribe failed for $mac -> $e');
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
          try {
            pm.removeNativeCharListenersForMac(normalized);
          } catch (_) {}
          try {
            await pm.disconnectDeviceNative(normalized);
          } catch (_) {}
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
      connectionStatus: d.connectionStatus,
    );
    notifyListeners();
  }

  /// Update or create device based on GenericOnOffStatus message received from mesh
  void _updateDeviceFromStatus(int unicastAddress, bool state) {
    if (kDebugMode) {
      debugPrint(
          'DeviceManager: Received status from 0x${unicastAddress.toRadixString(16)}: state=$state');
    }

    // Find device by matching calculated unicast address
    final deviceIndex =
        _devices.indexWhere((d) => d.unicastAddress == unicastAddress);

    if (deviceIndex >= 0) {
      // Update existing device
      final device = _devices[deviceIndex];
      if (kDebugMode) {
        debugPrint(
            'DeviceManager: Matched unicast 0x${unicastAddress.toRadixString(16)} to device ${device.identifier} (${device.macAddress})');
      }
      final now = DateTime.now();
      final activeGroupId = _activeGroupDiscoveryId;
      final activeDeadline = _activeGroupDiscoveryDeadline;

      // During an active discovery window, confirm membership for the active group.
      // Only assign groupId automatically if the device is currently unassigned.
      int? nextGroupId = device.groupId;
      if (activeGroupId != null &&
          activeDeadline != null &&
          now.isBefore(activeDeadline)) {
        final confirmed =
            _confirmedGroupMembers.putIfAbsent(activeGroupId, () => <String>{});
        confirmed.add(device.macAddress);
        if (nextGroupId == null) {
          nextGroupId = activeGroupId;
        }
      }

      _devices[deviceIndex] = MeshDevice(
        macAddress: device.macAddress,
        identifier: device.identifier,
        hardwareId: device.hardwareId,
        batteryPercent: device.batteryPercent,
        rssi: device.rssi,
        version: device.version,
        groupId: nextGroupId,
        lightOn: state,
        connectionStatus: device.connectionStatus,
      );
      notifyListeners();
      // Mark this device as a confirmed member of its assigned group (if assigned).
      final deviceAfter = _devices[deviceIndex];
      if (deviceAfter.groupId != null) {
        final gid = deviceAfter.groupId!;
        final set = _confirmedGroupMembers.putIfAbsent(gid, () => <String>{});
        set.add(deviceAfter.macAddress);
      }
    } else {
      if (kDebugMode) {
        debugPrint(
            'DeviceManager: No device found with unicast 0x${unicastAddress.toRadixString(16)}');
      }
    }
  }

  @override
  void dispose() {
    _activeTriggerStatusTimer?.cancel();
    _activeTriggerStatusSubscription?.cancel();
    _onOffStatusStream.close();
    stopPeriodicScanCycles();
    stopScanning(schedulePostScanRefresh: false);
    stopMockScanning();
    _scanningService.dispose();
    super.dispose();
  }
}

enum _OnOffWindowCompletion { onThenOff, anyStatus }

class _OnOffStatusEvent {
  final int unicastAddress;
  final bool state;
  _OnOffStatusEvent({required this.unicastAddress, required this.state});
}

class _OnOffProgress {
  bool seenAny = false;
  bool sawOn = false;
  bool sawOffAfterOn = false;
}

class _OnOffWindowResult {
  final Set<String> responded;
  final bool completedAllTargets;
  _OnOffWindowResult(
      {required this.responded, required this.completedAllTargets});
}
