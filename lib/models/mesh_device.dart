enum ConnectionStatus { disconnected, connecting, connected, ready }

enum ChargingState {
  notCharging,
  charging,
  discharging,
  unknown,
}

class MeshDevice {
  final String macAddress;
  final String identifier; // last 6 nibbles
  final String hardwareId;
  int batteryPercent;
  final int rssi;
  final String version;
  int? groupId;
  bool? lightOn;
  ConnectionStatus connectionStatus;
  // When known, this should be treated as the source-of-truth unicast address
  // (sourced from the mesh network DB / provisioning records).
  int? meshUnicastAddress;
  
  // Battery status fields from Mesh Generic Battery Server Model
  int? timeToDischarge; // minutes until battery depleted
  int? timeToCharge; // minutes until fully charged
  ChargingState? chargingState;
  
  MeshDevice({
    required this.macAddress,
    required this.identifier,
    required this.hardwareId,
    required this.batteryPercent,
    required this.rssi,
    required this.version,
    this.groupId,
    this.lightOn,
    this.connectionStatus = ConnectionStatus.disconnected,
    this.meshUnicastAddress,
    this.timeToDischarge,
    this.timeToCharge,
    this.chargingState,
  });
  
  /// Best-effort derived unicast address from MAC.
  /// This is not reliable across all devices; prefer [meshUnicastAddress] when set.
  int get derivedUnicastAddress {
    // Parse MAC address (format: "AA:BB:CC:DD:EE:FF")
    final parts = macAddress.split(':');
    if (parts.length != 6) return 0;
    
    try {
      // Get last 2 bytes (indices 4 and 5)
      final byte4 = int.parse(parts[4], radix: 16);
      final byte5 = int.parse(parts[5], radix: 16);

      // Combine in big-endian order (no byte-swap): high=parts[4], low=parts[5]
      int addr = (byte4 << 8) | byte5;
      addr &= 0x7FFF; // Keep in valid unicast range 0x0001-0x7FFF

      return addr;
    } catch (e) {
      return 0;
    }
  }

  /// Mesh unicast address used for messaging/status matching.
  /// Prefers mesh-DB-derived value; falls back to MAC-derived value.
  int get unicastAddress {
    final mesh = meshUnicastAddress;
    if (mesh != null && mesh >= 0x0001 && mesh <= 0x7FFF) {
      return mesh;
    }
    return derivedUnicastAddress;
  }
}
