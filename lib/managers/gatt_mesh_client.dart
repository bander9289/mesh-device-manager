import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'mesh_client.dart';
import '../models/mesh_device.dart';

/// Basic GATT-based MeshClient fallback. It writes to known candidate characteristics
/// to toggle a light on devices and reads them to determine state. This is not a
/// full mesh implementation but provides a practical fallback when native mesh is unavailable.
class GattMeshClient implements MeshClient {
  List<MeshDevice> Function() deviceProvider;
  final MeshClient? fallback;

  // Candidate characteristic UUIDs commonly used for light toggle / vendor features
  static const List<String> _candidateUuids = [
    '0000ff01-0000-1000-8000-00805f9b34fb',
    '0000fff3-0000-1000-8000-00805f9b34fb',
    '0000ff02-0000-1000-8000-00805f9b34fb',
  ];

  GattMeshClient({required this.deviceProvider, this.fallback});

  @override
  Future<void> initialize(Map<String, String>? credentials) async {
    // GATT approach doesn't need mesh keys but store if needed by fallback
    await fallback?.initialize(credentials);
  }

  Future<BluetoothDevice?> _getDeviceByMac(String mac) async {
    dynamic con = FlutterBluePlus.connectedDevices;
    List<BluetoothDevice> devicesList;
    if (con is Future) {
      devicesList = await con;
    } else {
      devicesList = con as List<BluetoothDevice>;
    }
    try {
      return devicesList.firstWhere((d) => d.remoteId.toString() == mac);
    } catch (_) {}
    // attempt to find via scan results
    try {
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 3));
      final resList = await FlutterBluePlus.scanResults.first; // List<ScanResult>
      for (final r in resList) {
        if (r.device.remoteId.toString() == mac) {
          FlutterBluePlus.stopScan();
          return r.device;
        }
      }
      FlutterBluePlus.stopScan();
    } catch (_) {
      try {
        FlutterBluePlus.stopScan();
      } catch (_) {}
    }
    return null;
  }

  Future<BluetoothCharacteristic?> _findCharacteristic(BluetoothDevice device) async {
    try {
      final services = await device.discoverServices();
      for (final s in services) {
        for (final c in s.characteristics) {
          final uuid = c.uuid.toString().toLowerCase();
          if (_candidateUuids.contains(uuid)) return c;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<Map<String, bool>> getLightStates(List<String> macAddresses) async {
    final out = <String, bool>{};
    for (final mac in macAddresses) {
      out[mac] = false;
    }

    for (final mac in macAddresses) {
      final device = await _getDeviceByMac(mac);
      if (device == null) continue;
      try {
        // Required by latest FlutterBluePlus: provide license option
        await device.connect(license: License.free);
        final char = await _findCharacteristic(device);
        if (char == null) {
          await device.disconnect();
          continue;
        }
        final val = await char.read();
        await device.disconnect();
        out[mac] = val.isNotEmpty && val.first == 0x01;
      } catch (_) {
        try { await device.disconnect(); } catch (_) {}
      }
    }

    // If no states determined and fallback exists, use it
    if (out.values.every((v) => v == false) && fallback != null) {
      return fallback!.getLightStates(macAddresses);
    }

    return out;
  }

  @override
  Future<void> sendGroupMessage(int groupId) async {
    // Write toggled value to devices in the group
    final devices = deviceProvider();
    final toToggle = devices.where((d) => d.groupId == groupId).toList();
    if (toToggle.isEmpty) {
      // fallback to underlying implementation if available
      return fallback?.sendGroupMessage(groupId) ?? Future.value();
    }

    for (final d in toToggle) {
      BluetoothDevice? device = await _getDeviceByMac(d.macAddress);
      if (device == null) continue;
      try {
        // Required by latest FlutterBluePlus: provide license option
        await device.connect(license: License.free);
        final char = await _findCharacteristic(device);
        if (char == null) {
          await device.disconnect();
          continue;
        }
        // read current
        final cur = await char.read();
        final isOn = cur.isNotEmpty && cur.first == 0x01;
        final newVal = [isOn ? 0x00 : 0x01];
        await char.write(newVal, withoutResponse: true);
        await device.disconnect();
      } catch (_) {
        try { await device.disconnect(); } catch (_) {}
      }
    }
  }
}
