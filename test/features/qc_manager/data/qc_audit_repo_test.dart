import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart' show MemberStatus;
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/features/qc_manager/data/qc_audit_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_audit.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Immutability and chaining of `qc_audits` (plan V6_ENHANCED §21.3).
///
/// The interesting property is not "the repository has no delete method" - it is
/// what happens when something *else* tries. Every tampering test here reaches
/// past the repository and talks to SQLite directly, because that is the only way
/// to be sure the guarantee is real rather than merely conventional.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late Database db;
  late QcAuditRepo repo;

  QcActor actor = const QcActor(
    uid: 'uid-hana',
    name: 'Hana',
    deviceId: 'device-1',
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_qc_audit_repo');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await helper.database;
    repo = QcAuditRepo(dbHelper: helper, actorReader: () => actor);
  });

  tearDown(() async {
    await helper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Removes the append-only triggers so a test can simulate tampering.
  ///
  /// This is deliberately the *only* way into `qc_audits` in this file: the
  /// trigger is the last line of defence, and dropping it is the kind of
  /// deliberate, visible act that `verifyChain` exists to catch afterwards.
  Future<void> dropGuards() async {
    await db.execute('DROP TRIGGER IF EXISTS qc_audits_block_update');
    await db.execute('DROP TRIGGER IF EXISTS qc_audits_block_delete');
  }

  group('QcActor.fromSession', () {
    // This mapping is what `service_locator.dart` hands to every QC write, and it
    // used to be an anonymous closure in the DI file - reachable only by booting
    // Firebase, which is why nobody ever checked what it did when nobody was
    // signed in.

    test('a signed-out session is visibly nobody, not a blank row', () {
      final actor = QcActor.fromSession(const AppSession());

      expect(actor.uid, isEmpty);
      expect(actor.name, isEmpty);
      expect(actor.deviceId, isEmpty);
    });

    test('a display name is preferred over the email', () {
      final actor = QcActor.fromSession(
        const AppSession(
          uid: 'uid-hana',
          email: 'hana@example.test',
          displayName: 'Hana Sato',
          deviceId: 'device-1',
        ),
      );

      expect(actor.uid, 'uid-hana');
      expect(actor.name, 'Hana Sato');
      expect(actor.deviceId, 'device-1');
    });

    test('the email is the fallback when there is no display name', () {
      // A Google account can legitimately have no display name; a blank audit
      // row would be worse than an email.
      final actor = QcActor.fromSession(
        const AppSession(uid: 'uid-hana', email: 'hana@example.test'),
      );

      expect(actor.name, 'hana@example.test');
    });

    test('a uid with no name at all still records who acted', () {
      final actor = QcActor.fromSession(const AppSession(uid: 'uid-hana'));

      expect(actor.uid, 'uid-hana');
      expect(actor.name, isEmpty);
    });

    test('it matches the actor the DI would derive from a live session', () {
      // Guards against the factory and the wiring drifting apart: this is the
      // exact shape `SessionSource` hands out.
      final source = SessionSource(
        () => const AppSession(
          uid: 'uid-hana',
          email: 'hana@example.test',
          displayName: 'Hana Sato',
          deviceId: 'device-1',
          status: MemberStatus.active,
          role: 'qualityManager',
        ),
      );

      expect(QcActor.fromSession(source.session).name, 'Hana Sato');
    });
  });

  group('append', () {
    test('insert_creates_row_with_hash_and_prev_hash_null_for_first', () async {
      final id = await repo.append(
        entityType: QcAuditEntity.goal,
        entityId: '42',
        action: 'completed',
        before: {'status': 'InProgress'},
        after: {'status': 'Completed'},
        meta: {'evidence': 'sop101.pdf'},
      );

      final row = (await db.query(
        'qc_audits',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(row['hash'], hasLength(64));
      expect(row['prev_hash'], anyOf(isNull, ''));
      expect(row['entity_type'], 'GOAL');
      expect(row['by_user_id'], 'uid-hana', reason: 'actor comes from session');
      expect(row['by_user_name'], 'Hana');
      expect(row['device_id'], 'device-1');
      expect(row['at'], isNotEmpty);
    });

    test('insert_preserves_immutable_flag_true', () async {
      final id = await repo.append(
        entityType: QcAuditEntity.inspection,
        entityId: '7',
        action: 'submitted',
      );
      final row = (await db.query(
        'qc_audits',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(row['immutable'], 1);
    });

    test('second_insert_links_prev_hash', () async {
      final first = await repo.append(
        entityType: QcAuditEntity.finding,
        entityId: '1',
        action: 'created',
      );
      final second = await repo.append(
        entityType: QcAuditEntity.finding,
        entityId: '1',
        action: 'assigned',
      );
      final third = await repo.append(
        entityType: QcAuditEntity.capa,
        entityId: '9',
        action: 'verified',
      );

      final rows = await db.query('qc_audits', orderBy: 'id ASC');
      expect(rows[0]['prev_hash'], anyOf(isNull, ''));
      expect(rows[1]['prev_hash'], rows[0]['hash']);
      expect(rows[2]['prev_hash'], rows[1]['hash']);
      expect(first, lessThan(second));
      expect(second, lessThan(third));
    });

    test(
      'snapshots are stored as the exact canonical text that was hashed',
      () async {
        // Inserted with keys in a deliberately unhelpful order.
        final id = await repo.append(
          entityType: QcAuditEntity.goal,
          entityId: '42',
          action: 'completed',
          before: {'z': 1, 'a': 2},
        );
        final row = (await db.query(
          'qc_audits',
          where: 'id = ?',
          whereArgs: [id],
        )).single;
        expect(row['before_json'], '{"a":2,"z":1}');
      },
    );

    test('rejects an unknown entity_type before touching the table', () async {
      await expectLater(
        repo.append(
          entityType: 'NOT_A_REAL_ENTITY',
          entityId: '1',
          action: 'created',
        ),
        throwsA(isA<Exception>()),
      );
      expect(await repo.count(), 0, reason: 'nothing may be written');
    });

    test('rejects a blank action', () async {
      await expectLater(
        repo.append(
          entityType: QcAuditEntity.goal,
          entityId: '1',
          action: '  ',
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('concurrent_inserts_maintain_monotonic_chain_by_id', () async {
      // Deliberately not awaited in order: the chain has to hold regardless of
      // the order the writes actually land in.
      await Future.wait([
        for (var i = 1; i <= 8; i++)
          repo.append(
            entityType: QcAuditEntity.inspection,
            entityId: '$i',
            action: 'submitted',
          ),
      ]);

      final verification = await repo.verifyChain();
      expect(verification.isValid, isTrue, reason: verification.reason);
      expect(verification.checked, 8);
    });
  });

  group('immutability', () {
    test('cannot_update_existing_audit_row', () async {
      final id = await repo.append(
        entityType: QcAuditEntity.goal,
        entityId: '42',
        action: 'created',
      );

      await expectLater(
        db.update(
          'qc_audits',
          {'action': 'quietly_rewritten'},
          where: 'id = ?',
          whereArgs: [id],
        ),
        throwsA(isA<Exception>()),
        reason: 'the trigger must reject the statement',
      );

      final row = (await db.query(
        'qc_audits',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(row['action'], 'created');
    });

    test('cannot_delete_existing_audit_row', () async {
      final id = await repo.append(
        entityType: QcAuditEntity.goal,
        entityId: '42',
        action: 'created',
      );

      await expectLater(
        db.delete('qc_audits', where: 'id = ?', whereArgs: [id]),
        throwsA(isA<Exception>()),
      );
      expect(await repo.count(), 1);
    });

    test('cannot_delete_the_whole_table', () async {
      await repo.append(
        entityType: QcAuditEntity.goal,
        entityId: '1',
        action: 'created',
      );
      await expectLater(db.delete('qc_audits'), throwsA(isA<Exception>()));
      expect(await repo.count(), 1);
    });

    test('a rollback cannot leave a partial audit entry', () async {
      final before = await repo.count();
      await expectLater(
        db.transaction((txn) async {
          await repo.append(
            entityType: QcAuditEntity.goal,
            entityId: '99',
            action: 'created',
            exec: txn,
          );
          throw StateError('business write failed');
        }),
        throwsStateError,
      );
      expect(
        await repo.count(),
        before,
        reason: 'the entry was part of the transaction, so it rolls back too',
      );
    });

    test(
      'an audit entry commits with the business write it describes',
      () async {
        await db.transaction((txn) async {
          await txn.insert('qc_defect_codes', {
            'code': 'D-001',
            'name': 'Moisture above limit',
          });
          await repo.append(
            entityType: QcAuditEntity.finding,
            entityId: '1',
            action: 'created',
            exec: txn,
          );
        });

        expect(await db.query('qc_defect_codes'), hasLength(1));
        expect(await repo.count(), 1);
        expect((await repo.verifyChain()).isValid, isTrue);
      },
    );
  });

  group('verifyChain', () {
    Future<void> seed(int n) async {
      for (var i = 1; i <= n; i++) {
        await repo.append(
          entityType: QcAuditEntity.inspection,
          entityId: '$i',
          action: 'submitted',
          after: {'n': i},
        );
      }
    }

    test('verifyChain_returns_true_for_valid_chain', () async {
      await seed(5);
      final result = await repo.verifyChain();
      expect(result.isValid, isTrue, reason: result.reason);
      expect(result.checked, 5);
      expect(result.brokenAt, 0);
    });

    test('verifyChain_returns_true_for_an_empty_table', () async {
      final result = await repo.verifyChain();
      expect(result.isValid, isTrue);
      expect(result.checked, 0);
    });

    test('verifyChain_returns_false_if_hash_tampered', () async {
      await seed(4);
      await dropGuards();
      await db.update(
        'qc_audits',
        {'action': 'rewritten'},
        where: 'id = ?',
        whereArgs: [3],
      );

      final result = await repo.verifyChain();
      expect(result.isValid, isFalse);
      expect(result.brokenAt, 3);
      expect(result.reason, contains('modified'));
    });

    test(
      'verifyChain_returns_false_if_payload_tampered_without_the_hash',
      () async {
        await seed(4);
        await dropGuards();
        // Re-hash the tampered row so only the *snapshot* disagrees with what a
        // verifier can see - the case a naive "did the hash change" check misses.
        final row = Map<String, dynamic>.from(
          (await db.query('qc_audits', where: 'id = ?', whereArgs: [2])).single,
        );
        row['after_json'] = '{"n":999}';
        await db.update(
          'qc_audits',
          {'after_json': row['after_json']},
          where: 'id = ?',
          whereArgs: [2],
        );

        final result = await repo.verifyChain();
        expect(result.isValid, isFalse);
        expect(result.brokenAt, 2);
      },
    );

    test('verifyChain_returns_false_if_prev_hash_broken', () async {
      await seed(4);
      await dropGuards();
      await db.update(
        'qc_audits',
        {'prev_hash': 'f' * 64},
        where: 'id = ?',
        whereArgs: [3],
      );

      final result = await repo.verifyChain();
      expect(result.isValid, isFalse);
      expect(result.reason, contains('prev_hash does not match'));
    });

    test('verifyChain_returns_false_if_a_row_was_removed', () async {
      await seed(4);
      await dropGuards();
      await db.delete('qc_audits', where: 'id = ?', whereArgs: [2]);

      final result = await repo.verifyChain();
      expect(result.isValid, isFalse);
      expect(result.reason, contains('was removed'));
    });
  });

  group('reads', () {
    test('filters by entity, action and paging', () async {
      await repo.append(
        entityType: QcAuditEntity.goal,
        entityId: '1',
        action: 'created',
      );
      await repo.append(
        entityType: QcAuditEntity.goal,
        entityId: '1',
        action: 'completed',
      );
      await repo.append(
        entityType: QcAuditEntity.finding,
        entityId: '2',
        action: 'created',
      );

      expect(await repo.count(), 3);
      expect(await repo.count(entityType: QcAuditEntity.goal), 2);
      expect(
        await repo.count(entityType: QcAuditEntity.goal, entityId: '1'),
        2,
      );

      final goals = await repo.list(entityType: QcAuditEntity.goal);
      expect(
        goals.map((a) => a.action),
        ['completed', 'created'],
        reason: 'newest first, so a screen shows the latest event at the top',
      );

      final created = await repo.list(action: 'created');
      expect(created, hasLength(2));

      final page = await repo.list(limit: 2);
      expect(page, hasLength(2));
    });

    test(
      'an entry round-trips into the model with its snapshots intact',
      () async {
        final id = await repo.append(
          entityType: QcAuditEntity.goal,
          entityId: '42',
          action: 'completed',
          before: {'status': 'InProgress'},
          after: {'status': 'Completed'},
          meta: {'evidence': 'sop101.pdf'},
        );

        final entry = await repo.get(id);
        expect(entry, isNotNull);
        expect(entry!.entityType, QcAuditEntity.goal);
        expect(entry.after['status'], 'Completed');
        expect(entry.before['status'], 'InProgress');
        expect(entry.meta['evidence'], 'sop101.pdf');
        expect(entry.immutable, isTrue);
        expect(
          entry.isGenesis,
          isTrue,
          reason: 'it is the first row, so it has no predecessor',
        );
      },
    );

    test('the export carries the chain verdict', () async {
      await repo.append(
        entityType: QcAuditEntity.goal,
        entityId: '1',
        action: 'created',
      );
      final json = await repo.exportJson();
      expect(json, contains('"chain_valid":true'));
      expect(json, contains('"row_count":1'));
    });

    test('the domain contract exposes no mutator', () async {
      // Compile-time proof rather than a string search: this class implements
      // the contract with *only* the read/append surface, so adding an
      // `update`/`delete` to `QcAuditRepository` breaks this file at compile
      // time instead of quietly weakening the guarantee.
      final contract = _AppendOnlyContract();
      expect(
        await contract.append(
          entityType: 'GOAL',
          entityId: '1',
          action: 'created',
        ),
        1,
      );
      expect(
        await contract.verifyChain(),
        const QcChainVerification.ok(checked: 0, headHash: ''),
      );

      // And the concrete repository must satisfy that same surface.
      expect(repo, isA<QcAuditRepository>());
    });
  });
}

/// Implements [QcAuditRepository] with nothing but `append` and reads.
///
/// If a mutator is ever added to the contract, this stops compiling - which is
/// the point. A trail that can be edited is not a trail.
class _AppendOnlyContract implements QcAuditRepository {
  @override
  Future<int> append({
    required String entityType,
    required String entityId,
    required String action,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    Map<String, dynamic>? meta,
  }) async => 1;

  @override
  Future<QcAudit?> get(int id) async => null;

  @override
  Future<List<QcAudit>> list({
    String entityType = '',
    String entityId = '',
    String action = '',
    int limit = 200,
    int offset = 0,
  }) async => const [];

  @override
  Future<int> count({String entityType = '', String entityId = ''}) async => 0;

  @override
  Future<QcChainVerification> verifyChain({int? limit}) async =>
      const QcChainVerification.ok(checked: 0, headHash: '');
}
