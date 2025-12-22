/// Utilities for working with BLE MAC addresses / FlutterBluePlus remoteIds.
///
/// Canonical representation used across the app is:
/// - lowercase
/// - colon-separated (e.g. "aa:bb:cc:dd:ee:ff")
///
/// IMPORTANT: Some call sites intentionally distinguish `null` vs empty lists
/// when passing MAC collections across layers (e.g. broadcast semantics).

library mac_address;


/// Returns a canonical, comparable MAC form: lowercase + colon-separated.
///
/// This is intentionally tolerant of inputs that may come from different layers:
/// - "AA-BB-CC-DD-EE-FF"
/// - "aa:bb:cc:dd:ee:ff"
/// - "aabbccddeeff"
///
/// If the input contains 12 hex characters (with any separators), it will be
/// formatted into 6 octets. Otherwise it will fall back to a best-effort
/// normalization (lowercasing and converting '-' to ':').
String normalizeMac(String input) {
  final raw = input.trim().toLowerCase();
  if (raw.isEmpty) return raw;

  // Best-effort fast path.
  final quick = raw.replaceAll('-', ':');

  // Extract hex chars only.
  final hex = StringBuffer();
  for (final codeUnit in raw.codeUnits) {
    final c = String.fromCharCode(codeUnit);
    final isHex = (codeUnit >= 48 && codeUnit <= 57) ||
        (codeUnit >= 97 && codeUnit <= 102); // 0-9 or a-f
    if (isHex) hex.write(c);
  }

  final hexStr = hex.toString();
  if (hexStr.length != 12) {
    return quick;
  }

  // Format into 6 octets.
  final parts = <String>[];
  for (var i = 0; i < 12; i += 2) {
    parts.add(hexStr.substring(i, i + 2));
  }
  return parts.join(':');
}

/// Returns a stable cache/map key form used by scan caches: lowercase + hyphen-separated.
String macCacheKey(String mac) => normalizeMac(mac).replaceAll(':', '-');

/// Returns the MAC with all separators removed (lowercase hex).
String macNoSeparators(String mac) => normalizeMac(mac).replaceAll(':', '');

/// Normalizes a MAC list while preserving null vs empty semantics.
List<String>? normalizeMacListPreserveNull(List<String>? macs) {
  if (macs == null) return null;
  return macs.map(normalizeMac).toList();
}

/// Compares two MACs by canonical normalized form.
bool macEquals(String a, String b) => normalizeMac(a) == normalizeMac(b);
