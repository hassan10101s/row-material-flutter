import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/inspections/data/offline_first_inspection_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

import 'sync_test_fixture.dart';

/// Plan P7.3: the local write, its `sync_queue` row and its `audit_logs` row must
/// commit **together** — a failure anywhere in that trio has to roll the whole
/// thing back, and §9.4 has to block a forbidden write before any row exists.
class _FakeGuard implements WriteGuard {
  _FakeGuard({this.online = true, Set<Permission>? allowed})
      : _allowed = allowed ?? {
          Permission.samplesCreate,
          Permission.samplesUpdate,
          Permission.qcApprove,
          Permission.qcReject,
        };

  final Set<Permission> _allowed;

  @override
  final bool online;
  @override
  String get uid => 'uid_admin';
  @override
  String get organizationId => 'org_1';
  @override
  String get memberId => 'admin@material-lab.test';
  @override
  String get deviceId => 'dev_1';
  @override
  String get email => memberId;

  @override
  bool allows(String permissionId) {
    final permission = Permission.byId(permissionId);
    if (permission == null) return false;
    // Same rule as `AppSession.canDo`: a privileged operation needs a live
    // connection as well as the permission.
    if (permissionRequiresFreshSession(permission) && !online) return false;
    return _allowed.contains(permission);
  }
}

/// A queue whose `enqueue` always fails, to prove the rollback of the write.
class _FailingQueue extends SyncQueue {
  _FailingQueue(super.dbHelper);

  @override
  Future<void> enqueue(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
    int? localRef,
    required String operation,
    required Map<String, dynamic> payload,
    int baseVersion = 0,
  }) async =>
      throw StateError('enqueue failed on purpose');
}

/// An audit logger whose `log` always fails.
class _FailingAudit extends AuditLogger {
  _FailingAudit(SyncQueue queue) : super(queue: queue);

  @override
  Future<int> log(
    DatabaseExecutor txn, {
    required String action,
    required String entityType,
    required String entityId,
    Map<String, dynamic>? details,
  }) async =>
      throw StateError('audit failed on purpose');
}

