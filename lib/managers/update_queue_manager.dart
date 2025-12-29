import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../models/mesh_device.dart';
import '../models/update_progress.dart';
import '../models/update_task.dart';
import '../models/update_summary.dart';
import 'firmware_manager.dart';
import 'smp_client.dart';

/// Manages concurrent firmware update queue with rate limiting and retry logic.
///
/// Handles queuing, progress tracking, error recovery, and resource management
/// for multiple simultaneous firmware updates.
class UpdateQueueManager extends ChangeNotifier {
  final SMPClient smpClient;
  final int maxConcurrent;

  /// Per-device progress tracking
  final Map<String, UpdateProgress> _deviceProgress = {};

  /// Queue of pending update tasks
  final Queue<UpdateTask> _queue = Queue();

  /// Number of currently active updates
  int _activeUpdates = 0;

  /// Pause flag to stop processing queue
  bool _isPaused = false;

  /// Active update subscriptions
  final Map<String, StreamSubscription<UpdateProgress>> _activeSubscriptions = {};

  UpdateQueueManager({
    required this.smpClient,
    this.maxConcurrent = 10,
  });

  /// Get progress for a specific device
  UpdateProgress? getProgress(String macAddress) => _deviceProgress[macAddress];

  /// Get all device progress
  Map<String, UpdateProgress> get allProgress => Map.unmodifiable(_deviceProgress);

  /// Get overall update summary
  UpdateSummary get summary {
    final total = _deviceProgress.length;
    final completed = _deviceProgress.values
        .where((p) => p.stage == UpdateStage.complete)
        .length;
    final failed = _deviceProgress.values
        .where((p) => p.stage == UpdateStage.failed)
        .length;
    final inProgress = total - completed - failed;

    return UpdateSummary(
      total: total,
      completed: completed,
      failed: failed,
      inProgress: inProgress,
    );
  }

  /// Check if queue is currently paused
  bool get isPaused => _isPaused;

  /// Check if any updates are active
  bool get hasActiveUpdates => _activeUpdates > 0 || _queue.isNotEmpty;

  /// Start firmware updates for multiple devices.
  ///
  /// Queues all devices with matching firmware and begins processing
  /// up to [maxConcurrent] devices simultaneously.
  Future<void> startUpdates(
    List<MeshDevice> devices,
    FirmwareManager firmwareManager,
  ) async {
    for (final device in devices) {
      final firmware = firmwareManager.getFirmwareForDevice(device);
      if (firmware == null) {
        debugPrint('No firmware found for device ${device.identifier}');
        continue;
      }

      final task = UpdateTask(
        device: device,
        firmware: firmware,
        retryCount: 0,
        maxRetries: 3,
      );

      _queue.add(task);
      _deviceProgress[device.macAddress] = UpdateProgress.initial(device.macAddress);
    }

    notifyListeners();
    _processQueue();
  }

  /// Process update queue with concurrency limit.
  ///
  /// Pulls tasks from queue and starts updates until reaching [maxConcurrent]
  /// limit or queue is empty.
  Future<void> _processQueue() async {
    // Don't process if paused
    if (_isPaused) return;

    // Process up to maxConcurrent devices
    while (_queue.isNotEmpty &&
        _activeUpdates < maxConcurrent &&
        !_isPaused) {
      final task = _queue.removeFirst();
      _activeUpdates++;

      // Start update in background, then process next in queue
      _updateDevice(task).then((_) {
        _activeUpdates--;
        _processQueue(); // Process next task
      }).catchError((error) {
        debugPrint('Error processing update task: $error');
        _activeUpdates--;
        _processQueue();
      });

      // Small delay to prevent BLE stack congestion
      await Future.delayed(const Duration(milliseconds: 100));
    }

    // Notify when queue processing state changes
    notifyListeners();
  }

  /// Update firmware for a single device with retry logic.
  ///
  /// Handles progress streaming, error recovery, and retry with exponential backoff.
  Future<void> _updateDevice(UpdateTask task) async {
    final mac = task.device.macAddress;

    try {
      // Start progress stream
      final progressStream = smpClient.uploadFirmware(
        mac,
        task.firmware.data,
      );

      // Track start time
      _deviceProgress[mac] = UpdateProgress.initial(mac).copyWith(
        stage: UpdateStage.connecting,
        startedAt: DateTime.now(),
        totalBytes: task.firmware.sizeBytes,
      );
      notifyListeners();

      // Subscribe to progress updates
      final subscription = progressStream.listen(
        (progress) {
          _deviceProgress[mac] = progress;
          notifyListeners();

          // Handle completion
          if (progress.stage == UpdateStage.complete) {
            _onUpdateComplete(task);
          }

          // Handle failure
          if (progress.stage == UpdateStage.failed) {
            _onUpdateFailed(task, progress.errorMessage ?? 'Unknown error');
          }
        },
        onError: (error) {
          _onUpdateFailed(task, error.toString());
        },
        cancelOnError: true,
      );

      _activeSubscriptions[mac] = subscription;

      // Wait for completion
      await subscription.asFuture();
    } catch (e) {
      debugPrint('Update failed for ${task.device.identifier}: $e');
      _onUpdateFailed(task, e.toString());
    } finally {
      // Cleanup subscription
      _activeSubscriptions[mac]?.cancel();
      _activeSubscriptions.remove(mac);
    }
  }

