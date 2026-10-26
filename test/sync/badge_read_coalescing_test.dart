import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/network/connectivity_service.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'sync_test_fixture.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/sync_engine.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/sync/presentation/sync_status_controller.dart';

class _MockQueue extends Mock implements SyncQueue {}

class _MockMetadata extends Mock implements SyncMetadata {}

class _MockPush extends Mock implements PushWorker {}

class _MockPull extends Mock implements PullWorker {}

class _MockAudit extends Mock implements AuditLogger {}

class _MockConnectivity extends Mock implements ConnectivityService {}

/// The stall this guards against: the badge fires from the engine timer, the
/// shell controller timer and the dashboard load — often at the same instant
/// (startup) — and every unshared read is another pair of round trips
/// queueing on the one connection lock behind real work. Overlapping reads
/// must collapse into one instead of piling on.
void main() {
  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue(() {});
  });

  group('SyncStatusController.refresh', () {
    late _MockQueue queue;
    late _MockMetadata metadata;
    late Completer<Map<String, String>> gate;

    setUp(() {
      queue = _MockQueue();
      metadata = _MockMetadata();
      gate = Completer<Map<String, String>>();
      when(() => queue.countBadge()).thenAnswer(
        (_) async =>
            const SyncQueueCounts(pending: 1, blocked: 0, conflicts: 0),
      );
      when(() => metadata.readAll(any())).thenAnswer((_) => gate.future);
    });

    test('overlapping refreshes share one underlying read pair', () async {
      final c = SyncStatusController(
        queue: queue,
        metadata: metadata,
        isOnline: () => true,
        refreshInterval: const Duration(days: 1),
      );
      addTearDown(c.dispose);

      final first = c.refresh();
      // The second refresh lands while the first still parks on the lock:
      // it must skip instead of queueing a duplicate pair behind it.
      final second = c.refresh();
      gate.complete(const {});
      await first;
      await second;

      verify(() => metadata.readAll(any())).called(1);
      verify(() => queue.countBadge()).called(1);
      expect(c.status.pending, 1);
    });
  });

  group('SyncEngine status reads', () {
    late SyncFixture fixture;
    tearDown(() async => fixture.dispose());
    late _MockQueue queue;
    late _MockMetadata metadata;
    late _MockPush push;
    late _MockPull pull;
    late _MockAudit audit;
    late _MockConnectivity connectivity;
    late Completer<Map<String, String>> gate;

    setUp(() async {
      fixture = await openSyncFixture();
      queue = _MockQueue();
      metadata = _MockMetadata();
      push = _MockPush();
      pull = _MockPull();
      audit = _MockAudit();
      connectivity = _MockConnectivity();
      gate = Completer<Map<String, String>>();
      when(() => queue.dbHelper).thenReturn(fixture.helper);
      when(() => push.source).thenReturn(SessionSource.empty());
      when(() => push.remote).thenReturn(InMemoryDataSource());
      when(() => metadata.bind(fixture.db)).thenReturn(metadata);
      when(() => connectivity.isOnline).thenReturn(true);
      when(() => push.runOnce()).thenAnswer((_) async => PushReport.empty);
      when(() => pull.runOnce()).thenAnswer((_) async => PullReport.empty);
      when(
        () => queue.recoverStalled(checkCurrent: any(named: 'checkCurrent')),
      ).thenAnswer((_) async => 0);
      when(
        () => queue.recoverEnvelopeUpgrade(
          checkCurrent: any(named: 'checkCurrent'),
        ),
      ).thenAnswer((_) async => 0);
      when(() => metadata.markError(any())).thenAnswer((_) async {});
      when(() => queue.countBadge()).thenAnswer(
        (_) async =>
            const SyncQueueCounts(pending: 0, blocked: 0, conflicts: 0),
      );
      when(() => metadata.readAll(any())).thenAnswer((_) => gate.future);
    });

    SyncEngine engine() => SyncEngine(
      pushWorker: push,
      pullWorker: pull,
      queue: queue,
      metadata: metadata,
      audit: audit,
      connectivity: connectivity,
    );

    test('concurrent cycles share one status read', () async {
      final e = engine();
      addTearDown(e.dispose);

      final first = e.syncNow(reason: 'test');
      // Let the first cycle park on the gated read, then start the second:
      // while both wait, no second underlying read may start.
      await Future<void>.delayed(Duration.zero);
      final second = e.syncNow(reason: 'test');
      await Future<void>.delayed(Duration.zero);
      verify(() => metadata.readAll(any())).called(1);

      gate.complete(const {});
      await first;
      await second;
    });
  });
}
