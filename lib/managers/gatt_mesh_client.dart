import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'mesh_client.dart';
import 'smp_client.dart';
import 'platform_smp_client.dart';
import '../models/mesh_device.dart';
import '../models/update_progress.dart';
import '../utils/mac_address.dart';

/// Basic GATT-based MeshClient fallback. It writes to known candidate characteristics
/// to toggle a light on devices and reads them to determine state. This is not a
/// full mesh implementation but provides a practical fallback when native mesh is unavailable.
class GattMeshClient implements MeshClient {
  List<MeshDevice> Function() deviceProvider;
  final MeshClient? fallback;
  final bool Function()? isAppScanning; // optional provider to determine whether the app is scanning
  final Map<String, StreamSubscription<BluetoothConnectionState>> _connectionStateListeners = {}; // Track connection states
  final Set<String> _connectingDevices = {}; // Track devices currently connecting
  
  // SMP (Simple Management Protocol) client for firmware updates
  late final SMPClient _smpClient;

  // Candidate characteristic UUIDs commonly used for light toggle / vendor features
  static const List<String> _candidateUuids = [
    '0000ff01-0000-1000-8000-00805f9b34fb',
    '0000fff3-0000-1000-8000-00805f9b34fb',
    '0000ff02-0000-1000-8000-00805f9b34fb',
  ];

  GattMeshClient({required this.deviceProvider, this.fallback, this.isAppScanning}) {
    _smpClient = PlatformSMPClient();
  }

  @override
  Future<void> initialize(Map<String, String>? credentials) async {
    // GATT approach doesn't need mesh keys but store if needed by fallback
    await fallback?.initialize(credentials);
  }

  static DateTime? _lastLocalScan;

  Future<BluetoothDevice?> _getDeviceByMac(String mac, {bool allowScan = true}) async {
    final normalizedMac = normalizeMac(mac);
    final normalizedMacNoSep = macNoSeparators(mac);
    
    // 1. First check connected devices
    final dynamic con = FlutterBluePlus.connectedDevices;
    List<BluetoothDevice> devicesList = [];
    if (con is Future<List<BluetoothDevice>>) {
      devicesList = await con;
    } else if (con is List<BluetoothDevice>) {
      devicesList = con;
    }
    try {
      if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: connectedDevices count=${devicesList.length}');
      final connected = devicesList.firstWhere((d) {
        final rid = normalizeMac(d.remoteId.toString());
        final ridNoSep = macNoSeparators(rid);
        return rid == normalizedMac || ridNoSep == normalizedMacNoSep;
      });
      if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: found connected device $mac');
      return connected;
    } catch (_) {}
    
    // 2. Check if app is currently scanning - use existing scan results
    final appScanning = isAppScanning?.call() ?? false;
    if (appScanning || !allowScan) {
      // App is already scanning or we're not allowed to scan - check recent results only
      try {
        final searchAttempts = appScanning ? 10 : 3;
        final stream = FlutterBluePlus.scanResults;
        for (int i = 0; i < searchAttempts; i++) {
          final resList = await stream.first.timeout(
            Duration(milliseconds: appScanning ? 500 : 200), 
            onTimeout: () => <ScanResult>[]
          );
          if (kDebugMode && i == 0) {
            debugPrint('GattMeshClient._getDeviceByMac: scanResults attempt $i size=${resList.length}');
          }
          for (final r in resList) {
            final rid = normalizeMac(r.device.remoteId.toString());
            final ridNoSep = macNoSeparators(rid);
            if (rid == normalizedMac || ridNoSep == normalizedMacNoSep) {
              if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: found in scan results $mac');
              return r.device;
            }
          }
          await Future.delayed(const Duration(milliseconds: 300));
        }
        if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: device $mac not found in existing scan results');
        return null;
      } catch (e) {
        if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: error checking scan results: $e');
        return null;
      }
    }
    
    // 3. Only start dedicated scan if explicitly allowed and app not already scanning
    final now = DateTime.now();
    // Throttle: if last scan started < 8s ago, skip to prevent registration failures
    if (_lastLocalScan != null && now.difference(_lastLocalScan!).inSeconds < 8) {
      if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: skipping dedicated scan (throttled, ${now.difference(_lastLocalScan!).inSeconds}s ago)');
      return null;
    }
    
    try {
      _lastLocalScan = now;
      if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: starting dedicated scan for $mac (3s)');
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 3));
      
