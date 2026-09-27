import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/conflict_resolver.dart';
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
    await fixture.transaction((txn) => queue.enqueue(
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
        ));
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
    await queue.markConflict((await queue.claim()).single,
        direction: 'push_rejected',
        remotePayload: jsonEncode(remote.documents['$orgId/samples/$entryCode']));
    final conflict = (await queue.listConflicts()).single;
    return (conflictId: (conflict['id'] as num).toInt(), localId: localId);
  }

  test('keep_local re-pushes the local payload on top of the remote version',
      () async {
    final parked = await parkConflict(entryCode: 'C-1', remoteVersion: 4);

    await resolver.keepLocal(parked.conflictId,
        organizationId: orgId, session: _Session());

    final row = (await queue.listQueue())
        .firstWhere((r) => r['entity_id'] == 'C-1');
    expect(row['operation'], 'update');
    expect(row['status'], 'pending');
    expect(row['base_version'], 4, reason: 'the remote version we push on top of');
    expect(row['local_ref'], parked.localId);
    final payload = '${row['payload']}';
    expect(payload, contains('"version":5'));
    expect(payload, contains('"updatedBy":"uid_admin"'));
    expect(payload, contains('"decisionStatus":"APPROVED"'));

    final local =
        (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [parked.localId])).single;
    expect(local['sync_state'], 'queued');
    expect(local['remote_version'], 4);
    expect(local['version'], 5, reason: 'the local version must match what we push');
  });

  test('keep_local on a tombstone re-queues a tombstone, not an update',
      () async {
    final localId = await fixture.db.insert('inspections', sampleRow(entryCode: 'C-2'));
    await fixture.transaction((txn) => queue.enqueue(
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
        ));
    remote.documents['$orgId/samples/C-2'] = <String, dynamic>{
      'entryCode': 'C-2',
      'localId': localId,
      'organizationId': orgId,
      'version': 6,
      'updatedBy': 'uid_other',
    };
    await queue.markConflict((await queue.claim()).single,
        direction: 'push_rejected',
        remotePayload: jsonEncode(remote.documents['$orgId/samples/C-2']));
    final conflictId =
        ((await queue.listConflicts()).single['id'] as num).toInt();

    await resolver.keepLocal(conflictId, organizationId: orgId, session: _Session());

    final row = (await queue.listQueue()).firstWhere((r) => r['entity_id'] == 'C-2');
    expect(row['operation'], 'tombstone');
  });

  test('keep_local closes the conflict, so it is not offered twice', () async {
    final parked = await parkConflict(entryCode: 'C-3', remoteVersion: 2);

    await resolver.keepLocal(parked.conflictId,
        organizationId: orgId, session: _Session());

    expect(await queue.listConflicts(), isEmpty);
    final resolved = (await fixture.db.query('sync_conflicts')).single;
    expect(resolved['resolution'], 'keep_local');
    expect(resolved['resolved_at'], isNotNull);
  });

  test('keep_remote replaces the local row with the remote document', () async {
    final parked = await parkConflict(entryCode: 'C-4', remoteVersion: 9);

    await resolver.keepRemote(parked.conflictId, organizationId: orgId);

    final local =
        (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [parked.localId])).single;
    expect(local['decision_status'], 'PENDING', reason: 'the remote won');
    expect(local['version'], 9);
    expect(local['remote_version'], 9);
    expect(local['sync_state'], 'synced');
    expect(await queue.listQueue(), isEmpty, reason: 'nothing is left to push');
    expect(await queue.listConflicts(), isEmpty);
  });

  test('keep_remote keeps only the columns the local table has', () async {
    final parked = await parkConflict(entryCode: 'C-5', remoteVersion: 3);

    await resolver.keepRemote(parked.conflictId, organizationId: orgId);

    // `organizationId`/`deviceId` have no local column (D3): the update must
    // succeed instead of aborting the transaction.
    final columns = (await fixture.db.rawQuery('PRAGMA table_info(inspections)'))
        .map((c) => '${c['name']}')
        .toSet();
    expect(columns.contains('organization_id'), isFalse);
    final local =
        (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [parked.localId])).single;
    expect(local['entry_code'], 'C-5');
  });

  test('an unknown conflict id is a no-op, not a crash', () async {
    await resolver.keepRemote(4242, organizationId: orgId);
    await resolver.keepLocal(4242, organizationId: orgId, session: _Session());
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