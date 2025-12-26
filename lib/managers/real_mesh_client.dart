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
  Function(int unicastAddress, bool state, bool? targetState)? _onDeviceStatus;
  
  bool get isPluginAvailable => _available;

  PlatformMeshClient({MeshClient? fallback}) : _fallback = fallback ?? MockMeshClient(() => []) {
    // Listen for callbacks from native plugin.
    // NOTE: Per METHOD_CHANNEL_CONTRACT.md, Android currently emits only `onDeviceStatus`.
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onDeviceStatus':
          try {
            final args = call.arguments as Map<dynamic, dynamic>?;
            if (args == null) return;
            final unicastAddress = args['unicastAddress'] as int;
            final state = args['state'] as bool;
            final targetState = args['targetState'] as bool?;
            if (kDebugMode) {
              debugPrint(
                'PlatformMeshClient: status from 0x${unicastAddress.toRadixString(16)}: state=$state, target=$targetState',
              );
            }
            _onDeviceStatus?.call(unicastAddress, state, targetState);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('PlatformMeshClient: error handling onDeviceStatus: $e');
            }
          }
          return;
        default:
          // Ignore unknown/unimplemented callbacks.
          return;
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
      // NOTE: An "all false" result is a valid mesh state (everything is OFF).
      // Only fall back when the plugin returns no data.
      if (out.isEmpty) return _fallback.getLightStates(macAddresses);
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
      if (res == null) return await _fallback.getBatteryLevels(macAddresses);
      final out = <String, int>{};
      res.forEach((k, v) {
        try {
          final battery = v as int;
          out[k] = battery;
        } catch (_) {
          out[k] = 0;
        }
      });
      // if the plugin returns no useful data (all zeros), use cached or fallback
      final hasUseful = out.values.any((v) => v > 0);
      if (!hasUseful) {
        return _fallback.getBatteryLevels(macAddresses);
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
  
  void setDeviceStatusCallback(Function(int unicastAddress, bool state, bool? targetState) callback) {
    _onDeviceStatus = callback;
  }
  
  Future<bool> discoverGroupMembers(int groupAddress, {bool currentState = false, List<int>? deviceUnicasts}) async {
    try {
      final result = await _channel.invokeMethod('discoverGroupMembers', {
        'groupAddress': groupAddress,
        'currentState': currentState,
        if (deviceUnicasts != null) 'deviceUnicasts': deviceUnicasts,
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

  /// Send a GenericOnOffGet to a specific unicast address.
  /// The device should respond with a GenericOnOffStatus which is surfaced via the status event channel.
  Future<bool> sendUnicastGet(int unicastAddress, {String? proxyMac}) async {
    try {
      final args = {
        'unicastAddress': unicastAddress,
        if (proxyMac != null) 'proxyMac': proxyMac,
      };
      final result = await _channel.invokeMethod<bool>('sendUnicastGet', args);
      return result == true;
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.sendUnicastGet error: $e');
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
      if (res == true) return true;
      return _fallback.subscribeToDeviceCharacteristics(macAddress, characteristicUuids, onNotify: onNotify, allowScan: allowScan);
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

  /// Read node subscription lists from the native mesh database.
  /// Useful for group membership discovery even when nodes don't respond to
  /// runtime status queries.
  Future<List<Map<String, dynamic>>> getNodeSubscriptions() async {
    if (!_available) return <Map<String, dynamic>>[];
    try {
      final res = await _channel.invokeMethod<List>('getNodeSubscriptions');
      if (res == null) return <Map<String, dynamic>>[];
      return res
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList();
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.getNodeSubscriptions error: $e');
      return <Map<String, dynamic>>[];
    }
  }

  /// Return the raw node list from the native mesh database.
  /// Each entry typically contains: { unicastAddress: int, name: String, uuid: String }.
  Future<List<Map<String, dynamic>>> getMeshNodes() async {
    if (!_available) return <Map<String, dynamic>>[];
    try {
      final res = await _channel.invokeMethod<List>('getMeshNodes');
      if (res == null) return <Map<String, dynamic>>[];
      return res
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e.map((k, v) => MapEntry(k.toString(), v))))
          .toList();
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformMeshClient.getMeshNodes error: $e');
      return <Map<String, dynamic>>[];
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
    // No-op: Android does not currently emit characteristic notification callbacks.
  }
}