  /// Handle successful update completion.
  Future<void> _onUpdateComplete(UpdateTask task) async {
    final mac = task.device.macAddress;
    debugPrint('Update completed for ${task.device.identifier}');

    // Mark as complete
    _deviceProgress[mac] = _deviceProgress[mac]!.copyWith(
      stage: UpdateStage.complete,
      completedAt: DateTime.now(),
    );
    notifyListeners();

    // Reset device to apply firmware
    try {
      await smpClient.resetDevice(mac);
      debugPrint('Device ${task.device.identifier} reset successfully');
    } catch (e) {
      debugPrint('Failed to reset device ${task.device.identifier}: $e');
      // Don't fail the update just because reset failed
      // User can manually power cycle if needed
    }
  }

  /// Handle update failure with retry logic.
  void _onUpdateFailed(UpdateTask task, String errorMessage) {
    final mac = task.device.macAddress;
    debugPrint('Update failed for ${task.device.identifier}: $errorMessage');

    // Check if we should retry
    if (task.canRetry) {
      task.retryCount++;
      debugPrint(
        'Scheduling retry ${task.retryCount}/${task.maxRetries} '
        'for ${task.device.identifier} after ${task.retryDelay.inSeconds}s',
      );

      // Mark as failed temporarily
      _deviceProgress[mac] = _deviceProgress[mac]!.copyWith(
        stage: UpdateStage.failed,
        errorMessage: 'Retry ${task.retryCount}/${task.maxRetries}...',
      );
      notifyListeners();

      // Schedule retry with exponential backoff
      Future.delayed(task.retryDelay, () {
        if (!_isPaused) {
          _queue.addFirst(task); // Priority: add to front of queue
          _processQueue();
        }
      });
    } else {
      // Max retries exceeded, mark as permanently failed
      debugPrint('Max retries exceeded for ${task.device.identifier}');
      _deviceProgress[mac] = _deviceProgress[mac]!.copyWith(
        stage: UpdateStage.failed,
        errorMessage: errorMessage,
        completedAt: DateTime.now(),
      );
      notifyListeners();
    }
  }

  /// Pause queue processing.
  ///
  /// Active updates continue, but no new updates start from queue.
  void pause() {
    if (!_isPaused) {
      _isPaused = true;
      debugPrint('Update queue paused');
      notifyListeners();
    }
  }

  /// Resume queue processing.
  ///
  /// Continues processing queued updates up to concurrency limit.
  void resume() {
    if (_isPaused) {
      _isPaused = false;
      debugPrint('Update queue resumed');
      notifyListeners();
      _processQueue();
    }
  }

  /// Cancel all pending and active updates.
  ///
  /// Clears queue and cancels active update subscriptions.
  void cancelAll() {
    debugPrint('Canceling all updates');

    // Clear queue
    _queue.clear();

    // Cancel active subscriptions
    for (final subscription in _activeSubscriptions.values) {
      subscription.cancel();
    }
    _activeSubscriptions.clear();

    // Mark in-progress updates as failed
    for (final entry in _deviceProgress.entries) {
      if (entry.value.stage != UpdateStage.complete &&
          entry.value.stage != UpdateStage.failed) {
        _deviceProgress[entry.key] = entry.value.copyWith(
          stage: UpdateStage.failed,
          errorMessage: 'Cancelled by user',
          completedAt: DateTime.now(),
        );
      }
    }

    _activeUpdates = 0;
    notifyListeners();
  }

  /// Clear completed and failed device progress.
  ///
  /// Removes progress entries for devices that finished updating.
  void clearProgress() {
    _deviceProgress.removeWhere((mac, progress) =>
        progress.stage == UpdateStage.complete ||
        progress.stage == UpdateStage.failed);
    notifyListeners();
  }

  @override
  void dispose() {
    // Cancel all active subscriptions
    for (final subscription in _activeSubscriptions.values) {
      subscription.cancel();
    }
    _activeSubscriptions.clear();
    _queue.clear();
    super.dispose();
  }
}
