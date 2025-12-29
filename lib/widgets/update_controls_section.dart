import 'package:flutter/material.dart';

/// Device selection modes for firmware updates.
enum DeviceSelectionMode {
  all('All Devices'),
  none('None'),
  outOfDate('Out-of-Date Only'),
  manual('Manual Selection');

  final String label;
  const DeviceSelectionMode(this.label);
}

/// Update controls section with device selection dropdown and force update options.
///
/// Provides:
/// - Device selection mode dropdown
/// - Allow Downgrade checkbox with warning
/// - Update Selected and Update All buttons
class UpdateControlsSection extends StatelessWidget {
  final DeviceSelectionMode selectionMode;
  final ValueChanged<DeviceSelectionMode> onSelectionModeChanged;
  final bool allowDowngrade;
  final ValueChanged<bool> onAllowDowngradeChanged;
  final int selectedDeviceCount;
  final int totalDeviceCount;
  final VoidCallback? onUpdateSelected;
  final VoidCallback? onUpdateAll;
  final bool isUpdating;

  const UpdateControlsSection({
    super.key,
    required this.selectionMode,
    required this.onSelectionModeChanged,
    required this.allowDowngrade,
    required this.onAllowDowngradeChanged,
    required this.selectedDeviceCount,
    required this.totalDeviceCount,
    this.onUpdateSelected,
    this.onUpdateAll,
    this.isUpdating = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Device Selection Dropdown
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<DeviceSelectionMode>(
                    value: selectionMode,
                    decoration: InputDecoration(
                      labelText: 'Device Selection',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    items: DeviceSelectionMode.values
                        .map((mode) => DropdownMenuItem(
                              value: mode,
                              child: Text(mode.label),
                            ))
                        .toList(),
                    onChanged: isUpdating
                        ? null
                        : (value) {
                            if (value != null) {
                              onSelectionModeChanged(value);
                            }
                          },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Allow Downgrade Checkbox
            Row(
              children: [
                Checkbox(
                  value: allowDowngrade,
                  onChanged: isUpdating
                      ? null
                      : (value) {
                          if (value != null) {
                            onAllowDowngradeChanged(value);
                          }
                        },
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.warning,
                  color: Colors.orange,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Allow Downgrade',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Enable to install older firmware versions',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.textTheme.bodySmall?.color
                              ?.withOpacity(0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // Selection summary
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    color: colorScheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '$selectedDeviceCount of $totalDeviceCount device(s) selected',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // Update buttons
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: onUpdateSelected != null &&
                            selectedDeviceCount > 0 &&
                            !isUpdating
                        ? onUpdateSelected
                        : null,
                    icon: isUpdating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.upload),
                    label: Text(
                      isUpdating ? 'Updating...' : 'Update Selected',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onUpdateAll != null &&
                            totalDeviceCount > 0 &&
                            !isUpdating
                        ? onUpdateAll
                        : null,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Update All'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
