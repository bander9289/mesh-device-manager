import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../models/mesh_device.dart';
import '../../models/mesh_group.dart';
import '../../utils/mac_address.dart';

class BleScanningService {
  BleScanningService({
    required List<MeshDevice> devices,
    required List<MeshGroup> groups,
    required Map<String, BluetoothDevice> deviceCache,
  })  : _devices = devices,
        _groups = groups,
        _deviceCache = deviceCache;

  final List<MeshDevice> _devices;
  final List<MeshGroup> _groups;
  final Map<String, BluetoothDevice> _deviceCache;

  bool filterMeshOnly = true;
  Set<String> hardwareIdWhitelist = <String>{};
  bool verboseLogging = false;

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  Timer? _scanCancelTimer;
  final Map<String, DateTime> _lastAdvertLogTimes = <String, DateTime>{};
  DateTime? _lastScanResultsLog;

  bool get isScanning => _scanSubscription != null;

  BluetoothDevice? getCachedDevice(String mac) {
    return _deviceCache[macCacheKey(mac)];
  }

  void start({
    Duration? timeout,
    bool clearExisting = false,
    required VoidCallback onDevicesChanged,
    ValueChanged<bool /* timedOut */ >? onScanStopped,
  }) {
    if (_scanSubscription != null) {
      return;
    }

    if (clearExisting) {
      _devices.clear();
    }

    if (kDebugMode) {
      debugPrint('BleScanningService.start: starting (clearExisting=$clearExisting)');
    }

    _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
      // Helpful scan diagnostics when only a few results appear.
      if (kDebugMode && results.isNotEmpty && results.length <= 4) {
        final macs = results
            .map((r) => normalizeMac(r.device.remoteId.toString()))
            .join(',');
        debugPrint('BleScanningService: raw scan results (${results.length}) macs=$macs');
      }

      if (kDebugMode && results.isNotEmpty) {
        final now = DateTime.now();
        if (_lastScanResultsLog == null ||
            now.difference(_lastScanResultsLog!).inSeconds > 10) {
          _lastScanResultsLog = now;
          debugPrint('BleScanningService: got ${results.length} scan results');
        }
      }

      var changed = false;
      for (final r in results) {
        if (filterMeshOnly && !_isMeshAdvertisement(r)) {
          // If we're seeing very few results, log what we're skipping to
          // differentiate radio issues from filter issues.
          if (kDebugMode && results.length <= 4) {
            final mac = normalizeMac(r.device.remoteId.toString());
            String name = '';
            try {
              final adv = r.advertisementData.advName;
              name = adv.isNotEmpty ? adv : r.device.platformName;
            } catch (_) {
              name = r.device.platformName;
            }
            final uuids = r.advertisementData.serviceUuids
                .map((u) => u.toString())
                .join(',');
            final hasMfg = r.advertisementData.manufacturerData.isNotEmpty;
            debugPrint(
              'BleScanningService: skipping (non-mesh) mac=$mac name="$name" uuids=[$uuids] mfg=$hasMfg',
            );
          }
          continue;
        }

        final mac = normalizeMac(r.device.remoteId.toString());

        // Cache the BluetoothDevice object for later use
        _deviceCache[macCacheKey(mac)] = r.device;

        final identifier = (r.device.platformName.isNotEmpty)
            ? r.device.platformName
            : (mac.length >= 8 ? mac.substring(mac.length - 8) : mac);

        // Extract hardwareId from manufacturerData if present
        String hw = 'unknown';
        int battery = -1;
        if (r.advertisementData.manufacturerData.isNotEmpty) {
          final entry = r.advertisementData.manufacturerData.entries.first;
          hw = entry.value
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
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
        if (hardwareIdWhitelist.isNotEmpty &&
            !hardwareIdWhitelist.contains(device.hardwareId)) {
          continue;
        }

        final idx = _devices.indexWhere((d) => d.macAddress == mac);
        if (idx >= 0) {
          final existing = _devices[idx];
          final defaultGroupId = _groups.any((g) => g.id == 0xC000) ? 0xC000 : null;
          final nextGroupId = existing.groupId ?? defaultGroupId;

          // update rssi and battery
          if (existing.rssi != device.rssi ||
              existing.batteryPercent != device.batteryPercent ||
              nextGroupId != existing.groupId) {
            _devices[idx] = MeshDevice(
              macAddress: existing.macAddress,
              identifier: existing.identifier,
              hardwareId: device.hardwareId,
              batteryPercent: device.batteryPercent,
              rssi: device.rssi,
              version: device.version,
              groupId: nextGroupId,
              lightOn: existing.lightOn,
              meshUnicastAddress: existing.meshUnicastAddress,
            );
            changed = true;
            if (kDebugMode && verboseLogging) {
              debugPrint(
                'BleScanningService: updated device $mac rssi=${device.rssi} battery=${device.batteryPercent}',
              );
            }
          }
        } else {
          // If we can't reliably infer group membership yet, default new devices to Default group.
          // This prevents newly discovered nodes (including proxies) from lingering in "Unknown".
          if (device.groupId == null && _groups.any((g) => g.id == 0xC000)) {
            device.groupId = 0xC000;
          }

          _devices.add(device);
          if (kDebugMode && verboseLogging) {
            debugPrint(
              'BleScanningService: added new device $mac id=$identifier hw=$hw rssi=${r.rssi}',
            );
          }
          changed = true;
        }
      }

      if (changed) {
        onDevicesChanged();
      }
    });

