import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Result of walking a hash chain.
///
/// Deliberately a plain core type: `lib/core` must not depend on
/// `lib/features`, so the feature repository maps this onto its own
/// `QcChainVerification`.
class AuditChainResult {
  const AuditChainResult({
    required this.isValid,
    required this.checked,
    this.brokenAt = 0,
    this.reason,
    this.headHash = '',
  });

  final bool isValid;

  /// Rows examined.
  final int checked;

  /// 1-based position of the first row that failed, 0 when intact.
  final int brokenAt;

  final String? reason;

  /// Hash of the last good row.
  final String headHash;

  @override
  String toString() => isValid
      ? 'AuditChainResult.ok(checked: $checked)'
      : 'AuditChainResult.broken(at: $brokenAt, reason: $reason)';
}

/// Canonical JSON + SHA-256 chaining for the tamper-evident audit trail
/// (plan V6_ENHANCED §21.2).
///
/// The threat is not a bored user with a SQL editor, it is the ordinary
/// accident: a cascade delete, a restore from a slightly old backup, a
/// "temporary" UPDATE applied to the wrong table. A hash chain turns "the audit
/// table looks wrong" into "row 412 no longer hashes to what row 411 commits
/// to", which is a question with an answer.
abstract final class AuditHasher {
  /// Columns that make up the hashed payload, in the canonical order.
  ///
  /// `id`, `hash` and `immutable` are excluded on purpose: `id` is not known
  /// until after the insert, and the other two are the *output* of the hash, not
  /// an input. Adding a column here retroactively invalidates every row already
  /// written, so it is a breaking change and has to be made deliberately.
  static const List<String> hashedFields = [
    'entity_type',
    'entity_id',
    'action',
    'by_user_id',
    'by_user_name',
    'at',
    'before_json',
    'after_json',
    'meta_json',
    'prev_hash',
  ];

  /// Deterministic JSON: object keys sorted, no insignificant whitespace, and
  /// `null` preserved rather than dropped.
  ///
  /// Two rows that differ only in key order must hash identically, otherwise the
  /// chain would report tampering every time a device rebuilt a map in a
  /// different order. Nested maps are sorted too - a payload can arrive from a
  /// Firestore document as well as from local code.
  static String canonicalize(Object? value) {
    final buffer = StringBuffer();
    _write(value, buffer);
    return buffer.toString();
  }

