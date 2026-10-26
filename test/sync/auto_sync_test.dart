import 'dart:async';

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
/// * two devices editing the SAME row preserve both versions until reviewed;
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
    when(
      () => connectivity.onStatusChange,
    ).thenAnswer((_) => const Stream<bool>.empty());
    final devices = DeviceRegistry(
      remote: remote,
      metadata: metadata,
      audit: audit,
      source: source,
    );
    return buildSyncEngine(
      timerInterval: timerInterval,
      heartbeatInterval: heartbeatInterval,
      mutationDelay: mutationDelay,
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
      deviceTagProvider: deviceTag == null ? null : () async => deviceTag!,
    ),
    guard: _LiveGuard(this),
    queue: queue,
    audit: audit,
  );

  Future<List<Map<String, Object?>>> rows() => fixture.db.query('inspections');

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
      expect(
        pushedB.conflicts,
        0,
        reason: 'no version race: different documents',
      );

      await laptop.puller(remote).runOnce();
      await phone.puller(remote).runOnce();

      for (final device in [laptop, phone]) {
        final rows = await device.rows();
        expect(rows.length, 2, reason: 'both inspections on both devices');
        final codes = {for (final r in rows) '${r['entry_code']}'};
        expect(codes, {codeA, codeB});
        expect(await device.queue.countPending(), 0);
        expect(
          await device.conflicts(),
          isEmpty,
          reason: 'nobody taps anything',
        );
      }
    },
  );

  test('competing edits are retained until an explicit resolution', () async {
    final created = await laptop.repo().create(payload(), user);
    final code = '${created['entry_code']}';
    await laptop.pusher(remote).runOnce();
    await phone.puller(remote).runOnce();

    // Device A edits and pushes first (remote v2).
    await laptop.repo().update(created['id'] as int, {
      ...payload(),
      'supplier': 'Supplier A edit',
    }, user);
    final pushedA = await laptop.pusher(remote).runOnce();
    expect(pushedA.conflicts, 0);

    // Device B edited from v1 without seeing v2: a version race that used
    // to park a manual conflict row.
    final phoneRow = (await phone.rows()).single;
    await phone.repo().update((phoneRow['id'] as num).toInt(), {
      ...payload(),
      'supplier': 'Supplier B edit',
    }, user);
    final pushedB = await phone.pusher(remote).runOnce();
    expect(pushedB.failed, 0);
    expect(pushedB.conflicts, 1);
    expect((await phone.rows()).single['supplier'], 'Supplier B edit');
    expect(
      remote.documents['$orgId/samples/$code']!['supplier'],
      'Supplier A edit',
    );
    await phone.puller(remote).runOnce();
    expect(
      (await phone.rows()).single['supplier'],
      'Supplier B edit',
      reason: 'pull cannot erase the parked local edit',
    );
    final conflict = (await phone.conflicts()).single;
    await ConflictResolver(queue: phone.queue, remote: remote).keepLocal(
      conflict['id'] as int,
      organizationId: orgId,
      session: _ConflictSession(phone.session),
    );
    await phone.pusher(remote).runOnce();

    // The user explicitly selected B; both devices now converge to it.
    await laptop.puller(remote).runOnce();
    await phone.puller(remote).runOnce();
    for (final device in [laptop, phone]) {
      final row = (await device.rows()).singleWhere(
        (r) => '${r['entry_code']}' == code,
      );
      expect(row['supplier'], 'Supplier B edit');
      expect((row['remote_version'] as num).toInt(), 3);
      expect(await device.conflicts(), isEmpty);
    }
  });

  test(
    'a local write pushes within seconds with nobody pressing sync',
    () async {
      final engine = laptop.engine(remote);
      addTearDown(engine.dispose);
      engine.start();

      await laptop.repo().create(payload(), user);

      // The 60-minute timer cannot be what moves this: only the debounced
      // post-mutation hook fires.
      await waitFor(
        () async =>
            remote.documents.keys.any((k) => k.startsWith('$orgId/samples/')),
      );
      await waitFor(() async => (await laptop.queue.countPending()) == 0);

      final key = remote.documents.keys.singleWhere(
        (k) => k.startsWith('$orgId/samples/'),
      );
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

  test(
    'an edit during a committed upload survives pull and the late receipt',
    () async {
      final delayed = _PausedRemote();
      final created = await laptop.repo().create(
        payload(supplier: 'first'),
        user,
      );
      final pusher = laptop.pusher(delayed);
      final uploading = pusher.runOnce();
      await delayed.committed.future;
      await laptop.repo().update(
        created['id'] as int,
        payload(supplier: 'latest'),
        user,
      );
      await laptop.puller(delayed).runOnce();
      expect((await laptop.rows()).single['supplier'], 'latest');
      delayed.release.complete();
      await uploading;
      final pending = (await laptop.queue.listQueue()).singleWhere(
        (r) => r['entity_type'] == 'sample',
      );
      expect(pending['status'], 'pending');
      expect(pending['base_version'], 1);
      expect((await laptop.rows()).single['sync_state'], 'queued');
      await pusher.runOnce();
      await phone.puller(delayed).runOnce();
      expect((await phone.rows()).single['supplier'], 'latest');
      expect((await phone.rows()).single['remote_version'], 2);
      expect(await laptop.conflicts(), isEmpty);
    },
  );

  test(
    'a delayed pull cannot write rows or cursors after an organization switch',
    () async {
      final created = await laptop.repo().create(payload(), user);
      await laptop.pusher(remote).runOnce();
      final delayed = _PausedPullRemote(remote);
      final pulling = phone.puller(delayed).runOnce();
      await delayed.fetched.future;
      phone.session = phone.session.copyWith(organizationId: 'org_other');
      await phone.fixture.helper.bindOrg('org_other');
      delayed.release.complete();
      await pulling;
      final otherDb = await phone.fixture.helper.database;
      expect(
        await otherDb.query('inspections'),
        isEmpty,
        reason: 'the old response must not enter the new organization file',
      );
      expect(await phone.metadata.cursor('sample'), const PullCursor('', ''));
      expect(created['id'], isNotNull);
      await phone.fixture.helper.close();
    },
  );

  test(
    'a queued batch cannot be redirected to a new organization mid-send',
    () async {
      final delayed = _PausedRemote();
      await laptop.repo().create(payload(supplier: 'one'), user);
      await laptop.repo().create(payload(supplier: 'two'), user);
      final pusher = PushWorker(
        queue: laptop.queue,
        metadata: laptop.metadata,
        remote: delayed,
        audit: laptop.audit,
        source: laptop.source,
        maxConcurrency: 1,
      );
      final sending = pusher.runOnce();
      await delayed.committed.future;
      laptop.session = laptop.session.copyWith(organizationId: 'org_other');
      await laptop.fixture.helper.bindOrg('org_other');
      delayed.release.complete();
      await sending;
      expect(
        delayed.documents.keys.any((k) => k.startsWith('org_other/')),
        isFalse,
      );
      expect(
        delayed.documents.keys.where((k) => k.startsWith('$orgId/samples/')),
        hasLength(1),
      );
      expect(
        await (await laptop.fixture.helper.database).query('sync_queue'),
        isEmpty,
      );
      await laptop.fixture.helper.close();
    },
  );

  test(
    'two engines sharing a file cannot recover each others live claims',
    () async {
      final delayed = _PausedRemote();
      await laptop.repo().create(payload(), user);
      final first = laptop.engine(delayed);
      final second = laptop.engine(delayed);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final running = first.syncNow();
      await delayed.committed.future;
      final before = (await laptop.queue.listQueue()).singleWhere(
        (r) => r['entity_type'] == 'sample',
      );
      await second.syncNow(pullOnly: true);
      final after = (await laptop.queue.listQueue()).singleWhere(
        (r) => r['entity_type'] == 'sample',
      );
      expect(after['status'], 'in_flight');
      expect(after['revision'], before['revision']);
      delayed.release.complete();
      await running;
      expect((await laptop.rows()).single['sync_state'], 'synced');
    },
  );

  test(
    'a failed heartbeat pull retries the same marker instead of consuming it',
    () async {
      final failing = _FailTwiceRemote();
      await laptop.repo().create(payload(), user);
      await laptop.pusher(failing).runOnce();
      final engine = phone.engine(
        failing,
        heartbeatInterval: const Duration(milliseconds: 80),
      );
      addTearDown(engine.dispose);
      engine.start();
      await waitFor(
        () async =>
            (await phone.rows()).isNotEmpty &&
            !engine.isSyncing &&
            (await phone.metadata.lastError()).isEmpty,
      );
      expect(failing.failures, 2);
      expect(
        await phone.metadata.lastError(),
        isEmpty,
        reason: 'a successful retry clears the old pull error',
      );
    },
  );

  test(
    'a pull-only debounce cannot replace an already scheduled push',
    () async {
      final engine = laptop.engine(
        remote,
        mutationDelay: const Duration(milliseconds: 120),
      );
      addTearDown(engine.dispose);
      engine.start();
      await waitFor(() async => !engine.isSyncing);
      await laptop.repo().create(payload(), user);
      engine.scheduleSync(pullOnly: true);
      await waitFor(
        () async =>
            remote.documents.keys.any((k) => k.startsWith('$orgId/samples/')),
      );
      expect(await laptop.conflicts(), isEmpty);
    },
  );

  test(
    'a cached session without remote authentication cannot report synced',
    () async {
      await laptop.metadata.markPush(DateTime(2026, 1, 1));
      await laptop.metadata.markPull(DateTime(2026, 1, 1));
      remote.signedIn = false;
      final engine = laptop.engine(remote);
      addTearDown(engine.dispose);
      final snapshot = await engine.syncNow();
      expect(snapshot.syncing, isFalse);
      expect(snapshot.fullySynced, isFalse);
      expect(snapshot.pullIncomplete, isTrue);
      expect(snapshot.lastError, contains('Authentication'));
    },
  );

  test(
    'pending writes retain their original account across sign-out and sign-in',
    () async {
      final original = laptop.session;
      await laptop.repo().create(payload(supplier: 'owner A'), user);
      // Simulate pre-upgrade rows without the owner column populated yet.
      await laptop.fixture.db.update('sync_queue', {'owner_uid': ''});
      laptop.session = phone.session;
      await laptop.pusher(remote).runOnce();
      expect(
        remote.documents.keys.where((k) => k.contains('/samples/')),
        isEmpty,
      );
      expect(
        (await laptop.queue.listQueue()).every(
          (r) => r['owner_uid'] == original.uid,
        ),
        isTrue,
      );
      await laptop.repo().create(payload(supplier: 'owner B'), user);
      await laptop.pusher(remote).runOnce();
      var samples = remote.documents.entries
          .where((e) => e.key.contains('/samples/'))
          .toList();
      expect(samples, hasLength(1));
      expect(samples.single.value['supplier'], 'owner B');
      expect(samples.single.value['updatedBy'], phone.session.uid);
      laptop.session = original;
      await laptop.pusher(remote).runOnce();
      samples = remote.documents.entries
          .where((e) => e.key.contains('/samples/'))
          .toList();
      expect(samples, hasLength(2));
      expect(
        samples
            .singleWhere((e) => e.value['supplier'] == 'owner A')
            .value['updatedBy'],
        original.uid,
      );
      expect(await laptop.queue.countPending(), 0);
    },
  );

  test('buildSyncEngine wires the enqueue-to-sync hook', () async {
    final engine = laptop.engine(remote);
    addTearDown(engine.dispose);
    expect(laptop.queue.onEnqueued, isNotNull);
    expect(engine.isSyncing, isFalse);
  });
}

class _ConflictSession implements AppSessionLike {
  _ConflictSession(this.session);
  final AppSession session;
  @override
  String get uid => session.uid;
  @override
  String get deviceId => session.deviceId;
}

class _PausedRemote extends InMemoryDataSource {
  _PausedRemote()
    : super(
        rolesByUid: const {
          'uid_dev_AAAAAA': 'admin',
          'uid_dev_BBBBBB': 'admin',
        },
      );
  final committed = Completer<void>();
  final release = Completer<void>();
  bool paused = false;
  @override
  Future<PushResult> setDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
    required Map<String, dynamic> data,
    required int baseVersion,
  }) async {
    final result = await super.setDocument(
      organizationId: organizationId,
      collection: collection,
      documentId: documentId,
      data: data,
      baseVersion: baseVersion,
    );
    if (collection == SyncCollection.samples && !paused) {
      paused = true;
      committed.complete();
      await release.future;
    }
    return result;
  }
}

