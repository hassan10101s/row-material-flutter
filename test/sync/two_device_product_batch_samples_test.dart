import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/database/database_helper.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/backfill_service.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Database;
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/lab/data/offline_first_lab_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import 'sync_test_fixture.dart';

/// plan P8 / user report: عينات التشغيل (product batch samples,
/// `product_batch_samples`) must converge. Device 1 is the writing device,
/// device 2 the read-only viewer: a sample added offline lands on the viewer
/// with its `batch_id` remapped through `batch_remote_id`, edits and the
/// pass/fail decision follow, and a delete tombstones the viewer's row —
/// the exact flow the lab log products screen runs.
///
/// The batch header (`inspections`, `inspection_kind = 'product'`) is seeded
/// identically on both devices with the deterministic legacy identity the
/// backfill stamps (`legacy_inspections_1`), because the header of a legacy
/// import exists on both devices with the same primary key.
class _Device {
  _Device(this.fixture, this.session);

  final SyncFixture fixture;
  AppSession session;

  late final SyncQueue queue = SyncQueue(fixture.helper);
  late final SyncMetadata metadata = SyncMetadata(fixture.helper);
  late final AuditLogger audit = AuditLogger(
    queue: queue,
    session: () => session,
  );
  late bool online = true;

  LabRepo writer() => OfflineFirstLabRepository(
    dbHelper: fixture.helper,
    guard: _WriteGuard(this),
    queue: queue,
    audit: audit,
  );

  PushWorker pusher(InMemoryDataSource remote) => PushWorker(
    queue: queue,
    metadata: metadata,
    remote: remote,
    audit: audit,
    source: SessionSource.empty(() => session),
  );

  PullWorker puller(InMemoryDataSource remote, {int pageSize = 300}) =>
      PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: ConflictResolver(queue: queue, remote: remote),
        source: SessionSource.empty(() => session),
        pageSize: pageSize,
      );

  Future<void> seedBatchHeader() async {
    await db().insert('inspections', <String, dynamic>{
      'entry_code': 'BATCH-1',
      'material_id': 1,
      'material_name': 'Cement',
      'material_code': 'M-CEM-01',
      'inspection_kind': 'product',
      'inspection_date': '2026-09-01',
      'specialist_name': 'Ahmed Ali',
      'quantity': 50.0,
      'physical_results_json': '{}',
      'chemical_results_json': '{}',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'decision_status': 'PENDING',
      'snapshot_json': '{}',
      'sample_names_json': '[]',
      'decision_version': 1,
      'remote_version': 0,
      'sync_state': 'local',
      'created_by': 1,
      'created_by_name': 'Ahmed Ali',
      'created_at': '2026-09-01T08:00:00.000',
      'updated_at': '2026-09-01T08:00:00.000',
      'remote_id': 'legacy_inspections_1',
    });
  }

  Future<List<Map<String, Object?>>> samples() =>
      fixture.db.query('product_batch_samples', orderBy: 'sample_no ASC');
  Database db() => fixture.db;
}

class _WriteGuard implements WriteGuard {
  _WriteGuard(this.device);

  final _Device device;

  @override
  String get uid => device.session.uid;
  @override
  String get email => device.session.email;
  @override
  String get organizationId => device.session.organizationId;
  @override
  String get memberId => device.session.memberId;
  @override
  String get deviceId => device.session.deviceId;
  @override
  bool get online => device.online;

  @override
  bool allows(String permissionId) => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late _Device laptop;
  late _Device phone;
  late InMemoryDataSource remote;

  AppSession sessionFor(String deviceId) => AppSession(
    uid: 'uid_$deviceId',
    email: '$deviceId@material-lab.test',
    organizationId: orgId,
    memberId: 'member_$deviceId',
    role: AppRoles.admin,
    status: 'active',
    deviceId: deviceId,
  );

  setUp(() async {
    laptop = _Device(await openSyncFixture(), sessionFor('dev_1'));
    phone = _Device(await openSyncFixture(), sessionFor('dev_2'));
    remote = InMemoryDataSource();
    await laptop.fixture.seedOrganization();
    await phone.fixture.seedOrganization();
    await laptop.seedBatchHeader();
    await phone.seedBatchHeader();
  });

