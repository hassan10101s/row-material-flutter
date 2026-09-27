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
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/inspections/data/offline_first_inspection_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

import 'sync_test_fixture.dart';

/// Plan §14-P8.4 / §42-8 + §42-9: two devices of the same organization, one
/// offline change on device 1, and device 2 sees it once it syncs.
///
/// Each device gets its **own** SQLite file (the isolation is physical) and
/// they share one remote. Nothing here talks to a real Firebase.
class _Device {
  _Device(this.fixture, this.label, this.session);

  final SyncFixture fixture;
  final String label;
  AppSession session;

  late final SyncQueue queue = SyncQueue(fixture.helper);
  late final SyncMetadata metadata = SyncMetadata(fixture.helper);
  late final AuditLogger audit = AuditLogger(queue: queue, session: () => session);
  late bool online = true;

  SessionSource get source => SessionSource.empty(() => session);

  PushWorker pusher(InMemoryDataSource remote) => PushWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        audit: audit,
        source: source,
      );

  PullWorker puller(InMemoryDataSource remote, {int pageSize = 300}) => PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: ConflictResolver(queue: queue, remote: remote),
        source: source,
        pageSize: pageSize,
      );

  OfflineFirstInspectionRepository repo() => OfflineFirstInspectionRepository(
        dbHelper: fixture.helper,
        referenceRepo: ReferenceRepo(dbHelper: fixture.helper),
        guard: _LiveGuard(this),
        queue: queue,
        audit: audit,
      );

  Future<List<Map<String, Object?>>> rows() => fixture.db.query('inspections');
}

class _LiveGuard implements WriteGuard {
  _LiveGuard(this.device);

  final _Device device;

  @override
  bool get online => device.online;
  @override
  String get uid => device.session.uid;
  @override
  String get organizationId => device.session.organizationId;
  @override
  String get memberId => device.session.memberId;
  @override
  String get deviceId => device.session.deviceId;
  @override
  String get email => device.session.email;

