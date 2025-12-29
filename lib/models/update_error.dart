/// Error types for firmware update failures
enum UpdateErrorType {
  connectionFailed,      // Can't connect to device
  uploadFailed,          // Upload interrupted
  verificationFailed,    // Image verification failed
  resetFailed,           // Device reset failed
  timeout,               // Operation timed out
  deviceNotFound,        // Device disappeared
  insufficientStorage,   // Not enough space on device
  cancelled,             // Update was cancelled
  unknown,               // Unknown error
}

/// Structured error information for firmware update failures
class UpdateError {
  final UpdateErrorType type;
  final String message;
  final String? technicalDetails;
  final DateTime timestamp;

  UpdateError({
    required this.type,
    required this.message,
    this.technicalDetails,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Create an error from a platform exception or error message
  factory UpdateError.fromMessage(String message) {
    final lowercaseMsg = message.toLowerCase();
    
    UpdateErrorType type;
    if (lowercaseMsg.contains('connection') || 
        lowercaseMsg.contains('connect')) {
      type = UpdateErrorType.connectionFailed;
    } else if (lowercaseMsg.contains('upload') ||
               lowercaseMsg.contains('transfer')) {
      type = UpdateErrorType.uploadFailed;
    } else if (lowercaseMsg.contains('verif') ||
               lowercaseMsg.contains('invalid image')) {
      type = UpdateErrorType.verificationFailed;
    } else if (lowercaseMsg.contains('reset')) {
      type = UpdateErrorType.resetFailed;
    } else if (lowercaseMsg.contains('timeout') ||
               lowercaseMsg.contains('timed out')) {
      type = UpdateErrorType.timeout;
    } else if (lowercaseMsg.contains('not found') ||
               lowercaseMsg.contains('disappeared')) {
      type = UpdateErrorType.deviceNotFound;
    } else if (lowercaseMsg.contains('storage') ||
               lowercaseMsg.contains('insufficient space')) {
      type = UpdateErrorType.insufficientStorage;
    } else if (lowercaseMsg.contains('cancel')) {
      type = UpdateErrorType.cancelled;
    } else {
      type = UpdateErrorType.unknown;
    }

    return UpdateError(
      type: type,
      message: message,
      technicalDetails: message,
    );
  }

  /// Factory constructor for unknown errors
  factory UpdateError.unknown(String technicalDetails) {
    return UpdateError(
      type: UpdateErrorType.unknown,
      message: 'An unexpected error occurred',
      technicalDetails: technicalDetails,
    );
  }

  /// Factory constructor for timeout errors
  factory UpdateError.timeout(String? details) {
    return UpdateError(
      type: UpdateErrorType.timeout,
      message: 'Update timed out',
      technicalDetails: details,
    );
  }

  /// Factory constructor for connection errors
  factory UpdateError.connectionFailed(String? details) {
    return UpdateError(
      type: UpdateErrorType.connectionFailed,
      message: 'Failed to connect to device',
      technicalDetails: details,
    );
  }

  /// Factory constructor for upload errors
  factory UpdateError.uploadFailed(String? details) {
    return UpdateError(
      type: UpdateErrorType.uploadFailed,
      message: 'Firmware upload failed',
      technicalDetails: details,
    );
  }

  /// Get user-friendly error message based on error type
  String getUserMessage() {
    switch (type) {
      case UpdateErrorType.connectionFailed:
        return "Can't connect to device. Make sure it's nearby and powered on.";
      case UpdateErrorType.uploadFailed:
        return "Upload interrupted. Check Bluetooth connection.";
      case UpdateErrorType.verificationFailed:
        return "Firmware verification failed. Try re-downloading the file.";
      case UpdateErrorType.resetFailed:
        return "Device reset failed. Try power cycling the device.";
      case UpdateErrorType.timeout:
        return "Update timed out. Device may be out of range.";
      case UpdateErrorType.deviceNotFound:
        return "Device not found. Make sure it's powered on and in range.";
      case UpdateErrorType.insufficientStorage:
        return "Not enough storage space on device.";
      case UpdateErrorType.cancelled:
        return "Update was cancelled.";
      case UpdateErrorType.unknown:
        return message.isNotEmpty ? message : "An unexpected error occurred.";
    }
  }

  /// Get a short description of the error type
  String getTypeDescription() {
    switch (type) {
      case UpdateErrorType.connectionFailed:
        return "Connection Error";
      case UpdateErrorType.uploadFailed:
        return "Upload Error";
      case UpdateErrorType.verificationFailed:
        return "Verification Error";
      case UpdateErrorType.resetFailed:
        return "Reset Error";
      case UpdateErrorType.timeout:
        return "Timeout";
      case UpdateErrorType.deviceNotFound:
        return "Device Not Found";
      case UpdateErrorType.insufficientStorage:
        return "Storage Error";
      case UpdateErrorType.cancelled:
        return "Cancelled";
      case UpdateErrorType.unknown:
        return "Unknown Error";
    }
  }

  @override
  String toString() {
    return 'UpdateError(${getTypeDescription()}: ${getUserMessage()})';
  }
}