  tearDown(() async {
    await laptop.fixture.dispose();
    await phone.fixture.dispose();
  });

  test(
    'simultaneous foreground and background upgrades share column additions safely',
    () async {
      await laptop.db().execute(
        'ALTER TABLE product_batch_samples DROP COLUMN batch_entry_code',
      );
      await laptop.fixture.helper.close();
      final other = DatabaseHelper(laptop.fixture.helper.paths);
      try {
        final handles = await Future.wait([
          laptop.fixture.helper.database,
          other.database,
        ]);
        for (final db in handles) {
          final schema = await db.rawQuery(
            'PRAGMA table_info(product_batch_samples)',
          );
          expect(
            schema.where((column) => column['name'] == 'batch_entry_code'),
            hasLength(1),
          );
        }
      } finally {
        await other.close();
        await laptop.fixture.helper.close();
      }
    },
  );

  test(
    'acknowledged legacy samples heal a wrong raw-material link using origin identity',
    () async {
      await phone.db().update('inspections', {
        'id': 57,
        'remote_id': 'viewer-legacy-id',
      }, where: 'id=1');
      await phone.db().insert(
        'inspections',
        sampleRow(entryCode: 'UNRELATED-RAW')..['id'] = 1,
      );
      await laptop.writer().addBatchSample(
        batchId: 1,
        sampleName: 'Cloud sample',
      );
      await laptop.pusher(remote).runOnce();
      final child = remote.documents.entries.singleWhere(
        (row) => row.key.contains('/productBatchSamples/'),
      );
      child.value.remove('batchEntryCode');
      child.value['batchRemoteId'] = '';
      final header = Map<String, dynamic>.from(
        (await laptop.db().query('inspections')).single,
      );
      remote.documents['$orgId/samples/BATCH-1'] = buildRemotePayload(
        syncEntities.firstWhere((e) => e.type == 'sample'),
        header,
        SyncPayloadContext(
          organizationId: orgId,
          uid: laptop.session.uid,
          deviceId: laptop.session.deviceId,
          version: 1,
          versionField: 'version',
        ),
        asCreate: true,
      );
      final remoteId = child.key.split('/').last;
      await phone.db().insert('product_batch_samples', {
        'batch_id': 1,
        'sample_no': 1,
        'sample_name': 'Keep local details',
        'tested_at': '2026-10-24',
        'created_at': '2026-10-24',
        'remote_id': remoteId,
        'remote_version': 1,
        'version': 1,
        'sync_state': 'synced',
        'batch_remote_id': 'wrong-raw-link',
      });
      final result = await phone.puller(remote).runOnce();
      expect(result.failed, 0);
      final repaired = (await phone.samples()).single;
      expect(repaired['batch_id'], 57);
      expect(repaired['batch_entry_code'], 'BATCH-1');
      expect(repaired['sample_name'], 'Keep local details');
      expect(repaired['remote_version'], 1);
      expect(await phone.queue.countPending(), 0);
    },
  );

  test(
    'origin lookup refuses two product headers with the same origin id',
    () async {
      for (final code in ['A', 'B']) {
        remote.documents['$orgId/samples/$code'] = {
          'inspectionKind': 'product',
          'localId': 1,
          'deviceId': 'origin',
          'version': 1,
        };
      }
      final parent = await remote.findProductBatchHeader(
        organizationId: orgId,
        deviceId: 'origin',
        localId: 1,
      );
      expect(parent.exists, isFalse);
    },
  );