void main() {
  late SyncFixture fixture;
  late ReferenceRepo referenceRepo;
  late SyncQueue queue;
  late AuditLogger audit;
  late _FakeGuard guard;
  late UserContext user;

  OfflineFirstInspectionRepository buildRepo({
    WriteGuard? writeGuard,
    SyncQueue? syncQueue,
    AuditLogger? auditLogger,
  }) =>
      OfflineFirstInspectionRepository(
        dbHelper: fixture.helper,
        referenceRepo: referenceRepo,
        guard: writeGuard ?? guard,
        queue: syncQueue ?? queue,
        audit: auditLogger ?? audit,
      );

  Map<String, dynamic> samplePayload({String entryCode = 'S-1'}) => {
        'entry_code': entryCode,
        'material_id': 1,
        'inspection_date': '2026-09-01',
        'supplier': 'Cement Supplier Co',
        'sample_taken_by': 'Mohamed Ali',
        'quantity': '10',
        'sample_names': ['S1'],
        'physical_results': {
          'color': 'good',
        },
        'decision_status': 'APPROVED',
      };

  Future<int> countOf(String table, {String? where, List<Object?>? args}) async {
    final rows = await fixture.db.rawQuery(
        'SELECT COUNT(*) AS c FROM $table${where == null ? '' : ' WHERE $where'}',
        args ?? const []);
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  Future<int> inspections() => countOf('inspections');

  Future<int> queueRows([String? entityType]) => countOf(
      'sync_queue', where: entityType == null ? null : 'entity_type = ?', args: entityType == null ? null : [entityType]);

  Future<int> auditRows([String? action]) => countOf(
      'audit_logs', where: action == null ? null : 'action = ?', args: action == null ? null : [action]);

  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    referenceRepo = ReferenceRepo(dbHelper: fixture.helper);
    queue = SyncQueue(fixture.helper);
    audit = AuditLogger(queue: queue);
    audit.organizationId = 'org_1';
    audit.uid = 'uid_admin';
    audit.userName = 'Ahmed Ali';
    audit.deviceId = 'dev_1';
    guard = _FakeGuard();
    user = const UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin');
  });

  tearDown(() async => fixture.dispose());

  group('P7.3 atomic write', () {
    test('create commits row + queue + audit in one transaction', () async {
      final repo = buildRepo();
      final created = await repo.create(samplePayload(), user);

      expect(await inspections(), 1);
      expect(await queueRows('sample'), 1);
      expect(await queueRows('auditLog'), 1, reason: 'the audit entry replicates too');
      expect(await auditRows(AuditAction.sampleCreated), 1);

      final entry = (await fixture.db.query('sync_queue', where: 'entity_type = ?', whereArgs: ['sample'])).single;
      expect(entry['entity_id'], created['entry_code']);
      expect(entry['local_ref'], created['id']);
      expect(entry['operation'], 'create');
      expect(entry['status'], 'pending');
      expect(entry['base_version'], 0);
      expect('${entry['payload']}', contains('"localId":${created['id']}'));

      final local = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [created['id']])).single;
      expect(local['version'], 1, reason: 'a first push is version 1');
      expect(local['sync_state'], 'queued');
      expect(local['decision_version'], 1, reason: 'the business counter is untouched');
    });

    test('a failing enqueue rolls the whole create back', () async {
      final repo = buildRepo(syncQueue: _FailingQueue(fixture.helper));

      await expectLater(
        repo.create(samplePayload(), user),
        throwsA(isA<StateError>()),
      );

      expect(await inspections(), 0, reason: 'no orphan inspection row');
      expect(await queueRows(), 0);
      expect(await auditRows(), 0);
    });

    test('a failing audit rolls the whole create back', () async {
      final repo = buildRepo(auditLogger: _FailingAudit(queue));

      await expectLater(
        repo.create(samplePayload(), user),
        throwsA(isA<StateError>()),
      );

      expect(await inspections(), 0);
      expect(await queueRows(), 0);
      expect(await auditRows(), 0);
    });

    test('update bumps the version, collapses the queue and keeps the count', () async {
      final repo = buildRepo();
      final created = await repo.create(samplePayload(), user);
      final id = created['id'] as int;

      await repo.update(id, {'supplier': 'Another Supplier'}, user);

      expect(await inspections(), 1);
      expect(await queueRows('sample'), 1, reason: 'the pending create is refreshed, not duplicated');
      final entry = (await fixture.db.query('sync_queue', where: 'entity_type = ?', whereArgs: ['sample'])).single;
      expect(entry['operation'], 'create', reason: 'create wins over update while it has never synced');
      expect(entry['base_version'], 0);
      final local = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
      expect(local['version'], 1, reason: 'still the first not-yet-acked version');
      expect(local['supplier'], 'Another Supplier');
    });

    test('update after a synced version bumps version and baseVersion', () async {
      final repo = buildRepo();
      final created = await repo.create(samplePayload(), user);
      final id = created['id'] as int;
      await fixture.db.update('inspections',
          {'remote_version': 1, 'version': 1, 'sync_state': 'synced'},
          where: 'id = ?', whereArgs: [id]);
      await fixture.db.delete('sync_queue');

      await repo.update(id, {'supplier': 'Third Supplier'}, user);

      final entry = (await fixture.db.query('sync_queue', where: 'entity_type = ?', whereArgs: ['sample'])).single;
      expect(entry['operation'], 'update');
      expect(entry['base_version'], 1);
      final local = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
      expect(local['version'], 2);
      expect(local['remote_version'], 1);
      expect(local['sync_state'], 'queued');
    });

    test('a decision writes the sample, the qc history and both queue rows together', () async {
      final repo = buildRepo();
      final created = await repo.create(samplePayload(), user);
      final id = created['id'] as int;

      await repo.updateStatus(id, {
        'decision_status': 'PARTIAL_REJECTION',
        'decision_reason': 'Moisture above the limit',
        'rejected_quantity': '2',
      }, user);

      expect(await queueRows('sample'), 1);
      expect(await queueRows('qualityCheck'), 1);
      expect(await auditRows(AuditAction.qcRejected), 1);
      final qc = (await fixture.db.query('sync_queue', where: 'entity_type = ?', whereArgs: ['qualityCheck'])).single;
      expect('${qc['entity_id']}', startsWith('qc_${id}_'));
      final local = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
      expect(local['decision_status'], 'PARTIAL_REJECTION');
      expect(local['decision_version'], 2, reason: 'the business decision counter advances');
      expect(local['version'], 1, reason: 'the sync version is separate');
      final history = await fixture.db.query('inspection_status_history',
          where: 'inspection_id = ?', whereArgs: [id]);
      expect(history, hasLength(1));
      expect(history.single['version'], 2);
    });

    test('a failing qc enqueue rolls the decision and its history back', () async {
      final created = await buildRepo().create(samplePayload(), user);
      final id = created['id'] as int;
      await fixture.db.delete('audit_logs');
      await fixture.db.delete('sync_queue');

      // The sample enqueue succeeds, the qualityCheck one throws: neither the
      // decision nor its append-only history row may survive.
      final flaky = _FlakyOnQualityCheck(fixture.helper);
      await expectLater(
        buildRepo(syncQueue: flaky).updateStatus(id, {
          'decision_status': 'FULL_REJECTION',
          'decision_reason': 'Failed the whole lot',
        }, user),
        throwsA(isA<StateError>()),
      );

      expect(flaky.calls, 2, reason: 'the sample queue was written before the qc one failed');
      final local =
          (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
      expect(local['decision_status'], 'APPROVED', reason: 'the original decision is untouched');
      expect(local['decision_version'], 1);
      expect(await fixture.db.query('inspection_status_history',
          where: 'inspection_id = ?', whereArgs: [id]), isEmpty);
      expect(await queueRows(), 0);
      expect(await auditRows(), 0);
    });

    test('delete tombstones the row, hides it from the lists and queues it', () async {
      final repo = buildRepo();
      final created = await repo.create(samplePayload(), user);
      final id = created['id'] as int;
      await fixture.db.delete('sync_queue');

      await repo.delete(id);

      expect(await inspections(), 1, reason: 'the row survives so the deletion can replicate');
      final local = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
      expect(local['deleted_at'], isNotNull);
      expect(await repo.list(), isEmpty, reason: 'a tombstone leaves the working set');
      expect(await repo.count(), 0);
      final entry = (await fixture.db.query('sync_queue', where: 'entity_type = ?', whereArgs: ['sample'])).single;
      expect(entry['operation'], 'tombstone');
      expect(await auditRows(AuditAction.sampleDeleted), 1);
    });

    test('a failing enqueue rolls the tombstone back', () async {
      final repo = buildRepo();
      final created = await repo.create(samplePayload(), user);
      final id = created['id'] as int;
      final failing = _FailingQueue(fixture.helper);

      await expectLater(
        buildRepo(syncQueue: failing).delete(id),
        throwsA(isA<StateError>()),
      );
      final local = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
      expect(local['deleted_at'], isNull, reason: 'the tombstone is rolled back with the queue');
    });
  });

  group('§9.4 local guards', () {
    test('a role without the permission is refused before anything is written', () async {
      final repo = buildRepo(writeGuard: _FakeGuard(allowed: {Permission.samplesRead}));

      await expectLater(
        repo.create(samplePayload(), user),
        throwsA(isA<AuthorizationError>()),
      );
      expect(await inspections(), 0);
      expect(await queueRows(), 0);
      expect(await auditRows(), 0);
    });

    test('a privileged decision needs connectivity', () async {
      final repo = buildRepo(writeGuard: _FakeGuard(online: false));
      final created = await repo.create(samplePayload(), user);

      await expectLater(
        repo.updateStatus(created['id'] as int, {
          'decision_status': 'FULL_REJECTION',
          'decision_reason': 'Failed the whole lot',
        }, user),
        throwsA(isA<AuthorizationError>()),
      );
      final local = (await fixture.db.query('inspections',
          where: 'id = ?', whereArgs: [created['id']])).single;
      expect(local['decision_status'], 'APPROVED', reason: 'the decision never ran');
      expect(local['decision_version'], 1);
      expect(await queueRows('qualityCheck'), 0);
      expect(await fixture.db.query('inspection_status_history'),
          isEmpty, reason: 'no history row for a refused decision');
    });

    test('a read-only device cannot write at all', () async {
      final repo = buildRepo(writeGuard: _FakeGuard(allowed: const {}));
      await expectLater(
        repo.create(samplePayload(), user),
        throwsA(isA<AuthorizationError>()),
      );
      expect(await inspections(), 0);
    });
  });
}

/// Fails only for the `qualityCheck` enqueue, after the sample one succeeded.
class _FlakyOnQualityCheck extends SyncQueue {
  _FlakyOnQualityCheck(super.dbHelper);

  int calls = 0;

  @override
  Future<void> enqueue(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
    int? localRef,
    required String operation,
    required Map<String, dynamic> payload,
    int baseVersion = 0,
  }) async {
    calls++;
    if (entityType == 'qualityCheck') throw StateError('qc enqueue failed on purpose');
    return super.enqueue(
      txn,
      entityType: entityType,
      entityId: entityId,
      localRef: localRef,
      operation: operation,
      payload: payload,
      baseVersion: baseVersion,
    );
  }
}