class _PausedPullRemote extends InMemoryDataSource {
  _PausedPullRemote(InMemoryDataSource inner) {
    documents.addAll(inner.documents);
  }
  final fetched = Completer<void>();
  final release = Completer<void>();
  bool paused = false;
  @override
  Future<RemotePage> listSince({
    required String organizationId,
    required SyncCollection collection,
    String startAtTs = '',
    String startAtId = '',
    int limit = 300,
  }) async {
    final result = await super.listSince(
      organizationId: organizationId,
      collection: collection,
      startAtTs: startAtTs,
      startAtId: startAtId,
      limit: limit,
    );
    if (collection == SyncCollection.samples && !paused) {
      paused = true;
      fetched.complete();
      await release.future;
    }
    return result;
  }
}

class _FailTwiceRemote extends InMemoryDataSource {
  _FailTwiceRemote()
    : super(
        rolesByUid: const {
          'uid_dev_AAAAAA': 'admin',
          'uid_dev_BBBBBB': 'admin',
        },
      );
  int failures = 0;
  @override
  Future<RemotePage> listSince({
    required String organizationId,
    required SyncCollection collection,
    String startAtTs = '',
    String startAtId = '',
    int limit = 300,
  }) async {
    if (collection == SyncCollection.samples && failures < 2) {
      failures++;
      throw StateError('temporary network failure');
    }
    return super.listSince(
      organizationId: organizationId,
      collection: collection,
      startAtTs: startAtTs,
      startAtId: startAtId,
      limit: limit,
    );
  }
}