  static void _write(Object? value, StringBuffer out) {
    if (value == null) {
      out.write('null');
      return;
    }
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      out.write('{');
      var first = true;
      for (final key in keys) {
        if (!first) out.write(',');
        first = false;
        out.write(jsonEncode(key));
        out.write(':');
        // Re-read by key rather than by the original object, so a non-String
        // key cannot desynchronise the sorted order from the emitted order.
        final original = value.containsKey(key)
            ? value[key]
            : value.entries
                  .firstWhere(
                    (e) => '${e.key}' == key,
                    orElse: () => MapEntry(key, null),
                  )
                  .value;
        _write(original, out);
      }
      out.write('}');
      return;
    }
    if (value is Iterable) {
      out.write('[');
      var first = true;
      for (final item in value) {
        if (!first) out.write(',');
        first = false;
        _write(item, out);
      }
      out.write(']');
      return;
    }
    if (value is num || value is bool || value is String) {
      out.write(jsonEncode(value));
      return;
    }
    // Anything else (DateTime, enum, model) is reduced through its string form
    // rather than `toJson()`, so the hash never depends on a class that may be
    // refactored later.
    out.write(jsonEncode('$value'));
  }

  /// The exact map that gets hashed for [row], with non-string values coerced
  /// and missing columns treated as empty rather than null.
  ///
  /// Empty string, not null: a row written by an older build that omitted
  /// `meta_json` has to hash the same as one written now with `meta_json = ''`,
  /// or merely re-saving a row would break the chain.
  static Map<String, dynamic> payloadOf(Map<String, Object?> row) => {
    for (final field in hashedFields) field: _asStored(row[field]),
  };

  /// `null`, `Map`, `List` and scalars all collapse to a stable string here.
  static Object _asStored(Object? value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is num || value is bool) return value;
    return canonicalize(value);
  }

  /// SHA-256 over the canonical payload, lowercase hex.
  static String hash(Map<String, Object?> row) {
    final canonical = canonicalize(payloadOf(row));
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  /// Convenience for a payload map that is already the right shape.
  static String hashPayload(Map<String, dynamic> payload) =>
      sha256.convert(utf8.encode(canonicalize(payload))).toString();

  /// Hash of the current chain head, or `null` when the table is empty.
  ///
  /// `DESC` is essential: with `ORDER BY id ASC LIMIT 1` SQLite returns the
  /// *oldest* row, so every entry from the third onwards would chain back onto
  /// row 1 and the chain would look broken the moment it had three links.
  ///
  /// `id` leads the ordering because it is the only total order that exists -
  /// two events routinely share a timestamp to the second on a fast local write,
  /// and `at` alone is not enough to decide which one came first.
  static Future<String?> computePrevHash(
    DatabaseExecutor db, {
    required String table,
    String orderBy = 'id DESC, at DESC',
  }) async {
    final rows = await db.query(
      table,
      orderBy: orderBy,
      columns: ['hash'],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final value = rows.first['hash'];
    if (value == null || '$value'.isEmpty) return null;
    return '$value';
  }

  /// Walks [rows] (which must be ordered `id ASC`) and re-derives every hash.
  ///
  /// Checks three separate things, because they fail for different reasons:
  /// the chain link (`prev_hash` matches its predecessor), the row's own hash,
  /// and that no row vanished from the sequence.
  static AuditChainResult verifyChain(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) {
      return const AuditChainResult(isValid: true, checked: 0);
    }

    var previousHash = '';
    int? previousId;

    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final position = i + 1;
      final id = (row['id'] as num?)?.toInt();
      final storedHash = '${row['hash'] ?? ''}';
      final storedPrev = (row['prev_hash'] == null)
          ? ''
          : '${row['prev_hash']}';

      if (i == 0) {
        if (storedPrev.isNotEmpty) {
          return AuditChainResult(
            isValid: false,
            checked: i,
            brokenAt: position,
            reason:
                'the first row (id=$id) has a prev_hash but nothing '
                'precedes it',
          );
        }
      }

      // The id sequence is checked *before* the hash link. A removed row breaks
      // both, but "row 412 is missing" is the actionable finding, and the link
      // check would otherwise always fire first and report the less useful
      // "prev_hash mismatch" for every single deletion.
      if (id != null && previousId != null && id <= previousId) {
        return AuditChainResult(
          isValid: false,
          checked: i,
          brokenAt: position,
          reason:
              'ids are not increasing (id=$id after $previousId); '
              'the rows are not in chain order',
        );
      }
      if (previousId != null && id != null && id != previousId + 1) {
        return AuditChainResult(
          isValid: false,
          checked: i,
          brokenAt: position,
          reason: 'id $previousId is followed by $id - a row was removed',
        );
      }

      if (i > 0 && storedPrev != previousHash) {
        return AuditChainResult(
          isValid: false,
          checked: i,
          brokenAt: position,
          reason:
              'prev_hash does not match the previous row '
              '(id=$id): stored "$storedPrev", expected "$previousHash"',
        );
      }

      final recomputed = hash(row);
      if (storedHash.isEmpty) {
        return AuditChainResult(
          isValid: false,
          checked: i,
          brokenAt: position,
          reason: 'row id=$id has no hash',
        );
      }
      if (storedHash != recomputed) {
        return AuditChainResult(
          isValid: false,
          checked: i,
          brokenAt: position,
          reason:
              'row id=$id was modified after it was written '
              '(stored "$storedHash", recomputed "$recomputed")',
        );
      }

      previousHash = storedHash;
      previousId = id;
    }

    return AuditChainResult(
      isValid: true,
      checked: rows.length,
      headHash: previousHash,
    );
  }
}