      final stream = FlutterBluePlus.scanResults;
      final start = DateTime.now();
      while (DateTime.now().difference(start) < const Duration(seconds: 3)) {
        final resList = await stream.first.timeout(
          const Duration(milliseconds: 400), 
          onTimeout: () => <ScanResult>[]
        );
        for (final r in resList) {
          final rid = normalizeMac(r.device.remoteId.toString());
          final ridNoSep = macNoSeparators(rid);
          if (rid == normalizedMac || ridNoSep == normalizedMacNoSep) {
            try { await FlutterBluePlus.stopScan(); } catch (_) {}
            if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: found in dedicated scan $mac');
            return r.device;
          }
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }
      try { await FlutterBluePlus.stopScan(); } catch (_) {}
    } catch (e) {
      if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: dedicated scan error: $e');
      try { await FlutterBluePlus.stopScan(); } catch (_) {}
    }
    
    if (kDebugMode) debugPrint('GattMeshClient._getDeviceByMac: device $mac not found');
    return null;
  }

  Future<bool> _connectWithRetry(BluetoothDevice device, {int attempts = 2}) async {
    final deviceId = device.remoteId.toString();
    
    // Prevent concurrent connection attempts to same device
    if (_connectingDevices.contains(deviceId)) {
      if (kDebugMode) debugPrint('GattMeshClient._connectWithRetry: already connecting to $deviceId');
      return false;
    }
    
    _connectingDevices.add(deviceId);
    
    try {
      dynamic lastError;
      for (var attempt = 0; attempt < attempts; attempt++) {
        try {
          if (kDebugMode) debugPrint('GattMeshClient._connectWithRetry: connecting attempt ${attempt + 1} to ${device.remoteId}');
          
          // Setup connection state listener before connecting
          final completer = Completer<BluetoothConnectionState>();
          StreamSubscription<BluetoothConnectionState>? stateSubscription;
          bool firstEvent = true;
          
          stateSubscription = device.connectionState.listen((state) {
            if (kDebugMode) debugPrint('GattMeshClient._connectWithRetry: ${device.remoteId} state=$state');
            
            // Skip the first event (initial state) and only complete on state change
            if (firstEvent) {
              firstEvent = false;
              return;
            }
            
            if (!completer.isCompleted) {
              completer.complete(state);
            }
          });
          
          try {
            // Initiate connection with timeout
            await device.connect(timeout: const Duration(seconds: 10), license: License.free);
            
            // Wait for connected state or timeout
            final state = await completer.future.timeout(
              const Duration(seconds: 10),
              onTimeout: () => BluetoothConnectionState.disconnected,
            );
            
            if (state == BluetoothConnectionState.connected) {
              // Store subscription to keep monitoring connection
              _connectionStateListeners[deviceId] = stateSubscription;
              if (kDebugMode) debugPrint('GattMeshClient._connectWithRetry: ✓ Connected to ${device.remoteId}');
              return true;
            } else {
              if (kDebugMode) debugPrint('GattMeshClient._connectWithRetry: ✗ Connection failed, state=$state');
              await stateSubscription.cancel();
              try { await device.disconnect(); } catch (_) {}
            }
          } catch (e) {
            await stateSubscription.cancel();
            rethrow;
          }
        } on TimeoutException catch (e) {
          lastError = e;
          if (kDebugMode) debugPrint('GattMeshClient._connectWithRetry: ✗ Timeout on attempt ${attempt + 1}');
          try { await device.disconnect(); } catch (_) {}
        } catch (e) {
          lastError = e;
          if (kDebugMode) debugPrint('GattMeshClient._connectWithRetry: ✗ Error on attempt ${attempt + 1}: $e');
          try { await device.disconnect(); } catch (_) {}
        }
        
        if (attempt < attempts - 1) {
          await Future.delayed(Duration(milliseconds: 1000 * (attempt + 1)));
        }
      }
      if (kDebugMode) debugPrint('GattMeshClient._connectWithRetry: ✗ Failed to connect to ${device.remoteId} after $attempts attempts -> $lastError');
      return false;
    } finally {
      _connectingDevices.remove(deviceId);
    }
  }

  Future<BluetoothCharacteristic?> _findCharacteristic(BluetoothDevice device) async {
    try {
      if (kDebugMode) debugPrint('GattMeshClient._findCharacteristic: discovering services on ${device.remoteId}');
      final services = await device.discoverServices();
      // 1) check candidate UUIDs (explicit match)
      for (final s in services) {
        for (final c in s.characteristics) {
          final uuid = c.uuid.toString().toLowerCase();
          if (_candidateUuids.contains(uuid)) return c;
        }
      }
      // 2) fallback: find a writable characteristic that supports read or notify
      for (final s in services) {
        for (final c in s.characteristics) {
          try {
            final props = c.properties;
            if (props.write || props.writeWithoutResponse) return c;
          } catch (_) {}
        }
      }
      // 3) as an additional fallback, find the first readable characteristic
      for (final s in services) {
        for (final c in s.characteristics) {
          try {
            if (c.properties.read) return c;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<Map<String, bool>> getLightStates(List<String> macAddresses) async {
    // For BLE Mesh devices, don't attempt direct GATT connections
    // Return cached states from device provider (updated via mesh messages)
    final out = <String, bool>{};
    final devices = deviceProvider();
    for (final mac in macAddresses) {
      final matches = devices.where((d) => macEquals(d.macAddress, mac)).toList();
      MeshDevice? match;
      if (matches.isNotEmpty) match = matches.first;
      out[mac] = match?.lightOn ?? false;
    }

    if (kDebugMode) debugPrint('GattMeshClient.getLightStates: returning cached states (mesh devices do not support direct GATT polling)');

    // If no states determined and fallback exists, use it
    if (out.values.every((v) => v == false) && fallback != null) {
      return fallback!.getLightStates(macAddresses);
    }

    return out;
  }

  @override
  Future<Map<String, int>> getBatteryLevels(List<String> macAddresses) async {
    // Battery implementation removed - stubbed for future Mesh Generic Battery Service.
    // Returns -1 (unknown) for all devices until mesh battery service is implemented.
    final out = <String, int>{};
    for (final mac in macAddresses) {
      out[mac] = -1; // Unknown
    }
    return out;
  }

  @override
  Future<void> sendGroupMessage(int groupId, [List<String>? macAddresses]) async {
    // Write toggled value to devices in the group
    final devices = deviceProvider();
    List<MeshDevice> toToggle;
    if (macAddresses != null && macAddresses.isNotEmpty) {
      final normalized = macAddresses.map(normalizeMac).toSet();
      toToggle = devices.where((d) => normalized.contains(normalizeMac(d.macAddress))).toList();
    } else {
      toToggle = devices.where((d) => d.groupId == groupId).toList();
    }
    if (toToggle.isEmpty) {
      // fallback to underlying implementation if available
      return fallback?.sendGroupMessage(groupId) ?? Future.value();
    }

    for (final d in toToggle) {
      BluetoothDevice? device = await _getDeviceByMac(d.macAddress, allowScan: true);
      if (device == null) {
        if (kDebugMode) debugPrint('GattMeshClient.sendGroupMessage: device ${d.macAddress} not found (not connected or not visible)');
        continue;
      }
      try {
        if (kDebugMode) debugPrint('GattMeshClient.sendGroupMessage: connecting to ${device.remoteId} for group $groupId (target ${d.macAddress})');
        final ok = await _connectWithRetry(device, attempts: 2);
        if (!ok) {
          if (kDebugMode) debugPrint('GattMeshClient.sendGroupMessage: connection failed to ${device.remoteId}; skipping');
          continue;
        }
        final char = await _findCharacteristic(device);
        if (char == null) {
          if (kDebugMode) debugPrint('GattMeshClient.sendGroupMessage: no candidate characteristic discovered for ${device.remoteId}');
          await device.disconnect();
          continue;
        }
        // read current
        final cur = await char.read();
        final isOn = cur.isNotEmpty && cur.first == 0x01;
        final newVal = [isOn ? 0x00 : 0x01];
        final supportsWriteWithResponse = char.properties.write;
        if (supportsWriteWithResponse) {
          await char.write(newVal, withoutResponse: false);
        } else {
          await char.write(newVal, withoutResponse: true);
        }
        // Give device time to process and try to read back the new value if readable
        try {
          if (char.properties.read) {
            await Future.delayed(const Duration(milliseconds: 150));
            final check = await char.read();
            if (kDebugMode) debugPrint('GattMeshClient.sendGroupMessage: write readback for ${device.remoteId} -> $check');
          } else {
            await Future.delayed(const Duration(milliseconds: 150));
          }
        } catch (_) {}
        await device.disconnect();
      } catch (_) {
        try { await device.disconnect(); } catch (_) {}
      }
    }
  }

  @override
  Future<bool> subscribeToDeviceCharacteristics(String macAddress, List<String> characteristicUuids, {Function(String mac, String uuid, List<int> value)? onNotify, bool allowScan = true}) async {
    // BLE Mesh devices support GATT for battery (BAS), firmware updates (SMP), etc.
    // This requires direct GATT connection to each device.
    // NOTE: Battery is already available from advertisement manufacturer data,
    // so GATT subscriptions are optional/for future enhancements
    try {
      final device = await _getDeviceByMac(macAddress, allowScan: false); // Don't scan - use cached only
      if (device == null) {
        if (kDebugMode) debugPrint('GattMeshClient.subscribeToDeviceCharacteristics: device $macAddress not in cache (skipping - battery from adverts)');
        return false;
      }
      
      // Check if already connected
      final currentState = await device.connectionState.first.timeout(const Duration(milliseconds: 500));
      if (currentState != BluetoothConnectionState.connected) {
        if (kDebugMode) debugPrint('GattMeshClient.subscribeToDeviceCharacteristics: device $macAddress not connected (skipping - battery from adverts)');
        return false;
      }
      
      // Only subscribe if already connected (from a previous operation)
      if (kDebugMode) debugPrint('GattMeshClient.subscribeToDeviceCharacteristics: discovering services for $macAddress');
      final services = await device.discoverServices();
      
      // Subscribe to requested characteristics
      bool anySubscribed = false;
      for (final service in services) {
        for (final char in service.characteristics) {
          final charUuid = char.uuid.toString().toLowerCase();
          if (characteristicUuids.any((uuid) => charUuid.contains(uuid.toLowerCase()))) {
            if (char.properties.notify || char.properties.indicate) {
              if (kDebugMode) debugPrint('GattMeshClient.subscribeToDeviceCharacteristics: subscribing to $charUuid for $macAddress');
              await char.setNotifyValue(true);
              anySubscribed = true;
              
              // Set up notification callback if provided
              if (onNotify != null) {
                char.lastValueStream.listen((value) {
                  onNotify(macAddress, charUuid, value);
                });
              }
            }
          }
        }
      }
      
      if (kDebugMode && anySubscribed) debugPrint('GattMeshClient.subscribeToDeviceCharacteristics: subscribed for $macAddress');
      return anySubscribed;
    } catch (e) {
      // Subscription failures are non-critical since battery comes from advertisements
      if (kDebugMode) debugPrint('GattMeshClient.subscribeToDeviceCharacteristics: skipping $macAddress (battery from adverts): $e');
      return false;
    }
  }
  
  /// Update firmware on a device via SMP DFU protocol.
  ///
  /// This method manages the complete firmware update workflow:
  /// 1. Connect to device via BLE (not mesh)
  /// 2. Establish SMP connection
  /// 3. Upload firmware with progress tracking
  /// 4. Verify image
  /// 5. Reset device
  /// 6. Wait for device to reboot
  ///
  /// Parameters:
  /// - [device]: The target device to update
  /// - [firmwareData]: The firmware binary data to upload
  /// - [onProgress]: Callback invoked with UpdateProgress events
  ///
  /// Returns: A Future that completes when the update is finished
  /// Throws: Exception on connection or upload failures
  Future<void> updateFirmware({
    required MeshDevice device,
    required Uint8List firmwareData,
    required Function(UpdateProgress) onProgress,
  }) async {
    final macAddress = device.macAddress;
    
    if (kDebugMode) {
      debugPrint('GattMeshClient.updateFirmware: starting update for $macAddress (${firmwareData.length} bytes)');
    }
    
    try {
      // 1. Connect to device via SMP
      onProgress(UpdateProgress(
        deviceMac: macAddress,
        bytesTransferred: 0,
        totalBytes: firmwareData.length,
        stage: UpdateStage.connecting,
        startedAt: DateTime.now(),
      ));
      
      final connected = await _smpClient.connect(macAddress);
      if (!connected) {
        throw Exception('Failed to establish SMP connection to $macAddress');
      }
      
      if (kDebugMode) {
        debugPrint('GattMeshClient.updateFirmware: SMP connection established');
      }
      
      // 2. Upload firmware and listen to progress
      final uploadStream = _smpClient.uploadFirmware(macAddress, firmwareData);
      
      await for (final progress in uploadStream) {
        if (kDebugMode) {
          debugPrint('GattMeshClient.updateFirmware: ${progress.stage} - ${progress.percentage.toStringAsFixed(1)}%');
        }
        
        onProgress(progress);
        
        // If upload failed, throw exception
        if (progress.stage == UpdateStage.failed) {
          throw Exception(progress.errorMessage ?? 'Firmware upload failed');
        }
        
        // If upload completed successfully, break the loop
        if (progress.stage == UpdateStage.complete) {
          if (kDebugMode) {
            debugPrint('GattMeshClient.updateFirmware: firmware verified successfully');
          }
          break;
        }
      }
      
      // 3. Reset device to apply the new firmware
      if (kDebugMode) {
        debugPrint('GattMeshClient.updateFirmware: resetting device');
      }
      
      onProgress(UpdateProgress(
        deviceMac: macAddress,
        bytesTransferred: firmwareData.length,
        totalBytes: firmwareData.length,
        stage: UpdateStage.rebooting,
      ));
      
      final resetSuccess = await _smpClient.resetDevice(macAddress);
      if (!resetSuccess) {
        if (kDebugMode) {
          debugPrint('GattMeshClient.updateFirmware: reset command may have failed, but device should reboot anyway');
        }
      }
      
      // 4. Wait for device to reboot (give it a few seconds)
      await Future.delayed(const Duration(seconds: 3));
      
      // 5. Update complete
      onProgress(UpdateProgress(
        deviceMac: macAddress,
        bytesTransferred: firmwareData.length,
        totalBytes: firmwareData.length,
        stage: UpdateStage.complete,
        completedAt: DateTime.now(),
      ));
      
      if (kDebugMode) {
        debugPrint('GattMeshClient.updateFirmware: update completed successfully');
      }
      
    } catch (e) {
      if (kDebugMode) {
        debugPrint('GattMeshClient.updateFirmware: error during update: $e');
      }
      
      // Notify caller of failure
      onProgress(UpdateProgress(
        deviceMac: macAddress,
        bytesTransferred: 0,
        totalBytes: firmwareData.length,
        stage: UpdateStage.failed,
        errorMessage: e.toString(),
        completedAt: DateTime.now(),
      ));
      
      rethrow;
    } finally {
      // Always disconnect SMP connection when done (success or failure)
      try {
        await _smpClient.disconnect();
        if (kDebugMode) {
          debugPrint('GattMeshClient.updateFirmware: SMP disconnected');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('GattMeshClient.updateFirmware: error disconnecting SMP: $e');
        }
      }
    }
  }
  
  /// Disconnect from SMP session.
  /// Should be called when firmware updates are complete or cancelled.
  Future<void> disconnectSMP() async {
    try {
      await _smpClient.disconnect();
      if (kDebugMode) {
        debugPrint('GattMeshClient.disconnectSMP: SMP disconnected');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('GattMeshClient.disconnectSMP: error: $e');
      }
      rethrow;
    }
  }
}
