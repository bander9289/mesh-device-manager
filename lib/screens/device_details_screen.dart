import 'package:flutter/material.dart';
import '../models/mesh_device.dart';

class DeviceDetailsScreen extends StatelessWidget {
  final MeshDevice device;
  const DeviceDetailsScreen({required this.device, super.key});

  @override
  Widget build(BuildContext context) {
    final d = device;
    return Scaffold(
      appBar: AppBar(title: Text('${d.identifier} - Details')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildInfoRow('MAC Address', d.macAddress),
            const SizedBox(height: 12),
            _buildInfoRow('Hardware ID', d.hardwareId),
            const SizedBox(height: 12),
            _buildInfoRow('Firmware Version', d.version),
            const SizedBox(height: 12),
            _buildInfoRow('Signal Strength', '${d.rssi} dBm'),
            const SizedBox(height: 12),
            _buildInfoRow(
              'Battery Level',
              d.batteryPercent < 0 ? 'Unknown' : '${d.batteryPercent}%',
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            const Text(
              'Additional functionality will be added in future releases.',
              style: TextStyle(
                fontStyle: FontStyle.italic,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            '$label:',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Expanded(
          child: Text(value),
        ),
      ],
    );
  }
}
