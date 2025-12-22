import '../models/mesh_device.dart';
import '../utils/mac_address.dart';

/// Mesh client abstraction used to send and poll mesh messages.
/// Provide a real implementation (nRF Mesh SDK) for production.
abstract class MeshClient {
  Future<void> initialize(Map<String, String>? credentials) async {}
  Future<Map<String, bool>> getLightStates(List<String> macAddresses);
  Future<Map<String, int>> getBatteryLevels(List<String> macAddresses) async { return <String,int>{}; }
  Future<void> sendGroupMessage(int groupId, [List<String>? macAddresses]);
  /// Subscribe to a set of characteristic UUIDs for a specific device MAC address.
  /// When a notification is received, the optional `onNotify` callback will be invoked with
  /// the mac, characteristic uuid and raw value.
  /// Return true if subscription succeeded for at least one characteristic.
  Future<bool> subscribeToDeviceCharacteristics(String macAddress, List<String> characteristicUuids, {Function(String mac, String uuid, List<int> value)? onNotify, bool allowScan = true}) async { return false; }
}

/// Mock mesh client used for testing without an actual mesh implementation.
/// It uses a device provider callback to determine initial group assignment.
class MockMeshClient implements MeshClient {
  List<MeshDevice> Function() deviceProvider;
  MockMeshClient(this.deviceProvider);
  final Map<String, bool> _state = {};

  @override
  Future<void> initialize(Map<String, String>? credentials) async {
    // no-op for mock
  }

  @override
  Future<bool> subscribeToDeviceCharacteristics(String macAddress, List<String> characteristicUuids, {Function(String mac, String uuid, List<int> value)? onNotify, bool allowScan = true}) async {
    // Mock client - nothing to subscribe to. Return false.
    await Future.delayed(const Duration(milliseconds: 50));
    return false;
  }

  @override
  Future<Map<String, bool>> getLightStates(List<String> macAddresses) async {
    // Return the stored states for devices; missing ones are default false.
    await Future.delayed(const Duration(milliseconds: 200));
    final out = <String, bool>{};
    for (final mac in macAddresses) {
      out[mac] = _state[mac] ?? false;
    }
    return out;
  }

  @override
  Future<Map<String, int>> getBatteryLevels(List<String> macAddresses) async {
    await Future.delayed(const Duration(milliseconds: 200));
    final out = <String, int>{};
    final devices = deviceProvider();
    for (final mac in macAddresses) {
      final match = devices.where((d) => macEquals(d.macAddress, mac)).toList();
      out[mac] = match.isNotEmpty ? (match.first.batteryPercent) : 0;
    }
    return out;
  }

  @override
  Future<void> sendGroupMessage(int groupId, [List<String>? macAddresses]) async {
    // Simulate toggling the state of devices assigned to this group.
    // Use the device provider to check group membership and toggle those devices.
    await Future.delayed(const Duration(milliseconds: 100));
    final devices = deviceProvider();
    if (macAddresses != null && macAddresses.isNotEmpty) {
      for (final mac in macAddresses) {
        final prev = _state[mac] ?? false;
        _state[mac] = !prev;
      }
    } else {
      for (final d in devices) {
        if (d.groupId == groupId) {
          final prev = _state[d.macAddress] ?? false;
          _state[d.macAddress] = !prev;
        }
      }
    }
  }
}
