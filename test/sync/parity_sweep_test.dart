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

import 'sync_test_fixture.dart';

class _MockConnectivity extends Mock implements ConnectivityService {}

/// The receiving-side parity sweep (plan §9.3-cross):
///
/// * a cursor preset past unseen documents (a poisoned cursor from an old
///   bug) is re-verified one entity per cycle until the whole scope has
///   been walked from the beginning;
/// * the sweep never runs while a pull error is live (churn guard);
/// * a "Pull skipped N documents" error arms the sweep without a restore;
/// * after the last entity the sweep stamps `last_full_sync_at`.
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
  late final _MockConnectivity connectivity = _MockConnectivity();

  PullWorker puller(InMemoryDataSource remote) => PullWorker(
    queue: queue,
    metadata: metadata,
    remote: remote,
    conflicts: ConflictResolver(queue: queue, remote: remote),
    source: SessionSource.empty(() => session),
  );

  SyncEngine engine(InMemoryDataSource remote) {
    when(() => connectivity.isOnline).thenReturn(online);
    when(
      () => connectivity.onStatusChange,
    ).thenAnswer((_) => const Stream<bool>.empty());
    final devices = DeviceRegistry(
      remote: remote,
      metadata: metadata,
      audit: audit,
      source: SessionSource.empty(() => session),
    );
    return buildSyncEngine(
      pushWorker: PushWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        audit: audit,
        source: SessionSource.empty(() => session),
      ),
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
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Device laptop;
  late InMemoryDataSource remote;

  AppSession sessionFor(String deviceId) => AppSession(
    uid: 'uid_$deviceId',
    email: '$deviceId@material-lab.test',
    organizationId: 'org_test',
    memberId: 'member_$deviceId',
    role: AppRoles.admin,
    status: 'active',
    deviceId: deviceId,
  );

  setUp(() async {
    final a = await openSyncFixture();
    await a.seedOrganization();
    laptop = _Device(a, sessionFor('dev_AAAAAA'));
    remote = InMemoryDataSource(rolesByUid: const {'uid_dev_AAAAAA': 'admin'});
  });

  tearDown(() async {
    await laptop.fixture.dispose();
  });

  /// Every entity's cursor parked far in the future: whatever writes exist
  /// on the server are behind the cursor and a normal pull never sees them.
  Future<void> poisonAllCursors() async {
    final entities = laptop.puller(remote).entities;
    for (final entity in entities) {
      await laptop.metadata.setCursor(
        entity.type,
        const PullCursor('2999-01-01T00:00:00Z', 'zz'),
      );
    }
    return;
  }

  test(
    'sweep re-walks one entity per cycle, then stamps last_full_sync_at',
    () async {
      final entities = laptop.puller(remote).entities;
      expect(entities.length, greaterThan(1));
      await poisonAllCursors();

      final engine = laptop.engine(remote);
      addTearDown(engine.dispose);
      await engine.markParityDue();

      // Each cycle clears exactly one cursor while the sweep is pending:
      // the sweep's index counter must advance by exactly one per cycle.
      for (var i = 0; i < entities.length; i++) {
        await engine.syncNow(pullOnly: true, reason: 'parity-test');
        final index = int.parse(
          (await laptop.metadata.readAll([
                SyncMetadata.parityIndexKey,
              ]))[SyncMetadata.parityIndexKey] ??
              '0',
        );
        expect(index, i + 1, reason: 'one entity swept per cycle (cycle $i)');
        if (i < entities.length - 1) {
          expect(
            (await laptop.metadata.readAll([
              SyncMetadata.parityPendingKey,
            ]))[SyncMetadata.parityPendingKey],
            '1',
          );
        }
      }

      // One extra cycle: completion is recognized at the START of the parity
      // pass following the last cleared entity.
      await engine.syncNow(pullOnly: true, reason: 'parity-finalize');
      final done = await laptop.metadata.readAll([
        SyncMetadata.parityPendingKey,
        SyncMetadata.lastFullSyncAtKey,
      ]);
      expect(done[SyncMetadata.parityPendingKey], '0');
      expect(done[SyncMetadata.lastFullSyncAtKey] ?? '', isNotEmpty);
      // The poisoned cursors are gone in the process.
      for (final entity in entities) {
        expect(
          await laptop.metadata.cursor(entity.type),
          const PullCursor('', ''),
          reason: '${entity.type} cursor re-verified',
        );
      }

      // Satisfied sweep does not run again: counters do not re-arm.
      await engine.syncNow(pullOnly: true, reason: 'parity-idle');
      final after = await laptop.metadata.readAll([
        SyncMetadata.parityIndexKey,
      ]);
      expect(after[SyncMetadata.parityIndexKey], '${entities.length}');
    },
  );

  test('a skipped-documents error arms the sweep without a restore', () async {
    final entities = laptop.puller(remote).entities;
    await poisonAllCursors();
    // The trigger the pull worker leaves behind when it must skip documents
    // it cannot apply (schema/FK): those rows sit behind the cursor forever.
    await laptop.metadata.markError('Pull skipped 2 documents');

    final engine = laptop.engine(remote);
    addTearDown(engine.dispose);

    // No explicit markParityDue: only the live error should arm the sweep.
    // In production a successful PUSH clears `last_error` (the push worker
    // does so on line ~192); here the store IS clean and empty, so once the
    // sweep is armed we simulate the error being resolved, exactly like a
    // push would, to let it churn through the scope. Bounded loop.
    var armed = false;
    for (var i = 0; i < entities.length + 4; i++) {
      await engine.syncNow(pullOnly: true, reason: 'parity-test');
      if ((await laptop.metadata.readAll([
            SyncMetadata.parityPendingKey,
          ]))[SyncMetadata.parityPendingKey] ==
          '1') {
        armed = true;
        await laptop.metadata.markError(null);
      }
      if ((await laptop.metadata.readAll([
            SyncMetadata.parityPendingKey,
            SyncMetadata.lastFullSyncAtKey,
          ]))[SyncMetadata.parityPendingKey] ==
          '0') {
        break;
      }
    }
    expect(
      armed,
      isTrue,
      reason: 'skipped-document errors must trigger a full re-verification',
    );
    expect(
      (await laptop.metadata.readAll([
        SyncMetadata.lastFullSyncAtKey,
      ]))[SyncMetadata.lastFullSyncAtKey],
      isNotEmpty,
    );
    for (final entity in entities) {
      expect(
        await laptop.metadata.cursor(entity.type),
        PullCursor('', ''),
        reason: 'every collection re-walked after the sweep',
      );
    }
  });

  test('sweep pauses while a pull error is live, resumes after', () async {
    await poisonAllCursors();
    final failing = _FailingPullRemote();
    final engine = laptop.engine(failing);
    addTearDown(engine.dispose);
    await engine.markParityDue();
    await laptop.metadata.markError('Pull skipped 1 document');

    await engine.syncNow(pullOnly: true, reason: 'parity-blocked');
    await laptop.metadata.markError(
      'Pull skipped 1 document',
    ); // keep the error live
    await engine.syncNow(pullOnly: true, reason: 'parity-blocked');
    await laptop.metadata.markError('Pull skipped 1 document');
    await engine.syncNow(pullOnly: true, reason: 'parity-blocked');
    final index = (await laptop.metadata.readAll([
      SyncMetadata.parityIndexKey,
    ]))[SyncMetadata.parityIndexKey];
    expect(
      index ?? '0',
      '0',
      reason: 'with live errors the sweep must not churn cursors',
    );

    // A real successful pull clears the error and resumes the sweep.
    failing.failing = false;
    await engine.syncNow(pullOnly: true, reason: 'parity-resume');
    final resumed = (await laptop.metadata.readAll([
      SyncMetadata.parityIndexKey,
    ]))[SyncMetadata.parityIndexKey];
    expect(resumed ?? '0', '1');
  });
}

class _FailingPullRemote extends InMemoryDataSource {
  bool failing = true;
  @override
  Future<RemotePage> listSince({
    required String organizationId,
    required SyncCollection collection,
    String startAtTs = '',
    String startAtId = '',
    int limit = 300,
  }) {
    if (failing) throw StateError('live pull failure');
    return super.listSince(
      organizationId: organizationId,
      collection: collection,
      startAtTs: startAtTs,
      startAtId: startAtId,
      limit: limit,
    );
  }
}
