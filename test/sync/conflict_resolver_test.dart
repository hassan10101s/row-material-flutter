import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_queue.dart';

import 'sync_test_fixture.dart';

/// `ConflictResolver` - the two manual choices of the Sync screen
/// (plan §9.6). Nothing is ever resolved silently.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fixture;
  late SyncQueue queue;
  late InMemoryDataSource remote;
  late ConflictResolver resolver;

  setUp(() async {
    fixture = await openSyncFixture();
    queue = SyncQueue(fixture.helper);
    remote = InMemoryDataSource();
    resolver = ConflictResolver(queue: queue, remote: remote);
    await fixture.seedOrganization();
  });

  tearDown(() async => fixture.dispose());

  /// A parked version conflict, as `markConflict` would have left it.
  Future<({int conflictId, int localId})> parkConflict({
    required String entryCode,
    required int remoteVersion,
    String decisionStatus = 'APPROVED',
  }) async {
    final localId = await fixture.db.insert(
      'inspections',
      sampleRow(entryCode: entryCode, decisionStatus: decisionStatus),
    );
    await fixture.transaction(
      (txn) => queue.enqueue(
        txn,
        entityType: 'sample',
        entityId: entryCode,
        localRef: localId,
        operation: 'update',
        payload: <String, dynamic>{
          'entryCode': entryCode,
          'localId': localId,
          'organizationId': orgId,
          'version': 2,
          'updatedBy': 'uid_admin',
          'deviceId': 'dev_1',
          'decisionStatus': decisionStatus,
        },
        baseVersion: 1,
      ),
    );
    remote.documents['$orgId/samples/$entryCode'] = <String, dynamic>{
      'entryCode': entryCode,
      'localId': localId,
      'organizationId': orgId,
      'version': remoteVersion,
      'updatedBy': 'uid_other',
      'deviceId': 'dev_2',
      'decisionStatus': 'PENDING',
      'updatedAt': '2026-09-05T10:00:00.000',
    };
    await queue.markConflict(
      (await queue.claim()).single,
      direction: 'push_rejected',
      remotePayload: jsonEncode(remote.documents['$orgId/samples/$entryCode']),
    );
    final conflict = (await queue.listConflicts()).firstWhere(
      (row) => row['entity_id'] == entryCode,
    );
    return (conflictId: (conflict['id'] as num).toInt(), localId: localId);
  }

  test('cleanup refuses an active read-only account', () async {
    final parked = await parkConflict(
      entryCode: 'CLEAN-READONLY',
      remoteVersion: 3,
    );
    final restricted = ConflictResolver(
      queue: queue,
      remote: remote,
      source: SessionSource(
        () => const AppSession(
          uid: 'uid_admin',
          organizationId: orgId,
          deviceId: 'dev_1',
          role: 'admin',
          status: 'active',
          readOnlyDevice: true,
        ),
      ),
    );
    await expectLater(
      restricted.cleanUpFromServer(
        [parked.conflictId],
        organizationId: orgId,
        session: _Session(),
      ),
      throwsStateError,
    );
    expect(await queue.listConflicts(), hasLength(1));
    expect(await queue.listQueue(), hasLength(1));
  });

  test(
    'cleanup uses server values, retains history and leaves unverifiable cases open',
    () async {
      final first = await parkConflict(entryCode: 'CLEAN-1', remoteVersion: 7);
      final second = await parkConflict(entryCode: 'CLEAN-2', remoteVersion: 3);
      remote.documents.remove('$orgId/samples/CLEAN-2');
      final failures = await resolver.cleanUpFromServer(
        [first.conflictId, second.conflictId],
        organizationId: orgId,
        session: _Session(),
      );
      expect(failures.keys, [second.conflictId]);
      final row = (await fixture.db.query(
        'inspections',
        where: 'id = ?',
        whereArgs: [first.localId],
      )).single;
      expect(row['decision_status'], 'PENDING');
      expect(row['remote_version'], 7);
      final remaining = await queue.listConflicts();
      expect(remaining.single['id'], second.conflictId);
      expect((await queue.listQueue()).single['entity_id'], 'CLEAN-2');
      final archived = (await fixture.db.query(
        'sync_conflicts',
        where: 'id = ?',
        whereArgs: [first.conflictId],
      )).single;
      expect(archived['resolution'], 'keep_remote');
      expect(archived['local_payload'], contains('APPROVED'));
      expect(remote.documents['$orgId/samples/CLEAN-1']!['version'], 7);
    },
  );

  test(
    'cleanup does not discard a newer edit staged after the selection',
    () async {
      final old = await parkConflict(entryCode: 'CLEAN-NEW', remoteVersion: 4);
      await fixture.transaction(
        (txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'CLEAN-NEW',
          localRef: old.localId,
          operation: 'update',
          payload: {'updatedBy': 'uid_admin', 'decisionStatus': 'REJECTED'},
          baseVersion: 4,
        ),
      );
      await resolver.cleanUpFromServer(
        [old.conflictId],
        organizationId: orgId,
        session: _Session(),
      );
      final pending = (await queue.listQueue()).single;
      expect(pending['status'], 'pending');
      expect(pending['payload'], contains('REJECTED'));
    },
  );

  test(
    'editing a parked record supersedes the old resolution without duplicate queue rows',
    () async {
      final parked = await parkConflict(entryCode: 'NEWER', remoteVersion: 4);
      await fixture.transaction(
        (txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'NEWER',
          localRef: parked.localId,
          operation: 'update',
          payload: const {'decisionStatus': 'NEWEST'},
          baseVersion: 1,
        ),
      );
      expect(await queue.listConflicts(), isEmpty);
      final rows = await queue.listQueue();
      expect(rows, hasLength(1));
      expect(rows.single['status'], 'pending');
      await resolver.keepRemote(
        parked.conflictId,
        organizationId: orgId,
        session: _Session(),
      );
      expect(
        '${(await queue.listQueue()).single['payload']}',
        contains('NEWEST'),
      );
    },
  );

  test(
    'keep_local re-pushes the local payload on top of the remote version',
    () async {
      final parked = await parkConflict(entryCode: 'C-1', remoteVersion: 4);

      await resolver.keepLocal(
        parked.conflictId,
        organizationId: orgId,
        session: _Session(),
      );

      final row = (await queue.listQueue()).firstWhere(
        (r) => r['entity_id'] == 'C-1',
      );
      expect(row['operation'], 'update');
      expect(row['status'], 'pending');
      expect(
        row['base_version'],
        4,
        reason: 'the remote version we push on top of',
      );
      expect(row['local_ref'], parked.localId);
      final payload = '${row['payload']}';
      expect(payload, contains('"version":5'));
      expect(payload, contains('"updatedBy":"uid_admin"'));
      expect(payload, contains('"decisionStatus":"APPROVED"'));

      final local = (await fixture.db.query(
        'inspections',
        where: 'id = ?',
        whereArgs: [parked.localId],
      )).single;
      expect(local['sync_state'], 'queued');
      expect(local['remote_version'], 4);
      expect(
        local['version'],
        5,
        reason: 'the local version must match what we push',
      );
    },
  );

  test(
    'keep_local on a tombstone re-queues a tombstone, not an update',
    () async {
      final localId = await fixture.db.insert(
        'inspections',
        sampleRow(entryCode: 'C-2'),
      );
      await fixture.transaction(
        (txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'C-2',
          localRef: localId,
          operation: 'tombstone',
          payload: <String, dynamic>{
            'entryCode': 'C-2',
            'localId': localId,
            'organizationId': orgId,
            'version': 3,
            'updatedBy': 'uid_admin',
            'deviceId': 'dev_1',
            'deletedAt': '2026-09-06T08:00:00.000',
          },
          baseVersion: 2,
        ),
      );
      remote.documents['$orgId/samples/C-2'] = <String, dynamic>{
        'entryCode': 'C-2',
        'localId': localId,
        'organizationId': orgId,
        'version': 6,
        'updatedBy': 'uid_other',
      };
      await queue.markConflict(
        (await queue.claim()).single,
        direction: 'push_rejected',
        remotePayload: jsonEncode(remote.documents['$orgId/samples/C-2']),
      );
      final conflictId = ((await queue.listConflicts()).single['id'] as num)
          .toInt();

      await resolver.keepLocal(
        conflictId,
        organizationId: orgId,
        session: _Session(),
      );

      final row = (await queue.listQueue()).firstWhere(
        (r) => r['entity_id'] == 'C-2',
      );
      expect(row['operation'], 'tombstone');
    },
  );

  test('keep_local closes the conflict, so it is not offered twice', () async {
    final parked = await parkConflict(entryCode: 'C-3', remoteVersion: 2);

    await resolver.keepLocal(
      parked.conflictId,
      organizationId: orgId,
      session: _Session(),
    );

    expect(await queue.listConflicts(), isEmpty);
    final resolved = (await fixture.db.query('sync_conflicts')).single;
    expect(resolved['resolution'], 'keep_local');
    expect(resolved['resolved_at'], isNotNull);
  });

  test(
    'keep_remote fetches the current version, not the stale conflict snapshot',
    () async {
      final parked = await parkConflict(entryCode: 'LATEST', remoteVersion: 3);
      remote.documents['$orgId/samples/LATEST']!['version'] = 7;
      remote.documents['$orgId/samples/LATEST']!['decisionStatus'] = 'REJECTED';
      await resolver.keepRemote(
        parked.conflictId,
        organizationId: orgId,
        session: _Session(),
      );
      final row = (await fixture.db.query(
        'inspections',
        where: 'id = ?',
        whereArgs: [parked.localId],
      )).single;
      expect(row['remote_version'], 7);
      expect(row['decision_status'], 'REJECTED');
    },
  );

  test('keep_remote replaces the local row with the remote document', () async {
    final parked = await parkConflict(entryCode: 'C-4', remoteVersion: 9);

    await resolver.keepRemote(
      parked.conflictId,
      organizationId: orgId,
      session: _Session(),
    );

    final local = (await fixture.db.query(
      'inspections',
      where: 'id = ?',
      whereArgs: [parked.localId],
    )).single;
    expect(local['decision_status'], 'PENDING', reason: 'the remote won');
    expect(local['version'], 9);
    expect(local['remote_version'], 9);
    expect(local['sync_state'], 'synced');
    expect(await queue.listQueue(), isEmpty, reason: 'nothing is left to push');
    expect(await queue.listConflicts(), isEmpty);
  });

  test('keep_remote keeps only the columns the local table has', () async {
    final parked = await parkConflict(entryCode: 'C-5', remoteVersion: 3);

    await resolver.keepRemote(
      parked.conflictId,
      organizationId: orgId,
      session: _Session(),
    );

    // `organizationId`/`deviceId` have no local column (D3): the update must
    // succeed instead of aborting the transaction.
    final columns = (await fixture.db.rawQuery(
      'PRAGMA table_info(inspections)',
    )).map((c) => '${c['name']}').toSet();
    expect(columns.contains('organization_id'), isFalse);
    final local = (await fixture.db.query(
      'inspections',
      where: 'id = ?',
      whereArgs: [parked.localId],
    )).single;
    expect(local['entry_code'], 'C-5');
  });

  test('an unknown conflict id is a no-op, not a crash', () async {
    await resolver.keepRemote(4242, organizationId: orgId, session: _Session());
    await resolver.keepLocal(4242, organizationId: orgId, session: _Session());
    expect(await queue.listConflicts(), isEmpty);
  });

  test('keep_remote maps foreign ids: natural key locate + FK-safe remap, '
      'never id = origin localId', () async {
    // Local row C-9 (id 1) + a decoy row: the remote document below was
    // written on another device, so its localId/materialId/createdBy are
    // meaningless here. The old code ran UPDATE ... WHERE id = localId with
    // raw ids: it either touched the decoy/nothing and closed the conflict
    // (silent loss), or died on FK (`created_by: local_9`).
    final localId = await fixture.db.insert(
      'inspections',
      sampleRow(entryCode: 'C-9', decisionStatus: 'APPROVED'),
    );
    final decoyId = await fixture.db.insert(
      'inspections',
      sampleRow(entryCode: 'DECOY', decisionStatus: 'APPROVED'),
    );
    await fixture.transaction(
      (txn) => queue.enqueue(
        txn,
        entityType: 'sample',
        entityId: 'C-9',
        localRef: localId,
        operation: 'update',
        payload: <String, dynamic>{
          'entryCode': 'C-9',
          'localId': localId,
          'organizationId': orgId,
          'version': 2,
          'updatedBy': 'uid_admin',
          'deviceId': 'dev_1',
          'decisionStatus': 'APPROVED',
        },
        baseVersion: 1,
      ),
    );
    final remoteDoc = <String, dynamic>{
      'entryCode': 'C-9',
      'localId': 9999,
      'materialId': 999,
      'materialCode': 'M-CEM-01',
      'materialName': 'Cement',
      'organizationId': orgId,
      'version': 9,
      'createdBy': 'local_9',
      'updatedBy': 'uid_other',
      'deviceId': 'dev_2',
      'decisionStatus': 'PENDING',
      'updatedAt': '2026-09-05T10:00:00.000',
    };
    remote.documents['$orgId/samples/C-9'] = remoteDoc;
    await queue.markConflict(
      (await queue.claim()).single,
      direction: 'push_rejected',
      remotePayload: jsonEncode(remoteDoc),
    );
    final conflictId = ((await queue.listConflicts()).single['id'] as num)
        .toInt();

    await resolver.keepRemote(
      conflictId,
      organizationId: orgId,
      session: _Session(),
    );

    final local = (await fixture.db.query(
      'inspections',
      where: 'id = ?',
      whereArgs: [localId],
    )).single;
    expect(local['decision_status'], 'PENDING', reason: 'remote won on C-9');
    expect(local['version'], 9);
    expect(local['sync_state'], 'synced');
    expect(
      local['created_by'],
      isA<int>(),
      reason: 'origin author placeholder must be remapped to a local id',
    );
    expect(
      local['material_id'],
      1,
      reason: 'material resolved by code to the local row',
    );
    final decoy = (await fixture.db.query(
      'inspections',
      where: 'id = ?',
      whereArgs: [decoyId],
    )).single;
    expect(
      decoy['decision_status'],
      'APPROVED',
      reason: 'unrelated local rows are never touched',
    );
    expect(await queue.listQueue(), isEmpty);
    expect(await queue.listConflicts(), isEmpty);
  });
}

/// Minimal session surface ConflictResolver needs.
class _Session implements AppSessionLike {
  @override
  String get uid => 'uid_admin';

  @override
  String get deviceId => 'dev_1';
}
