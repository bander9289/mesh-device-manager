/// Represents a firmware version with semantic versioning and hash.
///
/// Supports comparison operators for version ordering and hash mismatch detection.
class FirmwareVersion implements Comparable<FirmwareVersion> {
  final int major;
  final int minor;
  final int revision;
  final String hash; // Short hash from filename

  const FirmwareVersion({
    required this.major,
    required this.minor,
    required this.revision,
    required this.hash,
  });

  /// Parse version from string format: "2.1.5-a3d9c" or "0.5.0-e927703+"
  /// Allows optional trailing characters after the hash.
  factory FirmwareVersion.parse(String versionString) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)-([a-f0-9]+).*$')
        .firstMatch(versionString);
    
    if (match == null) {
      throw FormatException(
        'Invalid version format: $versionString. '
        'Expected format: major.minor.revision-hash (e.g., 2.1.5-a3d9c)',
      );
    }

    return FirmwareVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      revision: int.parse(match.group(3)!),
      hash: match.group(4)!,
    );
  }

  /// Compare versions for ordering (major > minor > revision).
  /// Hash is NOT considered in version comparison.
  @override
  int compareTo(FirmwareVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return revision.compareTo(other.revision);
  }

  bool operator >(FirmwareVersion other) => compareTo(other) > 0;
  bool operator <(FirmwareVersion other) => compareTo(other) < 0;
  bool operator >=(FirmwareVersion other) => compareTo(other) >= 0;
  bool operator <=(FirmwareVersion other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FirmwareVersion &&
        major == other.major &&
        minor == other.minor &&
        revision == other.revision &&
        hash == other.hash;
  }

  @override
  int get hashCode => Object.hash(major, minor, revision, hash);

  /// Check if versions have same version numbers but different hash.
  bool hasDifferentHash(FirmwareVersion other) {
    return major == other.major &&
        minor == other.minor &&
        revision == other.revision &&
        hash != other.hash;
  }

  /// Human-readable version string: "2.1.5-a3d9c"
  String toDisplayString() => '$major.$minor.$revision-$hash';

  @override
  String toString() => toDisplayString();
}
