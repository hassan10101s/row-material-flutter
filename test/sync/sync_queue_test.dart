import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/sync_queue.dart';

import 'sync_test_fixture.dart';

/// `sync_queue` row operations (plan §14-P6.2) against a real SQLite file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncFixture fixture;
  late SyncQueue queue;

  setUp(() async {
    fixture = await openSyncFixture();
    queue = SyncQueue(fixture.helper);
  });

  tearDown(() async => fixture.dispose());

  Future<int> insertSample(String entryCode) async {
    await fixture.seedOrganization();
    return fixture.db.insert('inspections', sampleRow(entryCode: entryCode));
  }

  group('enqueue', () {
    test('an offline create produces one pending row', () async {
      final id = await insertSample('QC-1');

      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-1',
            localRef: id,
            operation: 'create',
            payload: const {'entryCode': 'QC-1'},
          ));

      expect(await queue.countPending(), 1);
      final rows = await queue.listQueue();
      expect(rows.single['status'], 'pending');
      expect(rows.single['operation'], 'create');
      expect(rows.single['local_ref'], id);
    });

    test('consecutive offline edits collapse into a single row', () async {
      final id = await insertSample('QC-2');

      for (var i = 0; i < 3; i++) {
        await fixture.transaction((txn) => queue.enqueue(
              txn,
              entityType: 'sample',
              entityId: 'QC-2',
              localRef: id,
              operation: 'update',
              payload: {'attempt': i},
              baseVersion: 0,
            ));
      }

      final rows = await queue.listQueue();
      expect(rows, hasLength(1), reason: 'one row per entity (partial index)');
      expect(rows.single['operation'], 'update');
      expect('${rows.single['payload']}', contains('"attempt":2'));
    });

    test('a tombstone wins over a pending create and over an update', () async {
      final id = await insertSample('QC-3');

      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-3',
            localRef: id,
            operation: 'create',
            payload: const {},
          ));
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-3',
            localRef: id,
            operation: 'tombstone',
            payload: const {},
          ));
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-3',
            localRef: id,
            operation: 'update',
            payload: const {},
          ));

      final rows = await queue.listQueue();
      expect(rows, hasLength(1));
      expect(rows.single['operation'], 'tombstone');
    });

    test('a fresh edit clears the backoff and the error', () async {
      final id = await insertSample('QC-4');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-4',
            localRef: id,
            operation: 'create',
            payload: const {},
          ));
      final claimed = (await queue.claim()).single;
      await queue.markRetry(claimed, 'offline');

      var row = (await queue.listQueue()).single;
      expect(row['status'], 'pending');
      expect(row['retry_count'], 1);
      expect(row['last_error'], 'offline');
      expect(row['next_attempt_at'], isNotNull, reason: 'backoff is armed');

      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-4',
            localRef: id,
            operation: 'update',
            payload: const {},
          ));

      row = (await queue.listQueue()).single;
      expect(row['retry_count'], 0);
      expect(row['last_error'], isNull);
      expect(row['next_attempt_at'], isNull);
    });
  });

  group('claim', () {
    test('claims each row once and marks it in_flight', () async {
      final id = await insertSample('QC-5');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-5',
            localRef: id,
            operation: 'create',
            payload: const {},
          ));

      final first = await queue.claim();
      expect(first, hasLength(1));
      expect(first.single.status, 'pending');

      final second = await queue.claim();
      expect(second, isEmpty, reason: 'single-flight: no double claim');
      expect((await queue.listQueue()).single['status'], 'in_flight');
    });

    test('a row still inside its backoff window is not claimed', () async {
      final id = await insertSample('QC-6');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-6',
            localRef: id,
            operation: 'create',
            payload: const {},
          ));
      await queue.markRetry((await queue.claim()).single, 'offline');

      expect(await queue.claim(), isEmpty);
    });
  });

  group('markDone', () {
    test('deletes the row and marks the local row synced', () async {
      final id = await insertSample('QC-7');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-7',
            localRef: id,
            operation: 'create',
            payload: const {},
          ));

      await queue.markDone((await queue.claim()).single, remoteVersion: 4);

      expect(await queue.listQueue(), isEmpty);
      final row = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
      expect(row['remote_version'], 4);
      expect(row['sync_state'], 'synced');
      expect(row['remote_synced_at'], isNotNull);
    });
  });

  group('markRetry', () {
    test('grows exponentially inside the ±20% jitter band and caps at 15min',
        () {
      // 5s * 2^n with a deterministic ±20% jitter, hard-capped at 900s.
      for (var attempt = 0; attempt < 8; attempt++) {
        final base = 5 * (1 << attempt);
        final delay = SyncQueue.backoffDelay(attempt).inSeconds;
        expect(delay, inInclusiveRange((base * 0.8).floor(), (base * 1.2).ceil()),
            reason: 'attempt $attempt must stay within the jitter band');
      }
      // From attempt 8 on, 5s * 2^n is above the cap, so the wait stays in
      // [12min, 18min] - the jitter pattern repeats with `attempt % 5`.
      for (final attempt in [8, 10, 20, 40]) {
        final delay = SyncQueue.backoffDelay(attempt).inSeconds;
        expect(delay, inInclusiveRange(720, 1080), reason: 'attempt $attempt');
      }
      // Strictly increasing until the cap, so a retry storm cannot tighten.
      var previous = 0;
      for (var attempt = 0; attempt < 8; attempt++) {
        final delay = SyncQueue.backoffDelay(attempt).inSeconds;
        expect(delay, greaterThan(previous));
        previous = delay;
      }
    });

    test('after maxRetries the row is failed, not retried forever', () async {
      final id = await insertSample('QC-8');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-8',
            localRef: id,
            operation: 'create',
            payload: const {},
          ));

      QueueEntry entry = (await queue.claim()).single;
      for (var i = 0; i < SyncQueue.maxRetries; i++) {
        await queue.markRetry(entry, 'offline $i');
        // Clear the backoff so the next claim picks the row up again.
        await fixture.db.update(
          'sync_queue',
          {'next_attempt_at': null},
          where: 'id = ?',
          whereArgs: [entry.id],
        );
        final claimed = await queue.claim();
        if (claimed.isEmpty) break;
        entry = claimed.single;
      }

      final row = (await queue.listQueue()).single;
      expect(row['status'], 'failed');
      expect(row['retry_count'], SyncQueue.maxRetries);
      expect(await queue.countBlocked(), greaterThanOrEqualTo(1));
      final local = (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [id])).single;
      expect(local['sync_state'], 'conflict');
    });
  });

  group('conflicts', () {
    test('a conflict parks the row and records both payloads', () async {
      final id = await insertSample('QC-9');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-9',
            localRef: id,
            operation: 'update',
            payload: const {'decisionStatus': 'APPROVED'},
            baseVersion: 3,
          ));

      await queue.markConflict(
        (await queue.claim()).single,
        direction: 'push',
        remotePayload: '{"version":5}',
        error: 'version conflict',
      );

      final row = (await queue.listQueue()).single;
      expect(row['status'], 'conflict');
      final conflicts = await queue.listConflicts();
      expect(conflicts, hasLength(1));
      expect(conflicts.single['entity_type'], 'sample');
      expect(conflicts.single['entity_id'], 'QC-9');
      expect(conflicts.single['direction'], 'push');
      expect('${conflicts.single['remote_payload']}', contains('5'));
    });

    test('dismissAllConflicts ignores stale rows and clears the badge', () async {
      for (final code in ['QC-D1', 'QC-D2']) {
        final id = await insertSample(code);
        await fixture.transaction((txn) => queue.enqueue(
              txn,
              entityType: 'sample',
              entityId: code,
              localRef: id,
              operation: 'update',
              payload: const {},
            ));
      }
      for (final entry in await queue.claim(limit: 10)) {
        await queue.markConflict(entry, direction: 'push_rejected');
      }
      expect(await queue.listConflicts(), hasLength(2));
      expect((await queue.countBadge()).conflicts, 2);

      expect(await queue.dismissAllConflicts(), 2);

      expect(await queue.listConflicts(), isEmpty);
      expect(await queue.countConflicts(), 0);
      expect((await queue.countBadge()).conflicts, 0);
      // Parked rows are dropped, history is kept as ignored.
      expect(
        await queue.listQueue(),
        isEmpty,
        reason: 'stale parked payloads must not linger',
      );
      final history = await fixture.db
          .query('sync_conflicts', where: 'resolution = ?', whereArgs: ['ignored']);
      expect(history, hasLength(2));
      expect(history.every((r) => r['resolved_at'] != null), isTrue);
    });

    test('dismissAllConflicts is a no-op when nothing is unresolved', () async {
      expect(await queue.dismissAllConflicts(), 0);
      expect((await queue.countBadge()).conflicts, 0);
    });

    test('resolveConflict applies the choice and closes the conflict', () async {
      final id = await insertSample('QC-10');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-10',
            localRef: id,
            operation: 'update',
            payload: const {},
          ));
      await queue.markConflict(
        (await queue.claim()).single,
        direction: 'push',
        remotePayload: '{"decisionStatus":"REJECTED"}',
      );
      final conflict = (await queue.listConflicts()).single;
      var keptLocal = false;

      await queue.resolveConflict(
        (conflict['id'] as num).toInt(),
        resolution: 'keep_local',
        onKeepLocal: (row) async => keptLocal = '${row['entity_id']}' == 'QC-10',
        onKeepRemote: (_, _) async => fail('keep_remote must not run'),
      );

      expect(keptLocal, isTrue);
      expect(await queue.listConflicts(), isEmpty, reason: 'no longer unresolved');
      final resolved =
          (await fixture.db.query('sync_conflicts', where: 'resolution IS NOT NULL')).single;
      expect(resolved['resolution'], 'keep_local');
      expect(resolved['resolved_at'], isNotNull);
    });

    test('countBadge matches the individual counts, including resolved ones',
        () async {
      // The badge collapsed three queries into one statement, which means the
      // "unresolved" predicate is now spelled a second time in SQL instead of
      // reusing `listConflicts`. It has to agree with the stored resolution
      // values - `keep_local`/`keep_remote`, not `local`/`remote` - or a settled
      // conflict stays on the badge forever.
      final id = await insertSample('QC-BADGE');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-BADGE',
            localRef: id,
            operation: 'update',
            payload: const {},
          ));
      await queue.markConflict(
        (await queue.claim()).single,
        direction: 'push',
        remotePayload: '{"decisionStatus":"REJECTED"}',
      );
      expect((await queue.listConflicts()), hasLength(1));
      expect(await queue.countConflicts(), 1);
      expect(
        (await queue.countBadge()).conflicts,
        1,
        reason: 'an unresolved conflict must be counted',
      );

      await queue.resolveConflict(
        (await queue.listConflicts()).single['id'] as int,
        resolution: 'keep_remote',
        onKeepLocal: (_) async => fail('keep_local must not run'),
        onKeepRemote: (_, _) async {},
      );
      expect(await queue.listConflicts(), isEmpty);
      expect(
        await queue.countConflicts(),
        0,
        reason: 'a resolved conflict must not stay on the badge',
      );
      expect((await queue.countBadge()).conflicts, 0);
    });

    test('countBadge agrees with countPending and countBlocked', () async {
      for (final code in ['QC-A', 'QC-B', 'QC-C']) {
        final id = await insertSample(code);
        await fixture.transaction((txn) => queue.enqueue(
              txn,
              entityType: 'sample',
              entityId: code,
              localRef: id,
              operation: 'update',
              payload: const {},
            ));
      }
      // One pending, one claimed (in_flight), one failed.
      expect((await queue.claim(limit: 1)), hasLength(1));
      final remaining = await queue.listQueue();
      final failed = remaining.firstWhere((r) => r['status'] == 'pending');
      await queue.markRetry(
        QueueEntry.fromRow(failed),
        'boom',
      );
      await queue.markRetry(
        QueueEntry.fromRow(
          (await queue.listQueue())
              .firstWhere((r) => r['id'] != failed['id'] && r['status'] == 'pending'),
        ),
        'boom',
      );

      final badge = await queue.countBadge();
      expect(badge.pending, await queue.countPending());
      expect(badge.blocked, await queue.countBlocked());
      expect(badge.conflicts, await queue.countConflicts());
    });

    test('resolveConflict rejects an unknown resolution', () async {
      final id = await insertSample('QC-10b');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-10b',
            localRef: id,
            operation: 'update',
            payload: const {},
          ));
      await queue.markConflict((await queue.claim()).single, direction: 'pull');
      final conflict = (await queue.listConflicts()).single;

      await expectLater(
        queue.resolveConflict(
          (conflict['id'] as num).toInt(),
          resolution: 'whatever',
          onKeepLocal: (_) async {},
        ),
        throwsArgumentError,
      );
    });

    test('retryBlocked puts a failed row back into the queue', () async {
      final id = await insertSample('QC-11');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-11',
            localRef: id,
            operation: 'create',
            payload: const {},
          ));
      var entry = (await queue.claim()).single;
      for (var i = 0; i < SyncQueue.maxRetries; i++) {
        await queue.markRetry(entry, 'nope');
        await fixture.db.update(
          'sync_queue',
          {'next_attempt_at': null},
          where: 'id = ?',
          whereArgs: [entry.id],
        );
        final claimed = await queue.claim();
        if (claimed.isEmpty) break;
        entry = claimed.single;
      }
      expect((await queue.listQueue()).single['status'], 'failed');

      expect(await queue.retryBlocked(), 1);
      final row = (await queue.listQueue()).single;
      expect(row['status'], 'pending');
      expect(row['retry_count'], 0);
    });
  });

  group('recoverStalled', () {
    test('a row stranded in_flight by a crash returns to pending', () async {
      // The regression this guards: `claim()` sets in_flight, and if the process
      // dies before `markDone`/`markRetry` the row was never claimable again.
      // The user's edits were stranded until they reinstalled the app.
      final id = await insertSample('QC-STALL');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-STALL',
            localRef: id,
            operation: 'update',
            payload: const {'decisionStatus': 'APPROVED'},
            baseVersion: 2,
          ));
      final claimed = await queue.claim();
      expect(claimed, hasLength(1));
      expect((await queue.listQueue()).single['status'], 'in_flight');
      expect(await queue.claim(), isEmpty, reason: 'single-flight still holds');

      expect(await queue.recoverStalled(), 1);

      final row = (await queue.listQueue()).single;
      expect(row['status'], 'pending');
      expect(row['last_error'], 'interrupted mid-push');
      expect(row['retry_count'], 0, reason: 'a crash is not a failed attempt');
      expect(row['next_attempt_at'], isNotNull, reason: 'backoff is re-armed');
    });

    test('a recovered row is claimable again and still carries its payload',
        () async {
      final id = await insertSample('QC-STALL2');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-STALL2',
            localRef: id,
            operation: 'update',
            payload: const {'decisionStatus': 'REJECTED'},
            baseVersion: 7,
          ));
      await queue.claim();
      await queue.recoverStalled();

      // Backoff is armed, so clear it the way a real sync cycle would.
      await fixture.db.update(
        'sync_queue',
        {'next_attempt_at': null},
        where: "status = 'pending'",
      );
      final reclaimed = await queue.claim();
      expect(reclaimed, hasLength(1));
      expect(reclaimed.single.payload['decisionStatus'], 'REJECTED');
      expect(reclaimed.single.baseVersion, 7);
    });

    test('a stranded row that had exhausted its retries fails instead of looping',
        () async {
      final id = await insertSample('QC-STALL3');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-STALL3',
            localRef: id,
            operation: 'create',
            payload: const {},
          ));
      await queue.claim();
      // Simulate the row already having burned its budget before it stranded.
      await fixture.db.update(
        'sync_queue',
        {'retry_count': SyncQueue.maxRetries - 1},
        where: '1 = 1',
      );

      expect(await queue.recoverStalled(), 1);

      final row = (await queue.listQueue()).single;
      expect(row['status'], 'failed');
      expect(row['next_attempt_at'], isNull, reason: 'a failed row waits for retry');
      expect(row['last_error'], contains('retry limit'));
      expect(await queue.countBlocked(), 1, reason: 'surfaces on the sync badge');
    });

    test('recovery leaves pending, failed and conflict rows alone', () async {
      final id = await insertSample('QC-STALL4');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-STALL4',
            localRef: id,
            operation: 'create',
            payload: const {},
          ));
      final pendingBefore = (await queue.listQueue()).single;

      // Nothing is in_flight: recovery must be a no-op, not a requeue of work.
      expect(await queue.recoverStalled(), 0);
      final pendingAfter = (await queue.listQueue()).single;
      expect(pendingAfter['status'], 'pending');
      expect(pendingAfter['last_error'], pendingBefore['last_error']);
      expect(pendingAfter['next_attempt_at'], pendingBefore['next_attempt_at']);
      expect(pendingAfter['updated_at'], pendingBefore['updated_at']);
    });

    test('recovery is idempotent: a second pass finds nothing left to fix',
        () async {
      final id = await insertSample('QC-STALL5');
      await fixture.transaction((txn) => queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'QC-STALL5',
            localRef: id,
            operation: 'update',
            payload: const {},
          ));
      await queue.claim();

      expect(await queue.recoverStalled(), 1);
      // Must not touch the row again - `syncNow()` calls this on every run.
      expect(await queue.recoverStalled(), 0);
    });
  });

  test('purgeSolved drops rows whose local row disappeared, keeps tombstones',
      () async {
    final goneId = await insertSample('QC-12');
    final tombstoneId = await insertSample('QC-13');
    await fixture.transaction((txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'QC-12',
          localRef: goneId,
          operation: 'create',
          payload: const {},
        ));
    await fixture.transaction((txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'QC-13',
          localRef: tombstoneId,
          operation: 'tombstone',
          payload: const {},
        ));

    // A restore that did not contain the first row: its queue row is dead.
    await fixture.db.delete('inspections', where: 'id = ?', whereArgs: [goneId]);
    await fixture.db.delete('inspections', where: 'id = ?', whereArgs: [tombstoneId]);

    final purged = await queue.purgeSolved();
    expect(purged, 1, reason: 'the tombstone has to reach the server');
    final left = await queue.listQueue();
    expect(left, hasLength(1));
    expect(left.single['operation'], 'tombstone');
  });
}
