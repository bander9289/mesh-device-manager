import 'dart:typed_data';
import 'package:path/path.dart' as path;
import 'firmware_version.dart';

/// Represents a loaded firmware file with metadata.
///
/// Stores the hardware ID, version, file path, binary data, and load timestamp.
class FirmwareFile {
  final String hardwareId; // Parsed from filename
  final FirmwareVersion version;
  final String filePath;
  final Uint8List data;
  final int sizeBytes;
  final DateTime loadedAt;

  const FirmwareFile({
    required this.hardwareId,
    required this.version,
    required this.filePath,
    required this.data,
    required this.sizeBytes,
    required this.loadedAt,
  });

  /// Parse firmware file from filename and data.
  ///
  /// Expected format: `<hardware_id>-<major>.<minor>.<revision>-<hash>.signed.bin`
  /// Example: `HW-0A3F-2.1.5-a3d9c.signed.bin`
  factory FirmwareFile.fromFile({
    required String filePath,
    required Uint8List data,
  }) {
    final fileName = path.basename(filePath);
    
    // Regex: <hardware_id>-<major>.<minor>.<revision>-<hash>.signed.bin
    final match = RegExp(
      r'^([A-Za-z0-9\-]+)-(\d+)\.(\d+)\.(\d+)-([a-f0-9]+)\.signed\.bin$',
    ).firstMatch(fileName);

    if (match == null) {
      throw FormatException(
        'Invalid firmware filename: $fileName\n'
        'Expected format: <hardware_id>-<major>.<minor>.<revision>-<hash>.signed.bin\n'
        'Example: HW-0A3F-2.1.5-a3d9c.signed.bin',
      );
    }

    final hardwareId = match.group(1)!;
    final version = FirmwareVersion(
      major: int.parse(match.group(2)!),
      minor: int.parse(match.group(3)!),
      revision: int.parse(match.group(4)!),
      hash: match.group(5)!,
    );

    return FirmwareFile(
      hardwareId: hardwareId,
      version: version,
      filePath: filePath,
      data: data,
      sizeBytes: data.length,
      loadedAt: DateTime.now(),
    );
  }

  /// Human-readable display name: "HW-0A3F v2.1.5-a3d9c"
  String get displayName => '$hardwareId v${version.toDisplayString()}';

  /// File basename only
  String get fileName => path.basename(filePath);

  @override
  String toString() => displayName;
}
