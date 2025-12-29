import 'package:flutter/material.dart';
import '../models/firmware_file.dart';

/// Card widget to display loaded firmware file information.
///
/// Shows hardware ID, version, file size, and provides a remove button.
class FirmwareCard extends StatelessWidget {
  final FirmwareFile firmware;
  final VoidCallback onRemove;

  const FirmwareCard({
    super.key,
    required this.firmware,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          // Could expand to show more details in the future
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  // Hardware ID badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      firmware.hardwareId,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Remove button
                  IconButton(
                    icon: const Icon(Icons.close),
                    iconSize: 20,
                    tooltip: 'Remove firmware',
                    onPressed: onRemove,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // Version
              Text(
                'Version ${firmware.version.toDisplayString()}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              // File info
              Text(
                '${(firmware.sizeBytes / 1024).toStringAsFixed(1)} KB',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.textTheme.bodySmall?.color?.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                firmware.fileName,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.textTheme.bodySmall?.color?.withOpacity(0.7),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