    final dur = timeout ?? const Duration(seconds: 20);
    FlutterBluePlus.startScan(timeout: dur);

    // Ensure we stop scanning after the duration in case the plugin doesn't automatically
    _scanCancelTimer?.cancel();
    _scanCancelTimer = Timer(dur, () {
      try {
        stop(onDevicesChanged: onDevicesChanged, onScanStopped: onScanStopped, timedOut: true);
      } catch (_) {
        // best-effort
      }
    });
  }

  void stop({
    required VoidCallback onDevicesChanged,
    ValueChanged<bool /* timedOut */ >? onScanStopped,
    bool timedOut = false,
  }) {
    _scanSubscription?.cancel();
    _scanSubscription = null;
    FlutterBluePlus.stopScan();
    _scanCancelTimer?.cancel();
    _scanCancelTimer = null;
    onDevicesChanged();
    onScanStopped?.call(timedOut);
  }

  void dispose() {
    try {
      _scanSubscription?.cancel();
    } catch (_) {}
    _scanSubscription = null;

    try {
      _scanCancelTimer?.cancel();
    } catch (_) {}
    _scanCancelTimer = null;
  }

  bool _isMeshAdvertisement(ScanResult r) {
    final mac = normalizeMac(r.device.remoteId.toString());

    // 1) Mesh Proxy / Provisioning service UUIDs (provisioned/unprovisioned)
    final uuids = r.advertisementData.serviceUuids
        .map((u) => u.toString().toLowerCase())
        .toList();
    if (uuids.any((u) =>
        u.contains('00001828') ||
        u.contains('00001827') ||
        u.contains('1828') ||
        u.contains('1827'))) {
      if (_shouldLogAdvert(mac) && kDebugMode && verboseLogging) {
        debugPrint(
          'BleScanningService: mesh advertisement service uuid present (${uuids.join(',')})',
        );
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
        if (_shouldLogAdvert(mac) && kDebugMode && verboseLogging) {
          debugPrint('BleScanningService: mesh advertisement name starts with KMv: $name');
        }
        return true;
      }

      // also match the hw-version-hash pattern
      final nameRegex = RegExp(r'^[A-Z0-9\-]+-\d+\.\d+\.\d+-[a-f0-9]+\b',
          caseSensitive: false);
      if (nameRegex.hasMatch(name)) {
        if (_shouldLogAdvert(mac) && kDebugMode && verboseLogging) {
          debugPrint('BleScanningService: mesh advertisement matches firmware pattern: $name');
        }
        return true;
      }
    }

    // 3) Manufacturer data heuristic - fallback: some mesh devices include private bytes
    // Some devices may not consistently advertise Mesh UUIDs or a stable name;
    // manufacturer data is often more reliable.
    if (r.advertisementData.manufacturerData.isNotEmpty) {
      try {
        // Prefer a strong signal: Nordic Semiconductor company identifier (0x0059).
        // This is common for nRF52-based devices and helps avoid missing devices
        // whose adverts omit the Mesh service UUIDs.
        const nordicCompanyId = 0x0059;
        if (r.advertisementData.manufacturerData.containsKey(nordicCompanyId)) {
          if (_shouldLogAdvert(mac) && kDebugMode && verboseLogging) {
            debugPrint('BleScanningService: manufacturer data has Nordic companyId (0x0059)');
          }
          return true;
        }

        final entry = r.advertisementData.manufacturerData.entries.first;
        final hw = entry.value
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        if (_shouldLogAdvert(mac) && kDebugMode && verboseLogging) {
          debugPrint('BleScanningService: manufacturer data present hw=$hw');
        }
        // Only accept unknown manufacturer payloads if explicitly whitelisted.
        if (hardwareIdWhitelist.isNotEmpty && hardwareIdWhitelist.contains(hw)) {
          return true;
        }
      } catch (_) {
        // ignore
      }
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
}
