class MeshDevice {
  final String macAddress;
  final String identifier; // last 6 nibbles
  final String hardwareId;
  final int batteryPercent;
  final int rssi;
  final String version;
  int? groupId;
  bool? lightOn;
  MeshDevice({
    required this.macAddress,
    required this.identifier,
    required this.hardwareId,
    required this.batteryPercent,
    required this.rssi,
    required this.version,
    this.groupId,
    this.lightOn,
  });
}
