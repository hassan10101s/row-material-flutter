import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/utils/app_dates.dart';

import 'sync_test_fixture.dart';

/// The audit outbox (plan §9.7): written in the caller's transaction, pushed as
/// an append-only `auditLogs` document, attributed to the live session, and
/// pruned only once the server confirmed it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fixture;
  late SyncQueue queue;
  late SyncMetadata metadata;
  late AuditLogger audit;
  late InMemoryDataSource remote;
  late AppSession session;

  setUp(() async {
    fixture = await openSyncFixture();
    queue = SyncQueue(fixture.helper);
    metadata = SyncMetadata(fixture.helper);
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
    // Production wiring: the logger reads the live session, nothing is
    // configured at startup.
    audit = AuditLogger(queue: queue, session: () => session);
  });

  tearDown(() async => fixture.dispose());

  PushWorker worker() => PushWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        audit: audit,
        source: SessionSource.empty(() => session),
      );

  test('log() attributes the entry to the live session and redacts secrets',
      () async {
    final id = await fixture.transaction((txn) => audit.log(
          txn,
          action: AuditAction.sampleCreated,
          entityType: 'sample',
          entityId: 'S-1',
          details: <String, dynamic>{'password': 'hunter2', 'quantity': '10'},
        ));

    final row = (await fixture.db.query('audit_logs', where: 'id = ?', whereArgs: [id])).single;
    expect(row['user_id'], 'uid_admin');
    expect(row['organization_id'], orgId);
    expect(row['device_id'], 'dev_1');
    expect(row['action'], AuditAction.sampleCreated);
    expect(row['sync_state'], 'queued');
    expect(row['details_json'], contains('"password":"***"'));
    expect(row['details_json'], isNot(contains('hunter2')));
    expect(row['details_json'], contains('"quantity":"10"'), reason: 'non-sensitive keys survive');
  });

  test('the entry is pushed as an append-only auditLogs document', () async {
    final id = await fixture.transaction((txn) => audit.log(
          txn,
          action: AuditAction.qcApproved,
          entityType: 'qualityCheck',
          entityId: 'qc_1_1',
        ));

    final report = await worker().runOnce();
    expect(report.pushed, 1);
    expect(report.failed, 0);

    // The heartbeat bump shares the remote with the audit document.
    final doc = remote.documents.values.singleWhere(
      (d) => '${d['action']}' == AuditAction.qcApproved,
    );
    expect(doc['action'], AuditAction.qcApproved);
    expect(doc['entityType'], 'qualityCheck');
    expect(doc['userId'], 'uid_admin');
    expect(doc['organizationId'], orgId);
    expect(doc['version'], 1);
    // `hasOnly` in `firestore.rules` rejects a create carrying anything else,
    // and a rejected audit push loses the trail of a write that really
    // happened - so the payload is exactly these ten fields. `localId` is
    // deliberately absent: it is the primary key of *this* device and would
    // point at an unrelated row on any other device.
    expect(doc.keys.toSet(), {
      'userId',
      'userName',
      'organizationId',
      'action',
      'entityType',
      'entityId',
      'detailsJson',
      'deviceId',
      'occurredAt',
      'version',
    });

    final row = (await fixture.db.query('audit_logs', where: 'id = ?', whereArgs: [id])).single;
    expect(row['sync_state'], 'synced', reason: 'markDone stamps the pushed row');
    expect(await queue.countPending(), 0);
  });

  test('prune keeps what the server has not confirmed yet', () async {
    Future<int> insert(String state, int daysAgo) => fixture.db.insert('audit_logs', {
          'user_id': 'uid_admin',
          'organization_id': orgId,
          'action': AuditAction.settingsUpdated,
          'entity_type': 'settings',
          'entity_id': 'org_test',
          'device_id': 'dev_1',
          'occurred_at': nowIsoAt(DateTime.now().subtract(Duration(days: daysAgo))),
          'version': 1,
          'sync_state': state,
        });

    await insert('synced', 200); // old + confirmed -> prunable
    await insert('synced', 2); // recent -> kept by the retention window
    await insert('queued', 200); // old but not confirmed -> must survive
    await insert('failed', 200); // old but blocked -> must survive

    await audit.prune(retention: const Duration(days: 90));

    final remaining = (await fixture.db.query('audit_logs', orderBy: 'id ASC')).map((r) => r['sync_state']).toList();
    expect(remaining, ['synced', 'queued', 'failed'],
        reason: 'only the old entry the server confirmed is dropped');
  });

  test('prune caps the table at maxRows, newest kept', () async {
    // Inserted oldest first, so the highest id is also the most recent.
    for (var daysAgo = 4; daysAgo >= 0; daysAgo--) {
      await fixture.db.insert('audit_logs', {
        'user_id': 'uid_admin',
        'organization_id': orgId,
        'action': AuditAction.deviceRegistered,
        'entity_type': 'device',
        'entity_id': 'dev_$daysAgo',
        'device_id': 'dev_1',
        'occurred_at': nowIsoAt(DateTime.now().subtract(Duration(days: daysAgo))),
        'version': 1,
        'sync_state': 'synced',
      });
    }
    await audit.prune(maxRows: 2);
    final rows = await fixture.db.query('audit_logs', orderBy: 'id DESC');
    expect(rows.length, 2);
    expect(rows.first['entity_id'], 'dev_0', reason: 'the newest rows are the ones kept');
  });
}
