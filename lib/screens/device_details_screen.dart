import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/mesh_device.dart';
import 'package:provider/provider.dart';
import '../managers/device_manager.dart';
import '../utils/mac_address.dart';

class DeviceDetailsScreen extends StatefulWidget {
  final MeshDevice device;
  const DeviceDetailsScreen({required this.device, super.key});

  @override
  State<DeviceDetailsScreen> createState() => _DeviceDetailsScreenState();
}

class _DeviceDetailsScreenState extends State<DeviceDetailsScreen> {
  BluetoothDevice? _bleDevice;
  bool _connected = false;
  String _status = 'Disconnected';
  List<BluetoothService> _services = [];
  final Map<String, List<BluetoothCharacteristic>> _chars = {};
  final List<String> _candidateUuids = [
    '0000ff01-0000-1000-8000-00805f9b34fb',
    '0000fff3-0000-1000-8000-00805f9b34fb',
    '0000ff02-0000-1000-8000-00805f9b34fb',
  ];
  int _battery = -1;
  bool _lightOn = false;
  bool _supportsProxy = false;
  bool _supportsBattery = false;
  late DeviceManager _dm;

  @override
  void initState() {
    super.initState();
    _dm = Provider.of<DeviceManager>(context, listen: false);
    _init();
  }

  Future<void> _init() async {
    // Try to find the flutterblue device by MAC from connected devices
    try {
      final dynamic con = FlutterBluePlus.connectedDevices;
      List<BluetoothDevice> devicesList = [];
      if (con is Future<List<BluetoothDevice>>) { devicesList = await con; }
      else if (con is List<BluetoothDevice>) { devicesList = con; }
      final mac = normalizeMac(widget.device.macAddress);
      BluetoothDevice? found;
      for (final d in devicesList) {
        final rid = normalizeMac(d.remoteId.toString());
        if (rid == mac) {
          found = d;
          break;
        }
      }
      setState(() => _bleDevice = found);
    } catch (_) {
      setState(() => _bleDevice = null);
    }
  }

  Future<BluetoothDevice?> _findDevice() async {
    if (_bleDevice != null) return _bleDevice;
    final mac = normalizeMac(widget.device.macAddress);
    final dm = _dm;

    try {
      // If the app is already scanning, avoid starting/stopping scan ourselves to reduce noise
      if (dm.isScanning) {
        final resList = await FlutterBluePlus.scanResults.first;
        for (final r in resList) {
          final rid = normalizeMac(r.device.remoteId.toString());
          if (rid == mac) {
            setState(() {
              _bleDevice = r.device;
            });
            return r.device;
          }
        }
        return null;
      }

      // Otherwise, try a short dedicated scan with timeout
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      final resList = await FlutterBluePlus.scanResults.first;
      for (final r in resList) {
        final rid = normalizeMac(r.device.remoteId.toString());
        if (rid == mac) {
          FlutterBluePlus.stopScan();
          setState(() {
            _bleDevice = r.device;
          });
          return r.device;
        }
      }
      FlutterBluePlus.stopScan();
    } catch (e) {
      try {
        FlutterBluePlus.stopScan();
      } catch (_) {}
      if (kDebugMode) debugPrint('findDevice scan failed: $e');
    }

    return null;
  }

  Future<void> _connect() async {
    final dm = _dm;
    final wasScanning = dm.isScanning;
    final device = await _findDevice();
    if (device != null) {
      if (wasScanning) dm.stopScanning(schedulePostScanRefresh: false);
      setState(() {
        _status = 'Connecting...';
      });
      try {
        await device.connect(license: License.free);
        if (!mounted) return;
        setState(() {
          _connected = true;
          _status = 'Connected';
          _bleDevice = device;
        });
        await _discover();
      } catch (e) {
        if (kDebugMode) debugPrint('Connect failed: $e');
        if (!mounted) return;
        setState(() {
          _status = 'Connect failed: $e';
        });
      } finally {
        if (wasScanning) dm.startBLEScanning();
      }
      return;
    }

    // Not found via FlutterBlue.
    // The Android MethodChannel "GATT helper" methods are stubs by design (see METHOD_CHANNEL_CONTRACT.md),
    // so DeviceDetailsScreen relies on FlutterBlue/GATT-only.
    setState(() {
      _status =
          'Device not found (scan). Ensure scanning is running and the device is nearby.';
    });
  }

