import '../models/mesh_device.dart';

/// Mesh client abstraction used to send and poll mesh messages.
/// Provide a real implementation (nRF Mesh SDK) for production.
abstract class MeshClient {
  Future<void> initialize(Map<String, String>? credentials) async {}
  Future<Map<String, bool>> getLightStates(List<String> macAddresses);
  Future<void> sendGroupMessage(int groupId);
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
  Future<void> sendGroupMessage(int groupId) async {
    // Simulate toggling the state of devices assigned to this group.
    // Use the device provider to check group membership and toggle those devices.
    await Future.delayed(const Duration(milliseconds: 100));
    final devices = deviceProvider();
    for (final d in devices) {
      if (d.groupId == groupId) {
        final prev = _state[d.macAddress] ?? false;
        _state[d.macAddress] = !prev;
      }
    }
  }
}
