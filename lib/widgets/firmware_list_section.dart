import 'package:flutter/material.dart';
import '../models/firmware_file.dart';
import 'firmware_card.dart';

/// Section displaying loaded firmware files with a file picker button.
///
/// Shows horizontal scrolling list of firmware cards or empty state.
class FirmwareListSection extends StatelessWidget {
  final List<FirmwareFile> firmware;
  final VoidCallback onLoadFirmware;
  final void Function(String hardwareId) onRemoveFirmware;

  const FirmwareListSection({
    super.key,
    required this.firmware,
    required this.onLoadFirmware,
    required this.onRemoveFirmware,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Firmware Files',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: onLoadFirmware,
                  icon: const Icon(Icons.file_upload, size: 20),
                  label: const Text('Load Firmware'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (firmware.isEmpty)
              // Empty state
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32.0),
                  child: Column(
                    children: [
                      Icon(
                        Icons.folder_open,
                        size: 64,
                        color: theme.colorScheme.onSurfaceVariant
                            .withOpacity(0.5),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No firmware loaded',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Load a .signed.bin file to begin',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant
                              .withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              // Firmware cards (horizontal scroll if needed)
              SizedBox(
                height: 140,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: firmware.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(width: 12),
                  itemBuilder: (context, index) {
                    final fw = firmware[index];
                    return SizedBox(
                      width: 200,
                      child: FirmwareCard(
                        firmware: fw,
                        onRemove: () => onRemoveFirmware(fw.hardwareId),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
