import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
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
    'a production sample added offline lands on the viewer with its batch '
    'link remapped, and its edit + decision follow',
    () async {
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
      expect(created['batch_remote_id'], 'legacy_inspections_1',
          reason: 'the parent identity is stamped at insert time '
              '(lab_repo.dart addBatchSample)');
      expect(sampleId, 1);

      // Device 2 cannot see any of it yet.
      expect((await phone.puller(remote).runOnce()).applied, 0);
      expect(await phone.samples(), isEmpty);

      // ── Connectivity returns, device 1 pushes ──────────────────────────
      laptop.online = true;
      remote.offline = false;
      final pushed = await laptop.pusher(remote).runOnce();
      expect(pushed.failed, 0,
          reason: 'pushed=${pushed.pushed} failed=${pushed.failed}');

      final docKey = remote.documents.keys
          .firstWhere((k) => k.contains('/productBatchSamples/'));
      final docId = docKey.substring(docKey.lastIndexOf('/') + 1);

      // ── Device 2 pulls and converges ───────────────────────────────────
      final pulled = await phone.puller(remote).runOnce();
      expect(pulled.failed, 0,
          reason: 'applied=${pulled.applied} failed=${pulled.failed} '
              'pushedBack=${pulled.pushedBack}');
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
      final chemical =
          phoneSample['chemical_results_json'] as String? ?? '';
      expect(chemical, contains('Loss'));
      expect(chemical, contains('2.1'));
      expect('${phoneSample['sync_state']}', 'synced');
      expect('${phoneSample['sample_taker']}'.isEmpty, isFalse,
          reason: 'identity fields are real data, not placeholders');
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
    },
  );

  test(
    'a pass/fail decision and a delete both settle on the viewer',
    () async {
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
      final decisionRows =
          await laptop.fixture.db.query('product_batch_samples');
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
      expect(
        '${phoneSample['decision_reason']}',
        'Moisture above range',
      );
      expect(phoneSample['deleted_at'] ?? '', isEmpty);
      expect(await phone.queue.countPending(), 0);

      // ── The writer deletes the sample: the viewer's row must die too ────
      await laptop.writer().deleteBatchSample(sampleId);
      final tombstoneRows =
          await laptop.fixture.db.query('product_batch_samples');
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
    },
  );
}
