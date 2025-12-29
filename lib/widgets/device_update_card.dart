import 'package:flutter/material.dart';
import '../models/firmware_file.dart';
import '../models/mesh_device.dart';
import '../models/firmware_version.dart';
import '../models/update_progress.dart';

/// Status indicator for device firmware update availability.
enum UpdateStatus {
  upToDate,      // Green check
  updateAvailable, // Orange arrow up
  downgrade,     // Red arrow down
  hashMismatch,  // Yellow warning
  reflashAvailable, // Blue refresh
}

/// Card widget displaying device update information with progress tracking.
///
/// Shows device info, current/target versions, update status, progress,
/// and provides selection checkbox in manual mode.
class DeviceUpdateCard extends StatelessWidget {
  final MeshDevice device;
  final FirmwareFile firmware;
  final bool isSelected;
  final bool showCheckbox; // True in manual selection mode
  final UpdateProgress? progress;
  final ValueChanged<bool>? onSelectionChanged;
  final VoidCallback? onReflash;
  final VoidCallback? onRetry;

  const DeviceUpdateCard({
    super.key,
    required this.device,
    required this.firmware,
    required this.isSelected,
    this.showCheckbox = false,
    this.progress,
    this.onSelectionChanged,
    this.onReflash,
    this.onRetry,
  });

  UpdateStatus _getUpdateStatus() {
    final deviceVersion = FirmwareVersion.parse(device.version);
    
    if (firmware.version > deviceVersion) {
      return UpdateStatus.updateAvailable;
    } else if (firmware.version < deviceVersion) {
      return UpdateStatus.downgrade;
    } else if (firmware.version.hasDifferentHash(deviceVersion)) {
      return UpdateStatus.hashMismatch;
    } else {
      return UpdateStatus.upToDate;
    }
  }

  (IconData, Color, String) _getStatusInfo(BuildContext context, UpdateStatus status) {
    final colorScheme = Theme.of(context).colorScheme;
    
    switch (status) {
      case UpdateStatus.upToDate:
        return (Icons.check_circle, Colors.green, 'Up to date');
      case UpdateStatus.updateAvailable:
        return (Icons.arrow_upward, Colors.orange, 'Update available');
      case UpdateStatus.downgrade:
        return (Icons.arrow_downward, Colors.red, 'Downgrade');
      case UpdateStatus.hashMismatch:
        return (Icons.warning, Colors.orange.shade700, 'Different build');
      case UpdateStatus.reflashAvailable:
        return (Icons.refresh, Colors.blue, 'Re-flash available');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final status = _getUpdateStatus();
    final (statusIcon, statusColor, statusText) = _getStatusInfo(context, status);
    final deviceVersion = FirmwareVersion.parse(device.version);
    final isUpdating = progress != null && 
                       progress!.stage != UpdateStage.idle &&
                       progress!.stage != UpdateStage.complete &&
                       progress!.stage != UpdateStage.failed;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Checkbox (if manual selection mode)
                if (showCheckbox)
                  Checkbox(
                    value: isSelected,
                    onChanged: onSelectionChanged != null && !isUpdating
                        ? (value) => onSelectionChanged!(value ?? false)
                        : null,
                  ),
                
                // Device identifier (last 6 MAC nibbles)
                Text(
                  device.macAddress.substring(device.macAddress.length - 8),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 12),
                
                // Hardware ID badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    device.hardwareId,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                
                const Spacer(),
                
                // Status indicator
                Icon(statusIcon, color: statusColor, size: 24),
              ],
            ),
            
            const SizedBox(height: 12),
            
            // Version comparison
            Row(
              children: [
                Text(
                  deviceVersion.toDisplayString(),
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(width: 8),
                Icon(Icons.arrow_forward, size: 16, color: statusColor),
                const SizedBox(width: 8),
                Text(
                  firmware.version.toDisplayString(),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
              ],
            ),
            
            const SizedBox(height: 8),
            
            // Status text or progress
            if (progress != null && isUpdating) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress!.percentage / 100.0,
                backgroundColor: colorScheme.surfaceContainerHighest,
              ),
              const SizedBox(height: 8),
              Text(
                progress!.statusMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.primary,
                ),
              ),
            ] else if (progress != null && progress!.stage == UpdateStage.complete) ...[
              Row(
                children: [
                  Icon(Icons.check_circle, color: Colors.green, size: 16),
                  const SizedBox(width: 4),
                  Text(
                    'Update complete',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.green,
                    ),
                  ),
                ],
              ),
            ] else if (progress != null && progress!.stage == UpdateStage.failed) ...[
              // Error display with user-friendly message
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error, color: Colors.red, size: 16),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          progress!.error?.getUserMessage() ?? 
                          _getUserFriendlyError(progress!.errorMessage),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.red,
                          ),
                        ),
                        // Technical details expansion if available
                        if (progress!.error?.technicalDetails != null &&
                            progress!.error!.technicalDetails!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Theme(
                            data: theme.copyWith(
                              dividerColor: Colors.transparent,
                            ),
                            child: ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              childrenPadding: const EdgeInsets.only(
                                left: 12,
                                top: 4,
                                bottom: 4,
                              ),
                              title: Text(
                                'Technical Details',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: colorScheme.surfaceContainerHighest,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: SelectableText(
                                    progress!.error!.technicalDetails!,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontFamily: 'monospace',
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.orange,
                  ),
                ),
              ],
            ] else ...[
              Text(
                statusText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: statusColor,
                ),
              ),
            ],
            
            // Re-flash button (if same version)
            if (onReflash != null && 
                status == UpdateStatus.upToDate && 
                !isUpdating) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onReflash,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Re-flash'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.blue,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getUserFriendlyError(String? errorMessage) {
    if (errorMessage == null) return 'Update failed';
    
    // Map platform error codes to user-friendly messages
    if (errorMessage.contains('CONNECTION_FAILED')) {
      return "Can't connect to device. Make sure it's nearby and powered on.";
    }
    if (errorMessage.contains('UPLOAD_FAILED')) {
      return "Upload interrupted. Check Bluetooth connection.";
    }
    if (errorMessage.contains('VERIFICATION_FAILED')) {
      return "Firmware verification failed. Try re-downloading the file.";
    }
    if (errorMessage.contains('RESET_FAILED')) {
      return "Device reset failed. Try power cycling the device.";
    }
    if (errorMessage.contains('timeout') || errorMessage.contains('TIMEOUT')) {
      return "Update timed out. Device may be out of range.";
    }
    
    // Fallback to raw message
    return errorMessage;
  }
}
