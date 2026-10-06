import 'dart:convert';
import 'dart:typed_data';

/// Central JSON hardening for the sync pipeline (Timestamp crash fix).
///
/// `jsonEncode` only accepts `num/String/bool/null/List/Map`. A single
/// Firestore `Timestamp` (or `FieldValue`, `GeoPoint`, `DateTime`) inside a
/// payload used to throw:
///
///   `Converting object to an encodable object failed: Instance of 'Timestamp'`
///
/// and — because `PushWorker` encoded `result.remote` outside any per-entry
/// guard — the throw aborted the whole push batch and surfaced as
/// `SyncMetadata.last_error` on the Sync screen.
///
/// Every `jsonEncode` on the sync path must go through here:
/// sanitize first (single traversal), then encode. Sanitized output is
/// guaranteed encodable, so the encoder itself never throws for type reasons.
///
/// No `cloud_firestore` import on purpose: the codec duck-types `Timestamp`
/// / `FieldValue` via `runtimeType` + `toDate()`, so unit tests run without
/// Firebase initialization and a future Django backend reuses the same path.
abstract final class SyncCodec {
  /// Sentinel kept for `FieldValue.serverTimestamp()` placeholders when they
  /// must survive as JSON (conflict rows, size estimates).
  static const String serverTimestampPlaceholder = '__SERVER_TIMESTAMP__';

  /// Deep-convert [value] into something `jsonEncode` accepts.
  ///
  /// * `num/String/bool/null` pass through untouched (fast path, no copy).
  /// * `DateTime` -> ISO-8601 string.
  /// * `Timestamp`-like (has `toDate(): DateTime`) -> ISO-8601 string.
  /// * `FieldValue`-like -> [serverTimestampPlaceholder].
  /// * `Uint8List` -> base64 string (SQLite allows it, JSON does not).
  /// * `Map` keys are stringified; values recursed.
  /// * `List/Set/Iterable` recursed.
  /// * Anything else: try `toDate()`, else `'$value'` — always encodable,
  ///   never throws.
  static Object? sanitizeValue(Object? value) {
    if (value == null) return null;
    if (value is num || value is bool || value is String) return value;
    if (value is DateTime) return value.toIso8601String();
    if (value is Uint8List) return base64Encode(value);
    if (value is List) {
      // Growable fixed-size loop: avoids iterator allocation on hot pages.
      final out = List<Object?>.filled(value.length, null, growable: false);
      for (var i = 0; i < value.length; i++) {
        out[i] = sanitizeValue(value[i]);
      }
      return out;
    }
    if (value is Map) {
      final out = <String, dynamic>{};
      for (final entry in value.entries) {
        out['${entry.key}'] = sanitizeValue(entry.value);
      }
      return out;
    }
    if (value is Set || value is Iterable) {
      return [(value as Iterable).map(sanitizeValue).toList()];
    }

    final typeName = value.runtimeType.toString();
    // Firestore Timestamp / GeoPoint / DocumentReference / Blob arrive here
    // when the pull converter missed a new field. Duck-type so this file
    // never imports cloud_firestore.
    if (typeName.contains('FieldValue') ||
        typeName.contains('ServerTimestamp') ||
        typeName.contains('DeleteField') ||
        typeName.contains('ArrayUnion') ||
        typeName.contains('ArrayRemove')) {
      return serverTimestampPlaceholder;
    }
    if (typeName.contains('Timestamp')) {
      try {
        final date = (value as dynamic).toDate() as DateTime;
        return date.toIso8601String();
      } catch (_) {
        return '$value';
      }
    }
    if (typeName.contains('GeoPoint')) {
      try {
        final dynamic p = value;
        return 'geo:${p.latitude},${p.longitude}';
      } catch (_) {
        return '$value';
      }
    }
    if (typeName.contains('DocumentReference') ||
        typeName.contains('Blob')) {
      return '$value';
    }
    // Generic fallback: many Firebase types expose toDate().
    try {
      final maybe = (value as dynamic).toDate();
      if (maybe is DateTime) return maybe.toIso8601String();
    } catch (_) {
      // Not a date-like: fall through to string form.
    }
    return '$value';
  }

  /// Sanitize a document map (single traversal, fresh map).
  static Map<String, dynamic> sanitizeMap(Map<String, dynamic> input) {
    final out = <String, dynamic>{};
    for (final entry in input.entries) {
      out[entry.key] = sanitizeValue(entry.value);
    }
    return out;
  }

  /// `jsonEncode` that never throws for Firestore types.
  static String encode(Object? value) => jsonEncode(sanitizeValue(value));

  /// Encode a document map (the common sync case).
  static String encodeMap(Map<String, dynamic> map) =>
      jsonEncode(sanitizeMap(map));

  /// Never-throwing encoder for per-entry settlement: a poisoned remote
  /// document degrades to `'{}'` + caller-supplied error instead of aborting
  /// a 400-row batch. No allocation when input is null.
  static String? tryEncodeMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    try {
      return jsonEncode(sanitizeMap(map));
    } catch (_) {
      return '{}';
    }
  }

  /// Byte size of the JSON form, sanitized first.
  ///
  /// Replaces the old `jsonEncode(x).toLowerCase().codeUnits.length` which
  /// allocated two extra strings (lowercased copy + code-unit list) and
  /// measured UTF-16 units instead of bytes. UTF-8 length is what Firestore
  /// bills against; the 900 kB guard keeps the same threshold.
  static int byteSize(Object? value) {
    try {
      return utf8.encode(jsonEncode(sanitizeValue(value))).length;
    } catch (_) {
      // sanitizeValue guarantees encodability; this is pure defense.
      return maxPayloadFallback;
    }
  }

  static const int maxPayloadFallback = 1 << 30;
}
