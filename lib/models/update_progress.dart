/// Stages of firmware update process with progress percentage ranges.
enum UpdateStage {
  idle, // Not started
  connecting, // 0-10%
  uploading, // 10-80%
  verifying, // 80-95%
  rebooting, // 95-100%
  complete,
  failed,
}

/// Tracks progress of a firmware update for a single device.
class UpdateProgress {
  final String deviceMac;
  final int bytesTransferred;
  final int totalBytes;
  final UpdateStage stage;
  final String? errorMessage;
  final DateTime? startedAt;
  final DateTime? completedAt;

  const UpdateProgress({
    required this.deviceMac,
    required this.bytesTransferred,
    required this.totalBytes,
    required this.stage,
    this.errorMessage,
    this.startedAt,
    this.completedAt,
  });

  /// Create initial progress state
  factory UpdateProgress.initial(String deviceMac) {
    return UpdateProgress(
      deviceMac: deviceMac,
      bytesTransferred: 0,
      totalBytes: 0,
      stage: UpdateStage.idle,
    );
  }

  /// Calculate overall progress percentage (0-100)
  double get percentage {
    switch (stage) {
      case UpdateStage.idle:
        return 0.0;
      case UpdateStage.connecting:
        return 5.0;
      case UpdateStage.uploading:
        if (totalBytes == 0) return 10.0;
        // Map bytes to 10-80% range
        final uploadPercent = (bytesTransferred / totalBytes) * 70.0;
        return 10.0 + uploadPercent;
      case UpdateStage.verifying:
        return 87.0;
      case UpdateStage.rebooting:
        return 97.0;
      case UpdateStage.complete:
        return 100.0;
      case UpdateStage.failed:
        return percentage; // Keep last known percentage
    }
  }

  /// Elapsed time since update started
  Duration? get elapsedTime {
    if (startedAt == null) return null;
    final endTime = completedAt ?? DateTime.now();
    return endTime.difference(startedAt!);
  }

  /// Human-readable status message
  String get statusMessage {
    switch (stage) {
      case UpdateStage.idle:
        return 'Ready';
      case UpdateStage.connecting:
        return 'Connecting to device...';
      case UpdateStage.uploading:
        if (totalBytes > 0) {
          final kb = bytesTransferred ~/ 1024;
          final totalKb = totalBytes ~/ 1024;
          return 'Uploading: $kb KB / $totalKb KB';
        }
        return 'Uploading firmware...';
      case UpdateStage.verifying:
        return 'Verifying firmware...';
      case UpdateStage.rebooting:
        return 'Rebooting device...';
      case UpdateStage.complete:
        return 'Update complete';
      case UpdateStage.failed:
        return errorMessage ?? 'Update failed';
    }
  }

  /// Create a copy with updated fields
  UpdateProgress copyWith({
    int? bytesTransferred,
    int? totalBytes,
    UpdateStage? stage,
    String? errorMessage,
    DateTime? startedAt,
    DateTime? completedAt,
  }) {
    return UpdateProgress(
      deviceMac: deviceMac,
      bytesTransferred: bytesTransferred ?? this.bytesTransferred,
      totalBytes: totalBytes ?? this.totalBytes,
      stage: stage ?? this.stage,
      errorMessage: errorMessage ?? this.errorMessage,
      startedAt: startedAt ?? this.startedAt,
      completedAt: completedAt ?? this.completedAt,
    );
  }

  @override
  String toString() => 'UpdateProgress($deviceMac: ${percentage.toStringAsFixed(1)}% - $statusMessage)';
}