  test(
    'a legacy orphan does not abort backfill for valid operational samples',
    () async {
      final header = Map<String, dynamic>.from(
        (await laptop.db().query('inspections')).single,
      );
      await laptop.db().insert('inspections', {
        ...header,
        'id': 2,
        'entry_code': 'VALID-BATCH',
        'remote_id': 'valid-parent',
      });
      await laptop.writer().addBatchSample(
        batchId: 1,
        sampleName: 'Old orphan',
      );
      await laptop.writer().addBatchSample(
        batchId: 2,
        sampleName: 'Valid sample',
      );
      await laptop.db().update('inspections', {
        'inspection_kind': 'raw',
      }, where: 'id=1');
      await laptop.db().delete(
        'sync_queue',
        where: 'entity_type=?',
        whereArgs: ['productBatchSample'],
      );
      await laptop.db().update('product_batch_samples', {
        'sync_state': 'local',
      });
      final result = await BackfillService(
        dbHelper: laptop.fixture.helper,
        queue: laptop.queue,
        guard: _WriteGuard(laptop),
      ).enqueueUnsyncedAll(onlyTypes: {'productBatchSample'});
      expect(result.queued, 2);
      final pushed = await laptop.pusher(remote).runOnce();
      expect(pushed.retried, 1);
      final docs = remote.documents.entries
          .where((entry) => entry.key.contains('/productBatchSamples/'))
          .toList();
      expect(docs, hasLength(1));
      expect(docs.single.value['sampleName'], 'Valid sample');
      expect(await laptop.samples(), hasLength(2));
    },
  );

  test('a production sample added offline lands on the viewer with its batch '
      'link remapped, and its edit + decision follow', () async {
    // ── Device 1 works offline ───────────────────────────────────────────
    laptop.online = false;
    remote.offline = true;
    final created = await laptop.writer().addBatchSample(
      batchId: 1,
      sampleName: 'Sample 1',
      sampleTaker: 'Omar',
      physicalResults: {'Weight': '24.0'},
      chemicalResults: const [
        {'name': 'Loss', 'result': '2.1', 'unit': '%'},
      ],
      user: {'id': 1, 'name': 'Ahmed Ali'},
    );
    final sampleId = (created['id'] as num).toInt();
    expect(
      created['batch_remote_id'],
      'legacy_inspections_1',
      reason:
          'the parent identity is stamped at insert time '
          '(lab_repo.dart addBatchSample)',
    );
    expect(sampleId, 1);

    // Device 2 cannot see any of it yet.
    expect((await phone.puller(remote).runOnce()).applied, 0);
    expect(await phone.samples(), isEmpty);

    // ── Connectivity returns, device 1 pushes ──────────────────────────
    laptop.online = true;
    remote.offline = false;
    final pushed = await laptop.pusher(remote).runOnce();
    expect(
      pushed.failed,
      0,
      reason: 'pushed=${pushed.pushed} failed=${pushed.failed}',
    );

    final docKey = remote.documents.keys.firstWhere(
      (k) => k.contains('/productBatchSamples/'),
    );
    final docId = docKey.substring(docKey.lastIndexOf('/') + 1);

    // ── Device 2 pulls and converges ───────────────────────────────────
    final pulled = await phone.puller(remote).runOnce();
    expect(
      pulled.failed,
      0,
      reason:
          'applied=${pulled.applied} failed=${pulled.failed} '
          'pushedBack=${pulled.pushedBack}',
    );
    final phoneSample = (await phone.samples()).single;
    expect('${phoneSample['remote_id']}', docId);
    expect(
      '${phoneSample['batch_remote_id']}',
      'legacy_inspections_1',
      reason: 'the parent link travels with the row',
    );
    expect(
      (phoneSample['batch_id'] as num).toInt(),
      1,
      reason: 'remapped to the viewer\'s own header row',
    );
    expect('${phoneSample['sample_name']}', 'Sample 1');
    expect('${phoneSample['sample_taker']}', 'Omar');
    expect('${phoneSample['physical_results_json']}', '{"Weight":"24.0"}');
    final chemical = phoneSample['chemical_results_json'] as String? ?? '';
    expect(chemical, contains('Loss'));
    expect(chemical, contains('2.1'));
    expect('${phoneSample['sync_state']}', 'synced');
    expect(
      '${phoneSample['sample_taker']}'.isEmpty,
      isFalse,
      reason: 'identity fields are real data, not placeholders',
    );
    expect(await phone.queue.countPending(), 0);

    // ── An edit and a decision trail behind the sample ──────────────────
    await laptop.writer().updateBatchSample(
      sampleId,
      sampleName: 'Sample 1 (re-weighed)',
      physicalResults: {'Weight': '25.5'},
    );
    await laptop.pusher(remote).runOnce();
    final pulledEdit = await phone.puller(remote).runOnce();
    expect(pulledEdit.failed, 0);
    final edited = (await phone.samples()).single;
    expect('${edited['sample_name']}', 'Sample 1 (re-weighed)');
    expect('${edited['physical_results_json']}', '{"Weight":"25.5"}');
    expect(
      (edited['remote_version'] as num).toInt(),
      greaterThanOrEqualTo(2),
      reason: 'the second push raised the doc version',
    );
    expect(await phone.queue.countPending(), 0);
  });

