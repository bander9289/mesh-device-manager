enum ConnectionStatus { disconnected, connecting, connected, ready }

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
  });
  
  /// Calculate mesh unicast address from MAC address
  /// Formula: unicast = ((mac[5] << 8) | mac[4]) & 0x7FFF
  /// Returns 0x0001 if result is 0x0000
  int get unicastAddress {
    // Parse MAC address (format: "AA:BB:CC:DD:EE:FF")
    final parts = macAddress.split(':');
    if (parts.length != 6) return 0x0001;
    
    try {
      // Get last 2 bytes (indices 4 and 5)
      final byte4 = int.parse(parts[4], radix: 16);
      final byte5 = int.parse(parts[5], radix: 16);
      
      // Combine in little-endian order and mask to valid range
      int addr = (byte5 << 8) | byte4;
      addr &= 0x7FFF; // Keep in valid unicast range 0x0001-0x7FFF
      
      // If result is 0, default to 0x0001
      return addr == 0 ? 0x0001 : addr;
    } catch (e) {
      return 0x0001;
    }
  }
}
