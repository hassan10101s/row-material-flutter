import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/inspections/data/offline_first_inspection_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

import 'sync_test_fixture.dart';

/// Plan P7.5 / §42-6 + §42-7, automated: the Internet is off, an inspection is
/// created through the offline-first facade, it is visible immediately and the
/// change sits in the queue; the Internet comes back and the same push
/// synchronises it. No user-visible action is lost in between.
class _Guard implements WriteGuard {
  _Guard(this._online);

  bool _online;

  @override
  bool get online => _online;
  @override
  String get uid => 'uid_admin';
  @override
  String get organizationId => 'org_test';
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
    // A sample write is not privileged, so it is allowed while offline; §9.4
    // only demands connectivity for the privileged operations.
    return !permissionRequiresFreshSession(permission);
  }

  set online(bool value) => _online = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fixture;
  late SyncQueue queue;
  late SyncMetadata metadata;
  late AuditLogger audit;
  late InMemoryDataSource remote;
  late _Guard guard;
  late OfflineFirstInspectionRepository repo;
  late AppSession session;
  late UserContext user;

  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    queue = SyncQueue(fixture.helper);
    metadata = SyncMetadata(fixture.helper);
    audit = AuditLogger(queue: queue);
    remote = InMemoryDataSource(rolesByUid: const {'uid_admin': 'admin'});
    session = const AppSession(
      uid: 'uid_admin',
      email: 'admin@material-lab.test',
      organizationId: orgId,
      memberId: 'member_1',
      role: 'admin',
      status: 'active',
      deviceId: 'dev_1',
    );
    audit
      ..uid = session.uid
      ..organizationId = orgId
      ..deviceId = session.deviceId
      ..userName = 'Ahmed Ali';
    guard = _Guard(false);
    user = const UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin');
    repo = OfflineFirstInspectionRepository(
      dbHelper: fixture.helper,
      referenceRepo: ReferenceRepo(dbHelper: fixture.helper),
      guard: guard,
      queue: queue,
      audit: audit,
    );
  });

  tearDown(() async => fixture.dispose());

  PushWorker worker() => PushWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        audit: audit,
        source: SessionSource.empty(() => session),
      );

  Map<String, dynamic> payload() => {
        'material_id': 1,
        'inspection_date': '2026-09-01',
        'supplier': 'Cement Supplier Co',
        'sample_taken_by': 'Mohamed Ali',
        'quantity': '10',
        'sample_names': ['S1'],
        'physical_results': {'color': 'good'},
        'decision_status': 'APPROVED',
      };

  test('§42-6/7 offline create is visible at once and syncs when back online',
      () async {
    // ── Internet OFF ────────────────────────────────────────────────────
    remote.offline = true;

    final created = await repo.create(payload(), user);
    final id = created['id'] as int;

    // Visible immediately, from the local source of truth.
    expect((await repo.list()).single['id'], id);
    expect((await repo.getById(id))['supplier'], 'Cement Supplier Co');
    // …and queued for later.
    expect(await queue.countPending(), 2, reason: 'the sample plus its audit entry');
    final local = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
    expect(local['sync_state'], 'queued');

    // Pushing while offline keeps everything in the queue.
    final offlineReport = await worker().runOnce();
    expect(offlineReport.pushed, 0);
    expect(await queue.countPending(), 2);
    expect(remote.documents, isEmpty);

    // ── Internet ON ─────────────────────────────────────────────────────
    remote.offline = false;
    guard.online = true;

    final report = await worker().runOnce();
    expect(report.pushed, 2, reason: 'the sample and its audit entry');
    expect(report.failed, 0);

    final doc = remote.documents['$orgId/samples/${created['entry_code']}'];
    expect(doc, isNotNull, reason: 'it reached organizations/{orgId}/samples');
    expect(doc!['localId'], id);
    expect(doc['version'], 1);
    expect(doc['supplier'], 'Cement Supplier Co');

    final synced = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
    expect(synced['sync_state'], 'synced');
    expect(synced['remote_version'], 1);
    expect(await queue.countPending(), 0);
  });

  test('§42-6 a tombstone made offline replicates once the network returns',
      () async {
    // First push: the sample reaches the server.
    final created = await repo.create(payload(), user);
    final id = created['id'] as int;
    expect((await worker().runOnce()).failed, 0);
    final docKey = '$orgId/samples/${created['entry_code']}';
    expect(remote.documents[docKey], isNotNull);
    expect(remote.documents[docKey]!['deletedAt'], isNull);

    // ── Internet OFF again, then delete ─────────────────────────────────
    remote.offline = true;
    await repo.delete(id);
    expect(await repo.list(), isEmpty, reason: 'deleted right away for the user');
    final parked = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
    expect(parked['deleted_at'], isNotNull, reason: 'kept locally until the server knows');
    expect((await worker().runOnce()).pushed, 0);

    // ── Internet ON: the deletion replicates as a tombstone ─────────────
    remote.offline = false;
    final report = await worker().runOnce();
    expect(report.failed, 0);
    expect(remote.documents[docKey]!['deletedAt'], isNotNull,
        reason: 'deletedAt, not a document delete (plan §5)');
    expect(remote.documents[docKey]!['localId'], id);
    expect(await queue.countPending(), 0);
  });
}
