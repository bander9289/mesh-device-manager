import 'dart:async';
import 'package:flutter/foundation.dart';
// 'dart:convert' not used by PlatformMeshClient; remove unused import
import 'package:flutter/services.dart';
import 'mesh_client.dart';

/// Platform bridge MeshClient - communicates with native Nordic mesh implementation.
/// Falls back to provided MeshClient implementation if the native plugin is unavailable.
class PlatformMeshClient implements MeshClient {
  static const MethodChannel _channel = MethodChannel('mesh_plugin');

  final MeshClient _fallback;
  bool _available = false;
  final Map<String, DateTime> _recentPduInvocations = {};
  final Map<String, List<Function(String, String, List<int>)>> _nativeCharListeners = {};
  final Map<String, int> _deviceBatteryLevels = {}; // Track battery levels from native callbacks
  Function(String mac, int battery)? _onBatteryUpdate;
  Function(String mac)? _onSubscriptionReady;
  Function(int unicastAddress, bool state, bool? targetState)? _onDeviceStatus;
  
  bool get isPluginAvailable => _available;

  PlatformMeshClient({MeshClient? fallback}) : _fallback = fallback ?? MockMeshClient(() => []) {
    // Listen for callbacks from native plugin (e.g., created PDUs)
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onDeviceStatus') {
        try {
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args == null) return;
          final unicastAddress = args['unicastAddress'] as int;
          final state = args['state'] as bool;
          final targetState = args['targetState'] as bool?;
          if (kDebugMode) debugPrint('PlatformMeshClient: status from 0x${unicastAddress.toRadixString(16)}: state=$state, target=$targetState');
          _onDeviceStatus?.call(unicastAddress, state, targetState);
        } catch (e) {
          if (kDebugMode) debugPrint('PlatformMeshClient: error handling onDeviceStatus: $e');
        }
      }
      if (call.method == 'onMeshPduCreated') {
        try {
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args == null) return;
          final macs = (args['macs'] as List?)?.cast<String>() ?? [];
          final groupId = args['groupId'] as int? ?? 0;
          final fallback = args['fallback'] as bool? ?? true;
          if (kDebugMode) debugPrint('PlatformMeshClient: onMeshPduCreated: group=$groupId macs=${macs.length}');
          final key = '$groupId:${macs.join(',')}';
          final now = DateTime.now();
          final prev = _recentPduInvocations[key];
          if (prev != null && now.difference(prev).inMilliseconds < 1500) {
            if (kDebugMode) debugPrint('PlatformMeshClient: ignoring duplicate pdu callback for $key');
            return;
          }
          _recentPduInvocations[key] = now;
          // If fallback is a GattMeshClient, use it to send a group toggle; fall back to generic sendGroupMessage
          if (fallback) {
            await _fallback.sendGroupMessage(groupId, macs);
          } else {
            if (kDebugMode) debugPrint('PlatformMeshClient: plugin indicates transport is handled natively; no GATT fallback.');
          }
        } catch (_) {
          // ignore
        }
      }
      if (call.method == 'onCharacteristicNotification') {
        try {
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args == null) return;
          final mac = (args['mac'] as String).toLowerCase().replaceAll('-', ':');
          final uuid = args['uuid'] as String;
          final valueList = (args['value'] as List).map((e) => (e as int)).toList();
          final listeners = _nativeCharListeners[mac];
          if (listeners != null) {
            for (final l in listeners) {
              try { l(mac, uuid, valueList); } catch (_) {}
            }
          }
        } catch (e) { /* ignore */ }
      }
      if (call.method == 'onBatteryLevel') {
        try {
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args == null) return;
          final mac = (args['mac'] as String).toLowerCase().replaceAll('-', ':');
          final battery = args['battery'] as int;
          _deviceBatteryLevels[mac] = battery;
          if (kDebugMode) debugPrint('PlatformMeshClient: battery level for $mac = $battery%');
          _onBatteryUpdate?.call(mac, battery);
        } catch (e) { /* ignore */ }
      }
      if (call.method == 'onSubscriptionReady') {
        try {
          final args = call.arguments as Map<dynamic, dynamic>?;
          if (args == null) return;
          final mac = (args['mac'] as String).toLowerCase().replaceAll('-', ':');
          if (kDebugMode) debugPrint('PlatformMeshClient: subscription ready for $mac');
          _onSubscriptionReady?.call(mac);
        } catch (e) { /* ignore */ }
      }
    });
  }

  Future<void> _probe() async {
    try {
      final res = await _channel.invokeMethod<bool>('isAvailable');
      _available = res == true;
      if (kDebugMode) debugPrint('PlatformMeshClient._probe: plugin available=$_available');
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient._probe: error checking availability -> $e');
      _available = false;
    }
  }

  @override
  Future<void> initialize(Map<String, String>? credentials) async {
    // Probe plugin availability first (this is critical!)
    await _probe();
    if (kDebugMode) debugPrint('PlatformMeshClient.initialize: available=$_available');
    
    // If plugin unavailable, delegate to fallback
    if (!_available) {
      if (kDebugMode) debugPrint('PlatformMeshClient.initialize: plugin not available, using fallback');
      return _fallback.initialize(credentials);
    }
    
    // Plugin is available - initialize native mesh network
    try {
      if (kDebugMode) debugPrint('PlatformMeshClient.initialize: calling native initialize');
      await _channel.invokeMethod('initialize', {
        'netKey': credentials?['netKey'],
        'appKey': credentials?['appKey'],
        'ivIndex': credentials?['ivIndex'] ?? 0,
      });
      if (kDebugMode) debugPrint('PlatformMeshClient.initialize: native initialize successful');
    } on MissingPluginException catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.initialize: MissingPluginException -> $e');
      _available = false;
      return _fallback.initialize(credentials);
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.initialize: error during native initialize -> $e');
      _available = false;
      return _fallback.initialize(credentials);
    }
  }

  @override
  Future<Map<String, bool>> getLightStates(List<String> macAddresses) async {
    if (!_available) return _fallback.getLightStates(macAddresses);
    try {
      final res = await _channel.invokeMethod<Map>('getLightStates', {'macs': macAddresses});
      if (res == null) return _fallback.getLightStates(macAddresses);
      final out = <String, bool>{};
      res.forEach((k, v) { out[k as String] = v == true; });
      if (out.isEmpty || out.values.every((b) => b == false)) {
        return _fallback.getLightStates(macAddresses);
      }
      return out;
    } on MissingPluginException catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.getLightStates: MissingPluginException! Setting _available=false -> $e');
      _available = false;
      return _fallback.getLightStates(macAddresses);
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.getLightStates: exception -> $e');
      return _fallback.getLightStates(macAddresses);
    }
  }

  @override
  Future<Map<String, int>> getBatteryLevels(List<String> macAddresses) async {
    if (!_available) return _fallback.getBatteryLevels(macAddresses);
    try {
      final res = await _channel.invokeMethod<Map>('getBatteryLevels', {'macs': macAddresses});
      if (res == null) {
        // Return cached battery levels from callbacks
        final out = <String, int>{};
        for (final mac in macAddresses) {
          final normalized = mac.toLowerCase().replaceAll('-', ':');
          out[mac] = _deviceBatteryLevels[normalized] ?? 0;
        }
        final hasAny = out.values.any((v) => v > 0);
        if (hasAny) return out;
        return await _fallback.getBatteryLevels(macAddresses);
      }
      final out = <String, int>{};
      res.forEach((k, v) {
        try {
          final normalized = k.toLowerCase().replaceAll('-', ':');
          final battery = v as int;
          out[k] = battery;
          _deviceBatteryLevels[normalized] = battery;
        } catch (_) {
          out[k] = 0;
        }
      });
      // if the plugin returns no useful data (all zeros), use cached or fallback
      final hasUseful = out.values.any((v) => v > 0);
      if (!hasUseful) {
        // Check cached values
        for (final mac in macAddresses) {
          final normalized = mac.toLowerCase().replaceAll('-', ':');
          if (_deviceBatteryLevels.containsKey(normalized)) {
            out[mac] = _deviceBatteryLevels[normalized]!;
          }
        }
        if (!out.values.any((v) => v > 0)) {
          return _fallback.getBatteryLevels(macAddresses);
        }
      }
      return out;
    } on MissingPluginException catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.getBatteryLevels: MissingPluginException! Setting _available=false -> $e');
      _available = false;
      return _fallback.getBatteryLevels(macAddresses);
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.getBatteryLevels: exception -> $e');
      return _fallback.getBatteryLevels(macAddresses);
    }
  }
  
  /// Set callback for battery level updates
  void setBatteryUpdateCallback(Function(String mac, int battery) callback) {
    _onBatteryUpdate = callback;
  }
  
  /// Set callback for subscription ready notifications
  void setSubscriptionReadyCallback(Function(String mac) callback) {
    _onSubscriptionReady = callback;
  }
  
  void setDeviceStatusCallback(Function(int unicastAddress, bool state, bool? targetState) callback) {
    _onDeviceStatus = callback;
  }
  
  Future<bool> discoverGroupMembers(int groupAddress, {bool currentState = false}) async {
    try {
      final result = await _channel.invokeMethod('discoverGroupMembers', {
        'groupAddress': groupAddress,
        'currentState': currentState,
      });
      return result == true;
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.discoverGroupMembers error: $e');
      return false;
    }
  }
  
  /// Send unicast message directly to a device to test status responses
  Future<bool> sendUnicastMessage(int unicastAddress, bool state, {String? proxyMac}) async {
    try {
      final args = {
        'unicastAddress': unicastAddress,
        'state': state,
      };
      if (proxyMac != null) {
        args['proxyMac'] = proxyMac;
      }
      if (kDebugMode) debugPrint('PlatformMeshClient.sendUnicastMessage: proxyMac=$proxyMac, args=$args');
      final result = await _channel.invokeMethod('sendUnicastMessage', args);
      if (kDebugMode) debugPrint('PlatformMeshClient.sendUnicastMessage: unicast=0x${unicastAddress.toRadixString(16)} state=$state result=$result');
      return result == true;
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.sendUnicastMessage error: $e');
      return false;
    }
  }

  @override
  Future<void> sendGroupMessage(int groupId, [List<String>? macAddresses]) async {
    if (kDebugMode) debugPrint('PlatformMeshClient.sendGroupMessage: _available=$_available groupId=$groupId macs=${macAddresses?.length ?? 0}');
    if (!_available) {
      if (kDebugMode) debugPrint('PlatformMeshClient.sendGroupMessage: plugin not available, using fallback');
      return _fallback.sendGroupMessage(groupId, macAddresses);
    }
    try {
      if (kDebugMode) debugPrint('PlatformMeshClient.sendGroupMessage: calling native with group $groupId');
      final res = await _channel.invokeMethod<bool>('sendGroupMessage', {'groupId': groupId, 'macs': macAddresses});
      if (kDebugMode) debugPrint('PlatformMeshClient.sendGroupMessage: native returned $res');
      if (res == null || res == false) {
        if (kDebugMode) debugPrint('PlatformMeshClient.sendGroupMessage: native plugin returned failure; using fallback');
        return _fallback.sendGroupMessage(groupId, macAddresses);
      }
      if (kDebugMode) debugPrint('PlatformMeshClient.sendGroupMessage: native send successful');
    } on MissingPluginException catch (e) {
      _available = false;
      if (kDebugMode) debugPrint('PlatformMeshClient.sendGroupMessage: MissingPluginException -> $e');
      await _fallback.sendGroupMessage(groupId, macAddresses);
      return;
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.sendGroupMessage: exception -> $e');
      await _fallback.sendGroupMessage(groupId, macAddresses);
      return;
    }
  }

  /// Similar to sendGroupMessage but returns a boolean indicating if the plugin handled the send.
  /// If plugin is unavailable or indicates failure, fallback will be used and true/false will reflect the end result.
  Future<bool> sendGroupMessageWithStatus(int groupId, [List<String>? macAddresses]) async {
    if (!_available) {
      try {
        await _fallback.sendGroupMessage(groupId, macAddresses);
        return true;
      } catch (_) { return false; }
    }
    try {
      if (kDebugMode) debugPrint('PlatformMeshClient.sendGroupMessageWithStatus: sending group $groupId');
      final res = await _channel.invokeMethod<bool>('sendGroupMessage', {'groupId': groupId, 'macs': macAddresses});
      if (res == null) {
        await _fallback.sendGroupMessage(groupId, macAddresses);
        return true;
      }
      if (res == true) return true;
      // Plugin returned false — try fallback
      await _fallback.sendGroupMessage(groupId, macAddresses);
      return true;
    } on MissingPluginException {
      _available = false;
      try { await _fallback.sendGroupMessage(groupId, macAddresses); } catch (_) {}
      return true;
    } catch (_) {
      try { await _fallback.sendGroupMessage(groupId, macAddresses); } catch (_) {}
      return false;
    }
  }

  /// Force the fallback (GATT) to send group messages for the specified macs.
  Future<void> forceGATTFallbackSend(int groupId, List<String> macAddresses) async {
    try {
      await _fallback.sendGroupMessage(groupId, macAddresses);
    } catch (_) {}
  }

  @override
  Future<bool> subscribeToDeviceCharacteristics(String macAddress, List<String> characteristicUuids, {Function(String mac, String uuid, List<int> value)? onNotify, bool allowScan = true}) async {
    if (!_available) return _fallback.subscribeToDeviceCharacteristics(macAddress, characteristicUuids, onNotify: onNotify);
    try {
      final res = await _channel.invokeMethod<bool>('subscribeToCharacteristics', {'mac': macAddress, 'uuids': characteristicUuids});
      if (res != null && res == true) {
        if (onNotify != null) {
          final mac = macAddress.toLowerCase().replaceAll('-', ':');
          final list = _nativeCharListeners.putIfAbsent(mac, () => []);
          list.add(onNotify);
        }
        return true;
      }
      final acted = await _fallback.subscribeToDeviceCharacteristics(macAddress, characteristicUuids, onNotify: onNotify, allowScan: allowScan);
      if (acted && onNotify != null) {
        final mac = macAddress.toLowerCase().replaceAll('-', ':');
        final list = _nativeCharListeners.putIfAbsent(mac, () => []);
        list.add(onNotify);
      }
      return acted;
    } on MissingPluginException catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.subscribeToDeviceCharacteristics: MissingPluginException! Setting _available=false -> $e');
      _available = false;
      return _fallback.subscribeToDeviceCharacteristics(macAddress, characteristicUuids, onNotify: onNotify, allowScan: allowScan);
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.subscribeToDeviceCharacteristics: exception -> $e');
      return _fallback.subscribeToDeviceCharacteristics(macAddress, characteristicUuids, onNotify: onNotify, allowScan: allowScan);
    }
  }

  Future<bool> isDeviceConnectedNative(String macAddress) async {
    if (!_available) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isDeviceConnected', {'mac': macAddress});
      return res == true;
    } catch (_) { return false; }
  }

  Future<bool> ensureProxyConnection(String macAddress, {List<int>? deviceUnicasts}) async {
    if (!_available) return false;
    try {
      final params = <String, dynamic>{'mac': macAddress};
      if (deviceUnicasts != null && deviceUnicasts.isNotEmpty) {
        params['deviceUnicasts'] = deviceUnicasts;
      }
      final res = await _channel.invokeMethod<bool>('ensureProxyConnection', params);
      return res == true;
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.ensureProxyConnection error: $e');
      return false;
    }
  }
  
  /// Configure proxy filter to receive status messages from specific devices.
  /// CRITICAL: This must be called after connecting to proxy, otherwise status messages are dropped.
  Future<bool> configureProxyFilter(List<int> deviceUnicasts) async {
    if (!_available) return false;
    try {
      final res = await _channel.invokeMethod<bool>('configureProxyFilter', {
        'deviceUnicasts': deviceUnicasts,
      });
      if (kDebugMode) debugPrint('PlatformMeshClient.configureProxyFilter: configured for ${deviceUnicasts.length} devices');
      return res == true;
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.configureProxyFilter error: $e');
      return false;
    }
  }

  Future<Map<String, dynamic>?> discoverServices(String macAddress) async {
    if (!_available) return null;
    try {
      final res = await _channel.invokeMethod<Map>('discoverServices', {'mac': macAddress});
      if (res == null) return null;
      return Map<String, dynamic>.from(res.map((k, v) => MapEntry(k as String, v)));
    } catch (_) { return null; }
  }

  Future<bool> disconnectDeviceNative(String macAddress) async {
    if (!_available) return false;
    try {
      final res = await _channel.invokeMethod<bool>('disconnectDevice', {'mac': macAddress});
      return res == true;
    } catch (_) { return false; }
  }

  Future<List<int>?> readCharacteristic(String macAddress, String uuid) async {
    if (!_available) return null;
    try {
      final res = await _channel.invokeMethod<List>('readCharacteristic', {'mac': macAddress, 'uuid': uuid});
      if (res == null) return null;
      return res.cast<int>();
    } catch (_) { return null; }
  }

  Future<bool> writeCharacteristic(String macAddress, String uuid, List<int> value, {bool withResponse = true}) async {
    if (!_available) return false;
    try {
      final res = await _channel.invokeMethod<bool>('writeCharacteristic', {'mac': macAddress, 'uuid': uuid, 'value': value, 'withResponse': withResponse});
      return res == true;
    } catch (_) { return false; }
  }

  Future<bool> setNotify(String macAddress, String uuid, bool enabled) async {
    if (!_available) return false;
    try {
      final res = await _channel.invokeMethod<bool>('setNotify', {'mac': macAddress, 'uuid': uuid, 'enabled': enabled});
      return res == true;
    } catch (_) { return false; }
  }

  void removeNativeCharListenersForMac(String macAddress) {
    final mac = macAddress.toLowerCase().replaceAll('-', ':');
    _nativeCharListeners.remove(mac);
  }
}
