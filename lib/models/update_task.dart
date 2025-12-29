import 'firmware_file.dart';
import 'mesh_device.dart';

/// Represents a single firmware update task in the queue.
///
/// Tracks device, firmware, and retry state for queued updates.
class UpdateTask {
  final MeshDevice device;
  final FirmwareFile firmware;
  int retryCount;
  final int maxRetries;

  UpdateTask({
    required this.device,
    required this.firmware,
    this.retryCount = 0,
    this.maxRetries = 3,
  });

  /// Check if this task can be retried
  bool get canRetry => retryCount < maxRetries;

  /// Get exponential backoff delay for retries
  Duration get retryDelay {
    // 2s, 4s, 8s for retry 0, 1, 2
    return Duration(seconds: 2 << retryCount);
  }

  @override
  String toString() =>
      'UpdateTask(${device.identifier}, ${firmware.displayName}, retry: $retryCount/$maxRetries)';
}