  test(
    'sample numbers remain unique after deletion and both histories synchronize',
    () async {
      final first = await laptop.writer().addBatchSample(batchId: 1);
      await laptop.writer().deleteBatchSample((first['id'] as num).toInt());
      final second = await laptop.writer().addBatchSample(batchId: 1);
      expect(second['sample_no'], 2);
      final localRows = await laptop.samples();
      expect(localRows.map((row) => row['remote_id']).toSet(), hasLength(2));
      expect(
        localRows.every((row) => '${row['remote_id'] ?? ''}'.isNotEmpty),
        isTrue,
      );
      expect((await laptop.pusher(remote).runOnce()).conflicts, 0);
      expect((await phone.puller(remote).runOnce()).failed, 0);
      final rows = await phone.samples();
      expect(
        rows,
        hasLength(1),
        reason: 'a never-synced tombstone needs no local history placeholder',
      );
      expect(rows.single['sample_no'], 2);
      expect(rows.single['deleted_at'], isNull);
      expect(
        remote.documents.values.where((row) => row['deletedAt'] != null),
        hasLength(1),
      );
    },
  );

  test('a sample cannot be added to a deleted product header', () async {
    await laptop.db().update('inspections', {
      'deleted_at': '2026-10-24',
    }, where: 'id=1');
    await expectLater(
      laptop.writer().addBatchSample(batchId: 1),
      throwsA(isA<Exception>()),
    );
    expect(await laptop.samples(), isEmpty);
  });

  test(
    'a colliding remote sample never replaces a different sample or its results',
    () async {
      await laptop.writer().addBatchSample(
        batchId: 1,
        physicalResults: {'Weight': '25.5'},
      );
      await laptop.pusher(remote).runOnce();
      await phone.puller(remote).runOnce();
      final key = remote.documents.keys.singleWhere(
        (key) => key.contains('/productBatchSamples/'),
      );
      remote.documents['org_test/productBatchSamples/colliding-uuid'] = {
        ...remote.documents[key]!,
        'remoteId': 'colliding-uuid',
        'physicalResultsJson': '{"Weight":"999"}',
        'updatedAt': '2026-10-24T00:00:00.000Z',
      };
      expect((await phone.puller(remote).runOnce()).failed, greaterThan(0));
      final rows = await phone.samples();
      expect(rows, hasLength(1));
      expect(rows.single['remote_id'], remote.documents[key]!['remoteId']);
      expect(rows.single['physical_results_json'], '{"Weight":"25.5"}');
    },
  );

