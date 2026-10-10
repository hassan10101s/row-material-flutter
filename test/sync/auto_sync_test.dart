import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/network/connectivity_service.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/audit_trail.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/device_registry.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_engine.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/inspections/data/offline_first_inspection_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

import 'sync_test_fixture.dart';

class _MockConnectivity extends Mock implements ConnectivityService {}

/// The automatic-sync contract, end to end on two devices sharing one
/// remote:
///
/// * two devices creating the SAME material on the SAME day offline mint
///   disjoint entry codes, so both pushes land — no collision, no tap;
/// * two devices editing the SAME row converge by themselves (newest wins),
///   audited, with zero manual conflict rows;
/// * a local write pushes within seconds with nobody pressing anything;
/// * a push on one device wakes the other through the heartbeat probe.
class _Device {
  _Device(this.fixture, this.session, {this.deviceTag});

  final SyncFixture fixture;
  AppSession session;
  final String? deviceTag;

  late final SyncQueue queue = SyncQueue(fixture.helper);
  late final SyncMetadata metadata = SyncMetadata(fixture.helper);
  late final AuditLogger audit = AuditLogger(
    queue: queue,
    session: () => session,
  );
  late bool online = true;
  late final _MockConnectivity connectivity = _MockConnectivity();

  SessionSource get source => SessionSource.empty(() => session);

