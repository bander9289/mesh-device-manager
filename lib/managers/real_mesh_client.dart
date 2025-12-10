import 'dart:async';
// 'dart:convert' not used by PlatformMeshClient; remove unused import
import 'package:flutter/services.dart';
import 'mesh_client.dart';

/// Platform bridge MeshClient - communicates with native Nordic mesh implementation.
/// Falls back to provided MeshClient implementation if the native plugin is unavailable.
class PlatformMeshClient implements MeshClient {
  static const MethodChannel _channel = MethodChannel('mesh_plugin');

  final MeshClient _fallback;
  bool _available = false;

  PlatformMeshClient({MeshClient? fallback}) : _fallback = fallback ?? MockMeshClient(() => []) {
    // probe plugin availability
    _probe();
  }

  Future<void> _probe() async {
    try {
      final res = await _channel.invokeMethod<bool>('isAvailable');
      _available = res == true;
    } catch (_) {
      _available = false;
    }
  }

  @override
  Future<void> initialize(Map<String, String>? credentials) async {
    await _probe();
    if (!_available) {
      return _fallback.initialize(credentials);
    }
    try {
      await _channel.invokeMethod('initialize', {
        'netKey': credentials?['netKey'],
        'appKey': credentials?['appKey'],
        'ivIndex': credentials?['ivIndex'] ?? 0,
      });
    } on MissingPluginException {
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
      return out;
    } on MissingPluginException {
      _available = false;
      return _fallback.getLightStates(macAddresses);
    }
  }

  @override
  Future<void> sendGroupMessage(int groupId) async {
    if (!_available) return _fallback.sendGroupMessage(groupId);
    try {
      await _channel.invokeMethod('sendGroupMessage', {'groupId': groupId});
    } on MissingPluginException {
      _available = false;
      return _fallback.sendGroupMessage(groupId);
    }
  }
}
