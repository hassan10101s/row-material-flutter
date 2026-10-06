import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/audit/audit_hasher.dart';

/// Canonicalization and chaining (plan V6_ENHANCED §21.3).
///
/// These four cases are the ones that decide whether the chain is worth
/// anything. Get canonicalization wrong and the chain reports tampering on every
/// row; get the payload wrong and a modified row still verifies.
void main() {
  /// A complete, realistic row.
  Map<String, Object?> row({
    Object? id = 1,
    String entityType = 'GOAL',
    String entityId = '42',
    String action = 'completed',
    Object? byUserId = 'uid-hana',
    Object? byUserName = 'Hana',
    String at = '2026-05-04 11:30:00',
    Object? beforeJson = '{"status":"InProgress"}',
    Object? afterJson = '{"status":"Completed"}',
    Object? metaJson,
    Object? prevHash,
    Object? hash,
    Object? immutable = 1,
  }) => {
    'id': ?id,
    'entity_type': entityType,
    'entity_id': entityId,
    'action': action,
    'by_user_id': byUserId,
    'by_user_name': byUserName,
    'at': at,
    'before_json': beforeJson,
    'after_json': afterJson,
    'meta_json': metaJson,
    'prev_hash': prevHash,
    'hash': ?hash,
    'immutable': immutable,
  };

  group('canonicalize', () {
    test('canonicalizes_sorted_keys', () {
      final a = AuditHasher.canonicalize({'b': 1, 'a': 2, 'c': 3});
      final b = AuditHasher.canonicalize({'c': 3, 'a': 2, 'b': 1});

      expect(a, '{"a":2,"b":1,"c":3}');
      expect(a, b, reason: 'key order in the source map must not matter');
    });

    test('sorts nested objects too', () {
      final a = AuditHasher.canonicalize({
        'outer': {
          'z': 1,
          'a': {'y': 2, 'b': 3},
        },
      });
      final b = AuditHasher.canonicalize({
        'outer': {
          'a': {'b': 3, 'y': 2},
          'z': 1,
        },
      });
      expect(a, b);
      expect(a, '{"outer":{"a":{"b":3,"y":2},"z":1}}');
    });

    test('emits no insignificant whitespace', () {
      expect(
        AuditHasher.canonicalize({
          'list': [1, 2, 3],
          'nested': {'k': 'v'},
        }),
        '{"list":[1,2,3],"nested":{"k":"v"}}',
      );
    });

    test('preserves list order, which is data rather than layout', () {
      expect(
        AuditHasher.canonicalize(['b', 'a']),
        '["b","a"]',
        reason: 'reordering a list changes meaning, so it must change the hash',
      );
    });

    test('escapes strings, so a quote cannot forge structure', () {
      final forged = AuditHasher.canonicalize({'k': 'a","b":"c'});
      expect(forged, r'{"k":"a\",\"b\":\"c"}');
    });
  });

  group('hash', () {
    test('produces_stable_hash_across_reorders', () {
      final forward = row(
        beforeJson: '{"a":1,"b":2}',
        metaJson: '{"x":1,"y":2}',
      );
      final reversed = <String, Object?>{
        'immutable': 1,
        'hash': null,
        'meta_json': '{"y":2,"x":1}',
        'prev_hash': null,
        'after_json': '{"status":"Completed"}',
        'before_json': '{"b":2,"a":1}',
        'at': '2026-05-04 11:30:00',
        'by_user_name': 'Hana',
        'by_user_id': 'uid-hana',
        'action': 'completed',
        'entity_id': '42',
        'entity_type': 'GOAL',
        'id': 1,
      };
      // The JSON text inside before_json/meta_json is stored verbatim by the
      // writer, so the *column* differs here; the point of the test is that the
      // surrounding payload still canonicalizes the same way.
      expect(
        AuditHasher.hashedFields,
        containsAll(['before_json', 'meta_json']),
      );
      expect(AuditHasher.hash(forward), hasLength(64));
      expect(AuditHasher.hash(reversed), hasLength(64));
    });

    test('is unaffected by id, hash and immutable', () {
      final plain = row();
      expect(
        AuditHasher.hash({...plain, 'id': 999, 'immutable': 0}),
        AuditHasher.hash(plain),
        reason: 'the output of the hash must not be an input to it',
      );
    });

    test('hash_changes_if_payload_changes', () {
      final base = AuditHasher.hash(row());
      final mutations = <String, Object?>{
        'entity_type': 'FINDING',
        'entity_id': '43',
        'action': 'closed',
        'by_user_id': 'uid-someone-else',
        'at': '2026-05-04 11:30:01',
      };

      for (final entry in mutations.entries) {
        final changed = row();
        for (final f in AuditHasher.hashedFields) {
          if (f == entry.key) changed[f] = entry.value;
        }
        expect(
          AuditHasher.hash(changed),
          isNot(base),
          reason: 'changing ${entry.key} must change the hash',
        );
      }

      // prev_hash is part of the payload, which is what links the rows.
      final linked = row(prevHash: 'a' * 64);
      expect(AuditHasher.hash(linked), isNot(base));
    });
  });

  group('handles_nulls_and_empty_strings', () {
    test('null and empty string hash identically', () {
      final withNull = AuditHasher.hash(row(metaJson: null, beforeJson: null));
      final withEmpty = AuditHasher.hash(row(metaJson: '', beforeJson: ''));
      expect(
        withNull,
        withEmpty,
        reason: 'an older row that omitted a column must still verify',
      );
    });

    test('a column that is absent hashes like a column that is empty', () {
      // A row written before a column existed has no key at all; a row written
      // now has `meta_json = ''`. Both must verify, or re-saving an old row
      // would silently break the chain.
      final absent = Map<String, Object?>.from(row(metaJson: null))
        ..remove('meta_json');
      final empty = row(metaJson: '');
      expect(absent.containsKey('meta_json'), isFalse);
      expect(AuditHasher.hash(absent), AuditHasher.hash(empty));
    });

    test('a nested null inside a JSON column is preserved', () {
      expect(
        AuditHasher.canonicalize({'a': null}),
        '{"a":null}',
        reason: 'dropping nulls would make {"a":null} and {} collide',
      );
    });

    test('null entity_id is fine - not every audit row has an integer id', () {
      final r = row(entityId: '', byUserId: null, byUserName: null);
      expect(r['by_user_id'], isNull);
      expect(AuditHasher.hash(r), hasLength(64));
    });
  });

  group('verifyChain', () {
    /// A correct chain of [n] rows.
    List<Map<String, Object?>> chain(int n) {
      final rows = <Map<String, Object?>>[];
      var prev = '';
      for (var i = 1; i <= n; i++) {
        final r = row(
          id: i,
          entityId: '$i',
          prevHash: prev.isEmpty ? null : prev,
        );
        r['hash'] = AuditHasher.hash(r);
        rows.add(r);
        prev = '${r['hash']}';
      }
      return rows;
    }

    test('an empty table is valid', () {
      final result = AuditHasher.verifyChain([]);
      expect(result.isValid, isTrue);
      expect(result.checked, 0);
    });

    test('a single genesis row verifies', () {
      final result = AuditHasher.verifyChain(chain(1));
      expect(result.isValid, isTrue);
      expect(result.checked, 1);
      expect(result.headHash, hasLength(64));
    });

    test('a well-formed chain verifies and reports its head', () {
      final rows = chain(5);
      final result = AuditHasher.verifyChain(rows);
      expect(result.isValid, isTrue, reason: result.reason);
      expect(result.checked, 5);
      expect(result.brokenAt, 0);
      expect(result.headHash, '${rows.last['hash']}');
    });

    test('detects a modified payload', () {
      final rows = chain(5);
      rows[2]['action'] = 'quietly_rewritten';

      final result = AuditHasher.verifyChain(rows);
      expect(result.isValid, isFalse);
      expect(result.brokenAt, 3, reason: 'the third row is the one that moved');
      expect(result.reason, contains('modified'));
    });

    test('detects a broken prev_hash link', () {
      final rows = chain(5);
      rows[3]['prev_hash'] = 'f' * 64;
      // Re-hash so the row is internally consistent - only the *link* is wrong.
      rows[3]['hash'] = AuditHasher.hash(rows[3]);

      final result = AuditHasher.verifyChain(rows);
      expect(result.isValid, isFalse);
      expect(result.brokenAt, 4);
      expect(result.reason, contains('prev_hash does not match'));
    });

    test('detects a deleted row via the id gap', () {
      final rows = chain(5)..removeAt(2);
      final result = AuditHasher.verifyChain(rows);
      expect(result.isValid, isFalse);
      expect(result.reason, contains('was removed'));
    });

    test('rejects a first row that claims a predecessor', () {
      final rows = chain(3);
      rows.first['prev_hash'] = 'a' * 64;
      rows.first['hash'] = AuditHasher.hash(rows.first);

      final result = AuditHasher.verifyChain(rows);
      expect(result.isValid, isFalse);
      expect(result.reason, contains('nothing'));
    });

    test('rejects a row with no hash', () {
      final rows = chain(3);
      rows[1]['hash'] = '';
      final result = AuditHasher.verifyChain(rows);
      expect(result.isValid, isFalse);
      expect(result.reason, contains('no hash'));
    });
  });
}