  @override
  bool allows(String permissionId) {
    final permission = Permission.byId(permissionId);
    if (permission == null) return false;
    if (device.session.readOnlyDevice) return false;
    if (!device.session.isActiveMember) return false;
    if (permissionRequiresFreshSession(permission) && !device.online) return false;
    return device.session.can(permission);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late _Device laptop; // device 1: the one that works offline
  late _Device phone; // device 2: sees the result
  late InMemoryDataSource remote;

  AppSession sessionFor(String deviceId, {String role = AppRoles.admin, bool readOnly = false}) =>
      AppSession(
        uid: 'uid_$deviceId',
        email: '$deviceId@material-lab.test',
        organizationId: orgId,
        memberId: 'member_$deviceId',
        role: role,
        status: 'active',
        deviceId: deviceId,
        readOnlyDevice: readOnly,
      );

  setUp(() async {
    final a = await openSyncFixture();
    final b = await openSyncFixture();
    await a.seedOrganization();
    await b.seedOrganization();
    laptop = _Device(a, 'laptop', sessionFor('dev_1'));
    phone = _Device(b, 'phone', sessionFor('dev_2'));
    remote = InMemoryDataSource(
      rolesByUid: const {'uid_dev_1': 'admin', 'uid_dev_2': 'admin'},
    );
  });

  tearDown(() async {
    await laptop.fixture.dispose();
    await phone.fixture.dispose();
  });

  Map<String, dynamic> payload({String supplier = 'Cement Supplier Co'}) => {
        'material_id': 1,
        'inspection_date': '2026-09-01',
        'supplier': supplier,
        'sample_taken_by': 'Mohamed Ali',
        'quantity': '10',
        'sample_names': ['S1'],
        'physical_results': {'color': 'good'},
        'decision_status': 'APPROVED',
      };

  test('§42-8 a sample created offline on device 1 shows up on device 2',
      () async {
    // Device 2 is online and idle: it has nothing yet.
    expect(await phone.rows(), isEmpty);
    expect((await phone.puller(remote).runOnce()).applied, 0);

    // ── Device 1 works offline ───────────────────────────────────────────
    laptop.online = false;
    remote.offline = true; // the shared remote is unreachable for everyone
    final created = await laptop.repo().create(payload(), const UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin'));
    final entryCode = '${created['entry_code']}';

    // Device 2 cannot see it, it simply does not exist yet.
    expect((await phone.puller(remote).runOnce()).applied, 0);
    expect(await phone.rows(), isEmpty);

    // ── Connectivity is back, device 1 pushes ────────────────────────────
    laptop.online = true;
    remote.offline = false;
    final pushed = await laptop.pusher(remote).runOnce();
    expect(pushed.failed, 0);
    expect(pushed.pushed, greaterThanOrEqualTo(1));
    expect(remote.documents.containsKey('$orgId/samples/$entryCode'), isTrue);

    // ── Device 2 pulls and sees it ──────────────────────────────────────
    final pulled = await phone.puller(remote).runOnce();
    expect(pulled.applied, greaterThanOrEqualTo(1));
    final rows = await phone.rows();
    expect(rows.length, 1);
    expect(rows.single['entry_code'], entryCode);
    expect(rows.single['supplier'], 'Cement Supplier Co');
    expect(rows.single['sync_state'], 'synced', reason: 'it came from the server, not from a write');
    expect(rows.single['remote_version'], 1);
    // …and it is not queued for a pointless push back.
    expect(await phone.queue.countPending(), 0);
  });

  test('§42-9 an edit made offline on device 1 reaches device 2, both ways',
      () async {
    // Seed the server from device 1 while online.
    laptop.online = true;
    final created = await laptop.repo().create(payload(), const UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin'));
    await laptop.pusher(remote).runOnce();
    await phone.puller(remote).runOnce();
    expect((await phone.rows()).single['supplier'], 'Cement Supplier Co');

    // ── Device 1 offline: a normal edit is allowed without connectivity ──
    laptop.online = false;
    remote.offline = true;
    final phoneBefore = await phone.rows();
    await laptop.repo().update(
      created['id'] as int,
      <String, dynamic>{
        ...payload(),
        'supplier': 'Cement Supplier Co (revised)',
      },
      const UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin'),
    );
    expect((await phone.rows()).single['supplier'], phoneBefore.single['supplier'],
        reason: 'device 2 is offline too, it cannot know yet');
    expect((await laptop.rows()).single['decision_status'], 'APPROVED',
        reason: 'a plain edit never changes the decision - only updateStatus does');

    // ── Both back online: device 1 pushes, device 2 pulls ───────────────
    laptop.online = true;
    remote.offline = false;
    final pushed = await laptop.pusher(remote).runOnce();
    expect(pushed.failed, 0);
    expect(pushed.conflicts, 0);

    final pulled = await phone.puller(remote).runOnce();
    expect(pulled.applied, greaterThanOrEqualTo(1));
    final row = (await phone.rows()).single;
    expect(row['supplier'], 'Cement Supplier Co (revised)');
    expect(row['remote_version'], 2, reason: 'the edit is version 2 on the server');
    // A plain edit is not a QC decision, so no history document is written.
    expect(remote.documents.keys.any((k) => k.startsWith('$orgId/qualityChecks/')), isFalse);
  });

  test('a QC decision taken on device 1 reaches device 2 as its own document',
      () async {
    laptop.online = true;
    final created = await laptop.repo().create(payload(), const UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin'));
    await laptop.pusher(remote).runOnce();
    await phone.puller(remote).runOnce();
    expect((await phone.rows()).single['decision_status'], 'APPROVED');

    // The decision itself is privileged, so it is taken online.
    await laptop.repo().updateStatus(
      created['id'] as int,
      <String, dynamic>{
        'decision_status': 'CONDITIONAL_APPROVAL',
        'decision_reason': 'matches the reference within tolerance',
        'follow_up_note': 'retest the next truck',
      },
      const UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin'),
    );
    final pushed = await laptop.pusher(remote).runOnce();
    expect(pushed.failed, 0);
    expect(pushed.conflicts, 0);

    final pulled = await phone.puller(remote).runOnce();
    expect(pulled.applied, greaterThanOrEqualTo(1));

    final row = (await phone.rows()).single;
    expect(row['decision_status'], 'CONDITIONAL_APPROVAL');
    expect(row['decision_reason'], 'matches the reference within tolerance');
    expect(row['remote_version'], 2);
    // The append-only qualityCheck document arrived as well.
    final history = await phone.fixture.db.query('inspection_status_history');
    expect(history.length, 1);
    expect(history.single['new_status'], 'CONDITIONAL_APPROVAL');
    expect(history.single['sync_state'], 'synced');
    // …and the local decision counter moved with it.
    expect((await laptop.rows()).single['decision_version'], 2);
  });

  test('a QC decision offline is refused: it is a privileged operation',
      () async {
    laptop.online = true;
    final created = await laptop.repo().create(payload(), const UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin'));
    await laptop.pusher(remote).runOnce();

    laptop.online = false;
    remote.offline = true;
    Object? error;
    try {
      await laptop.repo().updateStatus(
        created['id'] as int,
        <String, dynamic>{'decision_status': 'FULL_REJECTION', 'decision_reason': 'offline try'},
        const UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin'),
      );
    } on Object catch (e) {
      error = e;
    }
    expect(error, isNotNull, reason: '§9.4: qc.* needs connectivity and a fresh token');
    final row = (await laptop.rows()).single;
    expect(row['decision_status'], 'APPROVED', reason: 'nothing was written');
    expect(row['sync_state'], 'synced');
  });

  test('a viewer device cannot write, and its rejection never reaches the server',
      () async {
    phone.session = sessionFor('dev_2', role: AppRoles.viewer, readOnly: true);
    phone.online = true;

    Object? error;
    try {
      await phone.repo().create(payload(supplier: 'Nope'), const UserContext(id: 1, fullName: 'Sara', role: 'viewer'));
    } on Object catch (e) {
      error = e;
    }
    expect(error, isNotNull, reason: 'the write guard refuses it');
    expect(await phone.rows(), isEmpty, reason: 'nothing was written locally');
    expect(await phone.queue.countPending(), 0);

    final report = await phone.pusher(remote).runOnce();
    expect(report.pushed, 0);
    expect(remote.documents, isEmpty);
  });

  test('an unknown role is read-only on both the model and the guard', () {
    final corrupted = sessionFor('dev_2', role: 'superuser');
    expect(corrupted.permissions, isEmpty);
    final user = User(email: 'x@lab.test', role: 'superuser', status: 'active');
    expect(user.isReadOnly, isTrue);
    expect(user.canCreateInspection, isFalse);
  });
}