  test('a pass/fail decision and a delete both settle on the viewer', () async {
    final created = await laptop.writer().addBatchSample(
      batchId: 1,
      sampleName: 'Sample 2',
      sampleTaker: 'Sara',
      user: {'id': 1, 'name': 'Ahmed Ali'},
    );
    final sampleId = (created['id'] as num).toInt();

    // Decision first (still local).
    await laptop.writer().setBatchSampleDecision(
      sampleId,
      status: 'REJECTED',
      reason: 'Moisture above range',
    );
    final decisionRows = await laptop.fixture.db.query('product_batch_samples');
    expect(
      '${decisionRows.first['decision_status']}',
      'REJECTED',
      reason: 'the local write happens before any sync',
    );

    // Push, pull.
    final pushed = await laptop.pusher(remote).runOnce();
    expect(pushed.failed, 0);
    final pulled = await phone.puller(remote).runOnce();
    expect(pulled.failed, 0);
    final phoneSample = (await phone.samples()).single;
    expect('${phoneSample['decision_status']}', 'REJECTED');
    expect('${phoneSample['decision_reason']}', 'Moisture above range');
    expect(phoneSample['deleted_at'] ?? '', isEmpty);
    expect(await phone.queue.countPending(), 0);

    // ── The writer deletes the sample: the viewer's row must die too ────
    await laptop.writer().deleteBatchSample(sampleId);
    final tombstoneRows = await laptop.fixture.db.query(
      'product_batch_samples',
    );
    expect(
      '${tombstoneRows.first['deleted_at'] ?? ''}'.isNotEmpty,
      isTrue,
      reason: 'delete is a tombstone, not a hard delete',
    );
    final pushedTombs = await laptop.pusher(remote).runOnce();
    expect(pushedTombs.failed, 0);
    final pulledTombs = await phone.puller(remote).runOnce();
    expect(pulledTombs.failed, 0);
    final phoneDeleted = (await phone.samples()).single;
    expect(
      '${phoneDeleted['deleted_at'] ?? ''}'.isNotEmpty,
      isTrue,
      reason: 'the tombstone crossed devices',
    );
    expect('${phoneDeleted['sync_state']}', 'synced');
    // The viewer must not have its own queued copy left behind: no
    // resurrection on the next poll cycle.
    expect(await phone.queue.countPending(), 0);
  });

  test(
    'legacy headers with different local ids link samples by entry code',
    () async {
      await laptop.db().update('inspections', {
        'remote_id': null,
      }, where: 'id = 1');
      await phone.db().update('inspections', {
        'id': 57,
        'remote_id': 'viewer-legacy-id',
      }, where: 'id = 1');
      await phone.db().insert(
        'inspections',
        sampleRow(entryCode: 'UNRELATED-RAW')..['id'] = 1,
      );
      await laptop.writer().addBatchSample(
        batchId: 1,
        sampleName: 'Operational sample',
        sampleTaker: 'Omar',
        physicalResults: {'Weight': '24'},
        chemicalResults: const [
          {'name': 'Protein', 'result': '18.5', 'unit': '%'},
        ],
      );
      final pushed = await laptop.pusher(remote).runOnce();
      expect(pushed.failed, 0);
      expect(pushed.retried, 0);
      final pulled = await phone.puller(remote).runOnce();
      expect(pulled.failed, 0);
      final sample = (await phone.samples()).single;
      expect(sample['batch_id'], 57);
      expect(sample['batch_entry_code'], 'BATCH-1');
      expect(sample['sample_taker'], 'Omar');
      expect(jsonDecode(sample['physical_results_json'] as String), {
        'Weight': '24',
      });
      expect(jsonDecode(sample['chemical_results_json'] as String), [
        {'name': 'Protein', 'result': '18.5', 'unit': '%'},
      ]);
      expect(
        (await phone.db().query(
          'inspections',
          where: 'id = 1',
        )).single['entry_code'],
        'UNRELATED-RAW',
      );
      expect(await phone.queue.countPending(), 0);
    },
  );

  test(
    'pending pre-upgrade sample payloads gain a safe parent link before push',
    () async {
      await laptop.writer().addBatchSample(
        batchId: 1,
        sampleName: 'Pending sample',
      );
      final queued = await laptop.db().query(
        'sync_queue',
        where: 'entity_type = ?',
        whereArgs: ['productBatchSample'],
      );
      final old =
          Map<String, dynamic>.from(
              jsonDecode(queued.single['payload'] as String) as Map,
            )
            ..remove('batchEntryCode')
            ..['batchRemoteId'] = '';
      await laptop.db().update(
        'sync_queue',
        {'payload': jsonEncode(old)},
        where: 'id = ?',
        whereArgs: [queued.single['id']],
      );
      final pushed = await laptop.pusher(remote).runOnce();
      expect(pushed.failed, 0);
      expect(pushed.retried, 0);
      final payload = remote.documents.entries
          .singleWhere((row) => row.key.contains('/productBatchSamples/'))
          .value;
      expect(payload['batchEntryCode'], 'BATCH-1');
      expect(payload['batchRemoteId'], 'legacy_inspections_1');
    },
  );