  PushWorker pusher(InMemoryDataSource remote) => PushWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        audit: audit,
        source: source,
      );

  PullWorker puller(InMemoryDataSource remote) => PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: ConflictResolver(queue: queue, remote: remote),
        source: source,
      );

  SyncEngine engine(
    InMemoryDataSource remote, {
    Duration timerInterval = const Duration(hours: 1),
    Duration heartbeatInterval = const Duration(hours: 1),
    Duration mutationDelay = const Duration(milliseconds: 80),
  }) {
    // ignore: avoid_redundant_argument_values
    when(() => connectivity.isOnline).thenReturn(online);
    when(() => connectivity.onStatusChange)
        .thenAnswer((_) => const Stream<bool>.empty());
    final devices = DeviceRegistry(
      remote: remote,
      metadata: metadata,
      audit: audit,
      source: source,
    );
    return buildSyncEngine(
      pushWorker: pusher(remote),
      pullWorker: puller(remote),
      queue: queue,
      metadata: metadata,
      audit: audit,
      connectivity: connectivity,
      conflicts: ConflictResolver(queue: queue, remote: remote),
      remote: remote,
      trail: AuditTrail(audit: audit, metadata: metadata, devices: devices),
    );
  }

  OfflineFirstInspectionRepository repo() => OfflineFirstInspectionRepository(
        dbHelper: fixture.helper,
        referenceRepo: ReferenceRepo(
          dbHelper: fixture.helper,
          deviceTagProvider:
              deviceTag == null ? null : () async => deviceTag!,
        ),
        guard: _LiveGuard(this),
        queue: queue,
        audit: audit,
      );

  Future<List<Map<String, Object?>>> rows() =>
      fixture.db.query('inspections');

  Future<List<Map<String, Object?>>> conflicts() =>
      fixture.db.query('sync_conflicts', where: 'resolution IS NULL');
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
    return device.session.canDo(permission, online: device.online);
  }
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
    final a = await openSyncFixture();
    final b = await openSyncFixture();
    await a.seedOrganization();
    await b.seedOrganization();
    laptop = _Device(a, sessionFor('dev_AAAAAA'), deviceTag: 'DEVAAA');
    phone = _Device(b, sessionFor('dev_BBBBBB'), deviceTag: 'DEVBBB');
    remote = InMemoryDataSource(
      rolesByUid: const {'uid_dev_AAAAAA': 'admin', 'uid_dev_BBBBBB': 'admin'},
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

  const user = UserContext(id: 1, fullName: 'Ahmed Ali', role: 'admin');

  Future<void> waitFor(
    Future<bool> Function() condition, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(await condition(), isTrue, reason: 'timed out waiting');
  }

  test(
    'simultaneous offline creates on both devices both land, zero manual',
    () async {
      laptop.online = false;
      phone.online = false;
      remote.offline = true;

      final createdA = await laptop.repo().create(payload(), user);
      final createdB = await phone.repo().create(payload(), user);
      final codeA = '${createdA['entry_code']}';
      final codeB = '${createdB['entry_code']}';

      // Disjoint code spaces: the sync document id IS the entry code, so
      // sharing one would have meant overwrite-or-conflict.
      expect(codeA, isNot(codeB));
      expect(codeA, contains('DEVAAA'));
      expect(codeB, contains('DEVBBB'));

      laptop.online = true;
      phone.online = true;
      remote.offline = false;

      final pushedA = await laptop.pusher(remote).runOnce();
      expect(pushedA.failed, 0);
      expect(pushedA.conflicts, 0);
      final pushedB = await phone.pusher(remote).runOnce();
      expect(pushedB.failed, 0);
      expect(pushedB.conflicts, 0,
          reason: 'no version race: different documents');

      await laptop.puller(remote).runOnce();
      await phone.puller(remote).runOnce();

      for (final device in [laptop, phone]) {
        final rows = await device.rows();
        expect(rows.length, 2, reason: 'both inspections on both devices');
        final codes = {for (final r in rows) '${r['entry_code']}'};
        expect(codes, {codeA, codeB});
        expect(await device.queue.countPending(), 0);
        expect(await device.conflicts(), isEmpty,
            reason: 'nobody taps anything');
      }
    },
  );

  test(
    'concurrent edits to one row converge automatically, newest wins',
    () async {
      final created = await laptop.repo().create(payload(), user);
      final code = '${created['entry_code']}';
      await laptop.pusher(remote).runOnce();
      await phone.puller(remote).runOnce();

      // Device A edits and pushes first (remote v2).
      await laptop.repo().update(
        created['id'] as int,
        {...payload(), 'supplier': 'Supplier A edit'},
        user,
      );
      final pushedA = await laptop.pusher(remote).runOnce();
      expect(pushedA.conflicts, 0);

      // Device B edited from v1 without seeing v2: a version race that used
      // to park a manual conflict row.
      final phoneRow = (await phone.rows()).single;
      await phone.repo().update(
        (phoneRow['id'] as num).toInt(),
        {...payload(), 'supplier': 'Supplier B edit'},
        user,
      );
      final pushedB = await phone.pusher(remote).runOnce();
      expect(pushedB.failed, 0);
      expect(pushedB.conflicts, 0,
          reason: 'the race rebases itself, no tap');
      expect(pushedB.pushed, greaterThanOrEqualTo(1));

      // B edited strictly later, so B wins everywhere after one pull each.
      await laptop.puller(remote).runOnce();
      await phone.puller(remote).runOnce();
      for (final device in [laptop, phone]) {
        final row = (await device.rows())
            .singleWhere((r) => '${r['entry_code']}' == code);
        expect(row['supplier'], 'Supplier B edit');
        expect((row['remote_version'] as num).toInt(), 3);
        expect(await device.conflicts(), isEmpty);
      }
    },
  );

  test(
    'a local write pushes within seconds with nobody pressing sync',
    () async {
      final engine = laptop.engine(remote);
      addTearDown(engine.dispose);
      engine.start();

      await laptop.repo().create(payload(), user);

      // The 60-minute timer cannot be what moves this: only the debounced
      // post-mutation hook fires.
      await waitFor(() async =>
          remote.documents.keys.any((k) => k.startsWith('$orgId/samples/')));
      await waitFor(() async => (await laptop.queue.countPending()) == 0);

      final key = remote.documents.keys
          .singleWhere((k) => k.startsWith('$orgId/samples/'));
      expect((remote.documents[key]!['version'] as num).toInt(), 1);
      expect(await laptop.conflicts(), isEmpty);
    },
  );

  test(
    'one device pushing wakes the other through the heartbeat probe',
    () async {
      final engineA = laptop.engine(remote);
      final engineB = phone.engine(
        remote,
        heartbeatInterval: const Duration(milliseconds: 200),
      );
      addTearDown(engineA.dispose);
      addTearDown(engineB.dispose);
      engineB.start();

      // B is idle and sees nothing.
      expect(await phone.rows(), isEmpty);

      // A writes and pushes (bumping the heartbeat); B only watches.
      await laptop.repo().create(payload(), user);
      await engineA.syncNow(reason: 'test');

      await waitFor(() async => (await phone.rows()).isNotEmpty);
      final rows = await phone.rows();
      expect(rows.length, 1);
      expect(rows.single['supplier'], 'Cement Supplier Co');
      expect(rows.single['sync_state'], 'synced');
    },
  );

  test('buildSyncEngine wires the enqueue-to-sync hook', () async {
    final engine = laptop.engine(remote);
    addTearDown(engine.dispose);
    expect(laptop.queue.onEnqueued, isNotNull);
    expect(engine.isSyncing, isFalse);
  });
}
