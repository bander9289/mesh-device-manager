import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/firmware_file.dart';
import '../models/firmware_version.dart';
import '../models/mesh_device.dart';

/// Exception thrown when firmware file validation fails
class FirmwareFileException implements Exception {
  final String message;
  const FirmwareFileException(this.message);
  
  @override
  String toString() => 'FirmwareFileException: $message';
}

/// Exception thrown when firmware file exceeds size limit
class FileSizeException implements Exception {
  final String message;
  const FileSizeException(this.message);
  
  @override
  String toString() => 'FileSizeException: $message';
}

/// Centralized firmware file management with version comparison.
///
/// Handles loading, validation, and matching firmware files to devices.
/// Notifies listeners when firmware is loaded or removed.
class FirmwareManager extends ChangeNotifier {
  static const int maxFileSizeBytes = 2 * 1024 * 1024; // 2MB

  final Map<String, FirmwareFile> _firmwareByHardwareId = {};
  bool _allowDowngrade = false;

  /// Get all loaded firmware files
  List<FirmwareFile> get loadedFirmware => _firmwareByHardwareId.values.toList();

  /// Get firmware indexed by hardware ID
  Map<String, FirmwareFile> get firmwareByHardwareId =>
      Map.unmodifiable(_firmwareByHardwareId);

  /// Get or set whether downgrade updates are allowed
  bool get allowDowngrade => _allowDowngrade;
  set allowDowngrade(bool value) {
    if (_allowDowngrade != value) {
      _allowDowngrade = value;
      notifyListeners();
    }
  }

  /// Load and validate a firmware file from the given path.
  ///
  /// Throws:
  /// - [FileSystemException] if file doesn't exist or can't be read
  /// - [FileSizeException] if file exceeds 2MB limit
  /// - [FirmwareFileException] if filename format is invalid
  Future<FirmwareFile> loadFirmware(String filePath) async {
    final file = File(filePath);

    // Check file exists
    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    // Check file size
    final fileSize = await file.length();
    if (fileSize > maxFileSizeBytes) {
      throw FileSizeException(
        'Firmware file exceeds 2MB limit: ${fileSize ~/ 1024}KB',
      );
    }

    // Read file data
    final data = await file.readAsBytes();

    // Parse and validate filename format
    final firmware = FirmwareFile.fromFile(
      filePath: filePath,
      data: data,
    );

    // Check for duplicate hardware ID
    final existing = _firmwareByHardwareId[firmware.hardwareId];
    if (existing != null) {
      // For now, replace existing firmware. UI can prompt user later if needed.
      debugPrint(
        'Replacing existing firmware for ${firmware.hardwareId}: '
        '${existing.version} → ${firmware.version}',
      );
    }

    _firmwareByHardwareId[firmware.hardwareId] = firmware;
    notifyListeners();

    return firmware;
  }

  /// Remove loaded firmware for a specific hardware ID
  void removeFirmware(String hardwareId) {
    if (_firmwareByHardwareId.remove(hardwareId) != null) {
      notifyListeners();
    }
  }

  /// Find firmware file that matches the device's hardware ID
  FirmwareFile? getFirmwareForDevice(MeshDevice device) {
    return _firmwareByHardwareId[device.hardwareId];
  }

  /// Check if device needs update based on version comparison.
  ///
  /// Parameters:
  /// - [device]: The device to check
  /// - [ignoreVersion]: If true, always return true (force update mode)
  ///
  /// Returns true if:
  /// - ignoreVersion is true, OR
  /// - firmware version > device version, OR
  /// - allowDowngrade is true AND firmware version < device version
  bool needsUpdate(MeshDevice device, {bool ignoreVersion = false}) {
    final firmware = getFirmwareForDevice(device);
    if (firmware == null) return false;

    if (ignoreVersion) return true;

    final deviceVersion = FirmwareVersion.parse(device.version);
    
    // Normal update: firmware is newer
    if (firmware.version > deviceVersion) return true;

    // Downgrade: firmware is older but downgrade allowed
    if (_allowDowngrade && firmware.version < deviceVersion) return true;

    return false;
  }

  /// Check if device can be downgraded to the available firmware.
  ///
  /// Returns true if firmware version is lower than device version
  /// and downgrade is allowed.
  bool canDowngrade(MeshDevice device, FirmwareFile firmware) {
    final deviceVersion = FirmwareVersion.parse(device.version);
    return _allowDowngrade && firmware.version < deviceVersion;
  }

  /// Check if available firmware has same version but different hash.
  ///
  /// This indicates a rebuild or variant of the same version.
  bool hasHashMismatch(MeshDevice device, FirmwareFile firmware) {
    final deviceVersion = FirmwareVersion.parse(device.version);
    return firmware.version.hasDifferentHash(deviceVersion);
  }

  /// Check if firmware can be re-flashed (same version and hash).
  bool canReflash(MeshDevice device, FirmwareFile firmware) {
    final deviceVersion = FirmwareVersion.parse(device.version);
    return firmware.version == deviceVersion;
  }
}