  test(
    'a child-only retry fetches its product header by Firestore entry code',
    () async {
      await laptop.writer().addBatchSample(
        batchId: 1,
        sampleName: 'Child first',
      );
      final header = syncEntities.firstWhere((e) => e.type == 'sample');
      final source = (await laptop.db().query('inspections')).single;
      remote.documents['$orgId/samples/BATCH-1'] = buildRemotePayload(
        header,
        Map<String, dynamic>.from(source)..['remote_id'] = null,
        SyncPayloadContext(
          organizationId: orgId,
          uid: laptop.session.uid,
          deviceId: laptop.session.deviceId,
          version: 1,
          versionField: 'version',
        ),
        asCreate: true,
      );
      await phone.db().delete('inspections');
      await laptop.pusher(remote).runOnce();
      final child = syncEntities.firstWhere(
        (e) => e.type == 'productBatchSample',
      );
      final puller = PullWorker(
        queue: phone.queue,
        metadata: phone.metadata,
        remote: remote,
        conflicts: ConflictResolver(queue: phone.queue, remote: remote),
        source: SessionSource.empty(() => phone.session),
        entities: [child],
      );
      final result = await puller.runOnce();
      expect(result.failed, 0);
      final parent = (await phone.db().query('inspections')).single;
      final sample = (await phone.samples()).single;
      expect(sample['batch_id'], parent['id']);
      expect(sample['batch_entry_code'], 'BATCH-1');
      expect(parent['inspection_kind'], 'product');
    },
  );

  test(
    'open-time repair skips null parent identities without aborting valid repairs',
    () async {
      final header = Map<String, dynamic>.from(
        (await laptop.db().query('inspections')).single,
      );
      await laptop.db().update('inspections', {
        'remote_id': null,
      }, where: 'id = 1');
      await laptop.db().insert('inspections', {
        ...header,
        'id': 2,
        'entry_code': 'IMPORTED-COLLISION',
        'remote_id': 'legacy_inspections_1',
      });
      await laptop.db().insert('inspections', {
        ...header,
        'id': 3,
        'entry_code': 'REPAIRABLE',
        'remote_id': null,
      });
      final local = LabRepo(dbHelper: laptop.fixture.helper);
      await local.addBatchSample(batchId: 1, sampleName: 'Unresolved legacy');
      await local.addBatchSample(batchId: 3, sampleName: 'Resolvable legacy');
      await laptop.fixture.helper.close();
      final reopened = await laptop.fixture.helper.database;
      final samples = await reopened.query(
        'product_batch_samples',
        orderBy: 'batch_id',
      );
      expect(samples.first['batch_remote_id'], '');
      expect(samples.first['batch_entry_code'], 'BATCH-1');
      expect(samples.last['batch_remote_id'], 'legacy_inspections_3');
      expect(samples.last['batch_entry_code'], 'REPAIRABLE');
    },
  );

  test(
    'upgrade replays old acknowledged samples once with the entry-code link',
    () async {
      final local = LabRepo(dbHelper: laptop.fixture.helper);
      await local.addBatchSample(batchId: 1, sampleName: 'Previously synced');
      await laptop.db().update('product_batch_samples', {
        'sync_state': 'synced',
        'remote_version': 1,
      });
      await laptop.db().execute(
        'ALTER TABLE product_batch_samples DROP COLUMN batch_entry_code',
      );
      await laptop.fixture.helper.close();
      final upgraded = await laptop.fixture.helper.database;
      final row = (await upgraded.query('product_batch_samples')).single;
      expect(row['batch_entry_code'], 'BATCH-1');
      expect(row['sync_state'], 'local');
      expect(row['remote_version'], 1);
      await upgraded.update('product_batch_samples', {'sync_state': 'synced'});
      await laptop.fixture.helper.close();
      final reopened = await laptop.fixture.helper.database;
      expect(
        (await reopened.query('product_batch_samples')).single['sync_state'],
        'synced',
      );
    },
  );