  Future<void> _disconnect() async {
    final dm = _dm;
    try {
      await _bleDevice?.disconnect();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _connected = false;
      _status = 'Disconnected';
      _services = [];
      _chars.clear();
    });
    // If app scanning was previously stopped by _connect, start it again
    try {
      if (!dm.isScanning) dm.startBLEScanning();
    } catch (_) {}
  }

  Future<void> _discover() async {
    final device = _bleDevice;
    if (device == null) return;
    try {
      _services = await device.discoverServices();
    } catch (_) {
      _services = [];
    }
    _chars.clear();
    for (final s in _services) {
      _chars[s.uuid.toString()] = s.characteristics;
    }
    setState(() {});
    // Attempt to read battery char if present
    _supportsProxy =
        _services.any((s) => s.uuid.toString().toLowerCase().contains('1828'));
    _supportsBattery =
        _services.any((s) => s.uuid.toString().toLowerCase().contains('180f'));
    await _readBattery();
    if (!mounted) return;
    final dm = _dm;
    // Read the candidate OnOff char if present to determine initial state
    for (final s in _services) {
      for (final c in s.characteristics) {
        final uuid = c.uuid.toString().toLowerCase();
        if (_candidateUuids.contains(uuid) && c.properties.read) {
          try {
            final val = await c.read();
            final on = val.isNotEmpty && val.first == 0x01;
            setState(() => _lightOn = on);
            try {
              dm.updateDeviceState(widget.device.macAddress, lightOn: on);
            } catch (_) {}
            break;
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _readBattery() async {
    final device = _bleDevice;
    if (device == null) {
      return;
    }
    final dm = context.read<DeviceManager>();
    for (final s in _services) {
      for (final c in s.characteristics) {
        if (c.uuid.toString().toLowerCase().contains('00002a19')) {
          try {
            if (kDebugMode) {
              debugPrint('DeviceDetails: reading battery from ${c.uuid}');
            }
            final val = await c.read();
            if (val.isNotEmpty) {
              final percent = val.first & 0xff;
              setState(() => _battery = percent);
              try {
                dm.updateDeviceState(widget.device.macAddress,
                    batteryPercent: percent);
              } catch (_) {}
            }
          } catch (e) {
            if (kDebugMode) debugPrint('DeviceDetails: battery read failed $e');
          }
        }
      }
    }
  }

  Future<void> _toggleCandidate() async {
    final device = _bleDevice;
    final dm = context.read<DeviceManager>();
    if (device == null) {
      // Try to toggle via meshClient plugin fallback
      final client = dm.meshClient;
      try {
        await client.sendGroupMessage(0, [widget.device.macAddress]);
        final states = await client.getLightStates([widget.device.macAddress]);
        final on = states[widget.device.macAddress] ?? false;
        setState(() {
          _lightOn = on;
        });
        try {
          dm.updateDeviceState(widget.device.macAddress, lightOn: on);
        } catch (_) {}
      } catch (e) {
        if (kDebugMode) debugPrint('Native toggle attempt failed: $e');
      }
      return;
    }

    // find vendor candidate char usable for On/Off
    BluetoothCharacteristic? candidate;
    for (final s in _services) {
      for (final c in s.characteristics) {
        final uuid = c.uuid.toString().toLowerCase();
        if (_candidateUuids.contains(uuid)) {
          candidate = c;
          break;
        }
      }
      if (candidate != null) break;
    }
    if (candidate == null) {
      if (kDebugMode) debugPrint('No candidate characteristic found for toggle');
      return;
    }
    try {
      final cur = await candidate.read();
      final isOn = cur.isNotEmpty && cur.first == 0x01;
      final newVal = isOn ? [0x00] : [0x01];
      final supportsWrite = candidate.properties.write;
      if (supportsWrite) {
        await candidate.write(newVal, withoutResponse: false);
      } else {
        await candidate.write(newVal, withoutResponse: true);
      }
      // short delay then read back
      await Future.delayed(const Duration(milliseconds: 150));
      final check = await candidate.read();
      final on = check.isNotEmpty && check.first == 0x01;
      setState(() {
        _lightOn = on;
      });
      try {
        dm.updateDeviceState(widget.device.macAddress, lightOn: on);
      } catch (_) {}
    } catch (e) {
      if (kDebugMode) debugPrint('Toggle write failed: $e');
    }
  }

  Future<void> _subscribeToNotifies() async {
    final device = _bleDevice; if (device == null) return;
    final dm = context.read<DeviceManager>();
    for (final s in _services) {
      for (final c in s.characteristics) {
        if (c.properties.notify) {
          try {
            await c.setNotifyValue(true);
            c.lastValueStream.listen((val) {
              if (kDebugMode) debugPrint('DeviceDetails: notify ${c.uuid} -> $val');
              if (!mounted) return;
              // update battery if this is battery char
              if (c.uuid.toString().toLowerCase().contains('00002a19') && val.isNotEmpty) {
                final percent = val.first & 0xff;
                setState(() => _battery = percent);
                try { dm.updateDeviceState(widget.device.macAddress, batteryPercent: percent); } catch (_) {}
              }
              if (_candidateUuids.contains(c.uuid.toString().toLowerCase())) {
                final on = val.isNotEmpty && val.first == 0x01;
                setState(() => _lightOn = on);
                try { dm.updateDeviceState(widget.device.macAddress, lightOn: on); } catch (_) {}
              }
            });
          } catch (_) {}
        }
      }
    }
  }

  @override
  void dispose() {
    try {
      _disconnect();
    } catch (_) {}
    super.dispose();
  }

  Widget _serviceTile(BluetoothService s) {
    final chars = s.characteristics;
    final dm = context.read<DeviceManager>();
    return ExpansionTile(
      title: Text('Service: ${s.uuid}'),
      children: chars.map((c) => ListTile(
        title: Text('Char: ${c.uuid}'),
        subtitle: Text('properties: r=${c.properties.read} w=${c.properties.write} nr=${c.properties.notify}'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (c.properties.read) IconButton(icon: const Icon(Icons.read_more), onPressed: () async {
            try {
              final val = await c.read();
              if (kDebugMode) debugPrint('Read ${c.uuid} -> $val');
              if (c.uuid.toString().toLowerCase().contains('00002a19') && val.isNotEmpty) {
                final percent = val.first & 0xff;
                setState(() => _battery = percent);
                try { dm.updateDeviceState(widget.device.macAddress, batteryPercent: percent); } catch (_) {}
              }
            } catch (_) {}
          }),
          if (c.properties.write || c.properties.writeWithoutResponse) IconButton(icon: const Icon(Icons.power_settings_new), onPressed: () async {
            try {
              final cur = await c.read();
              final isOn = cur.isNotEmpty && cur.first == 0x01;
              final newVal = isOn ? [0x00] : [0x01];
              await c.write(newVal, withoutResponse: !c.properties.write);
              await Future.delayed(const Duration(milliseconds: 150));
              final check = await c.read();
              if (_candidateUuids.contains(c.uuid.toString().toLowerCase())) {
                final on = check.isNotEmpty && check.first == 0x01;
                setState(() => _lightOn = on);
                try { dm.updateDeviceState(widget.device.macAddress, lightOn: on); } catch (_) {}
              }
            } catch (_) {}
          }),
        ]),
      )).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    return Scaffold(
      appBar: AppBar(title: Text('${d.identifier} - Details')),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('MAC: ${d.macAddress}'),
            const SizedBox(height: 8),
            Text('HW: ${d.hardwareId}'),
            const SizedBox(height: 8),
            Row(children: [Text('Version: ${d.version}'), const SizedBox(width: 16), Text('RSSI: ${d.rssi}dBm')]),
            const SizedBox(height: 8),
            Text('Status: $_status'),
            const SizedBox(height: 8),
              Text('Proxy: ${_supportsProxy ? 'Yes' : 'No'} • Battery Service: ${_supportsBattery ? 'Yes' : 'No'}'),
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('Guidance: Connect then Discover services. Look for "Battery (0x180F)", "SMP (8D53...)" or "Proxy (0x1828)". Use Toggle/Subscribe for Vendor OnOff chars.'),
              ),
            const SizedBox(height: 8),
            Row(children: [
              const Text('Battery: '),
              Text(_battery >= 0 ? '$_battery%' : 'Unknown'),
              const SizedBox(width: 16),
              if (_lightOn) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              ElevatedButton(onPressed: _connected ? _disconnect : _connect, child: Text(_connected ? 'Disconnect' : 'Connect')),
              ElevatedButton(onPressed: _connected ? _discover : null, child: const Text('Discover')),
              ElevatedButton(onPressed: _connected ? _readBattery : null, child: const Text('Read Battery Now')),
              ElevatedButton(onPressed: _connected ? _toggleCandidate : null, child: const Text('Toggle Candidate')),
              ElevatedButton(onPressed: _connected ? _subscribeToNotifies : null, child: const Text('Subscribe')),            
            ]),
            const SizedBox(height: 16),
                  if (_services.isEmpty) const Text('No services discovered yet') else Column(children: _services.map((s) => _serviceTile(s)).toList()),
          ]),
        ),
      ),
    );
  }
}