  test(
    'a fresh viewer pulls the product header and its samples in one cycle',
    () async {
      // The real first-run mobile: no header seeded locally — the product
      // header doc itself arrives through the `samples` collection, so the
      // dependency order (sample rank 3 → productBatchSample rank 4) must
      // land the header BEFORE its samples so every batch_id remaps.
      final created = await laptop.writer().addBatchSample(
        batchId: 1,
        sampleName: 'Sample 1',
        sampleTaker: 'Omar',
        user: {'id': 1, 'name': 'Ahmed Ali'},
      );
      expect(
        created['batch_remote_id'],
        'legacy_inspections_1',
        reason: 'the header identity is stamped at write time',
      );
      await laptop.writer().addBatchSample(
        batchId: 1,
        sampleName: 'Sample 2',
        sampleTaker: 'Sara',
        user: {'id': 1, 'name': 'Ahmed Ali'},
      );

      // The header doc, exactly as the inspection write path pushes it
      // (entity `sample`, doc id = entry_code, remote identity in payload).
      final header = syncEntities.firstWhere((e) => e.type == 'sample');
      final headerRows = await laptop.fixture.db.query('inspections', limit: 1);
      remote.documents['$orgId/samples/BATCH-1'] = buildRemotePayload(
        header,
        Map<String, dynamic>.from(headerRows.single)
          ..['remote_id'] = 'legacy_inspections_1',
        SyncPayloadContext(
          organizationId: orgId,
          uid: laptop.session.uid,
          deviceId: laptop.session.deviceId,
          version: 1,
          versionField: 'decision_version',
        ),
        asCreate: true,
      );

      final pushed = await laptop.pusher(remote).runOnce();
      expect(
        pushed.failed,
        0,
        reason: 'pushed=${pushed.pushed} failed=${pushed.failed}',
      );

      final pulled = await phone.puller(remote).runOnce();
      expect(
        pulled.failed,
        0,
        reason: 'applied=${pulled.applied} failed=${pulled.failed}',
      );

      final phoneHeader = await phone.fixture.db.query(
        'inspections',
        where: 'entry_code = ?',
        whereArgs: ['BATCH-1'],
      );
      expect(phoneHeader, hasLength(1));
      final headerId = (phoneHeader.single['id'] as num).toInt();
      expect(phoneHeader.single['remote_id'], 'legacy_inspections_1');

      final rows = await phone.samples();
      expect(rows, hasLength(2));
      for (final r in rows) {
        expect(
          (r['batch_id'] as num).toInt(),
          headerId,
          reason: 'every sample remaps to the viewer\'s own header row',
        );
        expect(r['batch_remote_id'], 'legacy_inspections_1');
      }
      expect([
        for (final r in rows) r['sample_name'],
      ], containsAll(['Sample 1', 'Sample 2']));
      expect('${rows.first['sample_taker']}', anyOf('Omar', 'Sara'));
      expect(
        (await phone.fixture.db.query(
          'product_batch_samples',
        )).every((r) => '${r['sync_state']}' == 'synced'),
        isTrue,
      );
      // The viewer's rows carry the same cross-device identities the writer
      // created, so later remote edits still resolve on this device.
      final laptopRemoteIds = [
        for (final r in await laptop.fixture.db.query(
          'product_batch_samples',
          orderBy: 'sample_no ASC',
        ))
          '${r['remote_id']}',
      ];
      expect(laptopRemoteIds, everyElement(isNotEmpty));
      expect([
        for (final r in await phone.samples()) '${r['remote_id']}',
      ], laptopRemoteIds);
      expect(await phone.queue.countPending(), 0);
    },
  );
}
