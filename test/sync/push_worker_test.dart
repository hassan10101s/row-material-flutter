import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';

import 'sync_test_fixture.dart';

/// `PushWorker` against the in-memory remote (plan §14-P6.3).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fixture;
  late SyncQueue queue;
  late SyncMetadata metadata;
  late AuditLogger audit;
  late InMemoryDataSource remote;
  late AppSession session;
  late SessionSource source;

  AppSession sessionFor({String role = 'admin', String organizationId = orgId}) => AppSession(
        uid: 'uid_admin',
        email: 'admin@material-lab.test',
        organizationId: organizationId,
        memberId: 'member_1',
        role: role,
        status: 'active',
        deviceId: 'dev_1',
      );

  setUp(() async {
    fixture = await openSyncFixture();
    queue = SyncQueue(fixture.helper);
    metadata = SyncMetadata(fixture.helper);
    audit = AuditLogger(queue: queue);
    remote = InMemoryDataSource(rolesByUid: const {'uid_admin': 'admin'});
    session = sessionFor();
    source = SessionSource.empty(() => session);
    await fixture.seedOrganization();
  });

  tearDown(() async => fixture.dispose());

  PushWorker worker() => PushWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        audit: audit,
        source: source,
      );

  /// Creates the local row and enqueues its first push.
  Future<int> createLocalSample(String entryCode) async {
    final id = await fixture.db.insert('inspections', sampleRow(entryCode: entryCode));
    await fixture.transaction((txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: entryCode,
          localRef: id,
          operation: 'create',
          payload: <String, dynamic>{
            'entryCode': entryCode,
            'organizationId': orgId,
            'version': 1,
            'updatedBy': 'uid_admin',
            'decisionStatus': 'PENDING',
          },
        ));
    return id;
  }

  /// Edits the local row in place and re-enqueues (one queue row per entity).
  Future<int> editLocalSample(
    String entryCode, {
    String operation = 'update',
    required int baseVersion,
    Map<String, dynamic>? payload,
  }) async {
    final localId = (await fixture.db.query('inspections',
            where: 'entry_code = ?', whereArgs: [entryCode], limit: 1))
        .single['id'] as int;
    await fixture.db.update(
      'inspections',
      {'decision_status': 'APPROVED', 'decision_version': baseVersion + 1},
      where: 'id = ?',
      whereArgs: [localId],
    );
    await fixture.transaction((txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: entryCode,
          localRef: localId,
          operation: operation,
          payload: payload ??
              <String, dynamic>{
                'entryCode': entryCode,
                'organizationId': orgId,
                'version': baseVersion + 1,
                'updatedBy': 'uid_admin',
                'decisionStatus': 'APPROVED',
              },
          baseVersion: baseVersion,
        ));
    return localId;
  }

  String docKey(String entryCode) => '$orgId/samples/$entryCode';

  /// The queue also carries the audit outbox rows, so a lookup by entity is
  /// the only safe way to inspect one entry.
  Future<Map<String, Object?>> queueRow(String entityType, String entityId) async {
    final rows = (await queue.listQueue(limit: 500))
        .where((r) => r['entity_type'] == entityType && r['entity_id'] == entityId);
    if (rows.isEmpty) fail('no $entityType/$entityId row in sync_queue');
    return rows.first;
  }

  test('a signed-out session pushes nothing and leaves the row queued', () async {
    await createLocalSample('P-1');
    remote.signedIn = false;

    final report = await worker().runOnce();

    expect(report.pushed, 0);
    expect(report.retried, 0);
    expect(remote.documents, isEmpty);
    expect((await queueRow('sample', 'P-1'))['status'], 'pending',
        reason: 'the row must survive for later');
  });

  test('an unbound session (no organizationId) retries, it is never dropped',
      () async {
    await createLocalSample('P-2');
    session = sessionFor(organizationId: '');
    source = SessionSource.empty(() => session);

    final report = await worker().runOnce();

    expect(report.retried, 1);
    expect((await queueRow('sample', 'P-2'))['status'], 'pending');
    expect('${(await queueRow('sample', 'P-2'))['last_error']}', contains('organization'));
  });

  test('a transient network failure retries with a backoff, never fails',
      () async {
    await createLocalSample('P-3');
    final flaky = _FlakyRemote(inner: remote, failing: true);
    final workerWithFlakyRemote = PushWorker(
      queue: queue,
      metadata: metadata,
      remote: flaky,
      audit: audit,
      source: source,
    );

    final report = await workerWithFlakyRemote.runOnce();

    expect(report.retried, 1);
    expect(report.pushed, 0);
    final row = await queueRow('sample', 'P-3');
    expect(row['status'], 'pending');
    expect(row['retry_count'], 1);
    expect(row['next_attempt_at'], isNotNull, reason: 'backoff armed');
    expect(await metadata.lastError(), contains('network down'));
  });

  test('a create reaches the org collection and marks the local row synced',
      () async {
    final localId = await createLocalSample('P-4');

    final report = await worker().runOnce();

    expect(report.pushed, 1);
    expect(report.conflicts, 0);
    final doc = remote.documents[docKey('P-4')]!;
    expect(doc['version'], 1);
    expect(doc['entryCode'], 'P-4');
    expect(doc['organizationId'], orgId);

    expect(await queue.listQueue(), isEmpty);
    final local =
        (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [localId])).single;
    expect(local['remote_version'], 1);
    expect(local['sync_state'], 'synced');
    expect(await metadata.lastPushAt(), isNotNull);
    expect(await metadata.lastError(), isEmpty);
  });

  test('an update with a stale baseVersion becomes a conflict, not a clobber',
      () async {
    await createLocalSample('P-5');
    await worker().runOnce(); // the remote sample is now at version 1
    final localId = await editLocalSample('P-5', baseVersion: 0);

    final report = await worker().runOnce();

    expect(report.conflicts, 1);
    expect(report.pushed, 0);
    final row = await queueRow('sample', 'P-5');
    expect(row['status'], 'conflict');
    expect('${row['last_error']}', contains('Version conflict'));
    final parked = (await queue.listConflicts()).single;
    expect(parked['direction'], 'push_rejected');
    expect('${parked['remote_payload']}', contains('"version":1'),
        reason: 'the parked remote payload is the document we lost to');
    final local =
        (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [localId])).single;
    expect(local['sync_state'], 'conflict');
    // The remote document is untouched - no last-writer-wins clobber.
    expect(remote.documents[docKey('P-5')]!['version'], 1);
    // And the conflict is auditable.
    final conflicts = await fixture.db
        .query('audit_logs', where: 'action = ?', whereArgs: [AuditAction.syncConflict]);
    expect(conflicts, isNotEmpty);
  });

  test('an update with the right baseVersion bumps the remote version', () async {
    await createLocalSample('P-6');
    await worker().runOnce();

    await editLocalSample('P-6', baseVersion: 1);
    final report = await worker().runOnce();

    expect(report.pushed, 1);
    expect(remote.documents[docKey('P-6')]!['version'], 2);
    expect(remote.documents[docKey('P-6')]!['decisionStatus'], 'APPROVED');
  });

  test('a tombstone replicates as deletedAt, never as a hard delete', () async {
    final localId = await createLocalSample('P-7');
    await worker().runOnce();
    expect(remote.documents[docKey('P-7')], isNotNull);

    await fixture.transaction((txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'P-7',
          localRef: localId,
          operation: 'tombstone',
          payload: const {},
          baseVersion: 1,
        ));
    final report = await worker().runOnce();

    expect(report.pushed, 1);
    final doc = remote.documents[docKey('P-7')]!;
    expect(doc['deletedAt'], isNotNull);
    expect(await queue.listQueue(), isEmpty);
  });

  test('a viewer is blocked locally, before any network call', () async {
    session = sessionFor(role: 'viewer');
    source = SessionSource.empty(() => session);
    await createLocalSample('P-8');

    final report = await worker().runOnce();

    expect(report.conflicts, 1);
    expect(remote.documents, isEmpty, reason: 'no round-trip may be spent');
    final row = await queueRow('sample', 'P-8');
    expect('${row['last_error']}', contains('samples.update'));
    final denied = await fixture.db
        .query('audit_logs', where: 'action = ?', whereArgs: [AuditAction.deniedEntry]);
    expect(denied, isNotEmpty, reason: 'a denied push is audited');
  });

  test('an append-only entity cannot be overwritten by a duplicate id', () async {
    final inspectionId = await fixture.db.insert('inspections', sampleRow(entryCode: 'P-9'));
    final historyId = await fixture.db.insert(
      'inspection_status_history',
      historyRow(inspectionId: inspectionId, newStatus: 'APPROVED', version: 1),
    );
    final docId = 'qc_${inspectionId}_1';
    await fixture.transaction((txn) => queue.enqueue(
          txn,
          entityType: 'qualityCheck',
          entityId: docId,
          localRef: historyId,
          operation: 'create',
          payload: {'newStatus': 'APPROVED', 'version': 1},
        ));

    expect((await worker().runOnce()).pushed, 1);
    expect(remote.documents['$orgId/qualityChecks/$docId'], isNotNull);

    // A second push of the same id (a re-run) must not overwrite the record.
    await fixture.transaction((txn) => queue.enqueue(
          txn,
          entityType: 'qualityCheck',
          entityId: docId,
          localRef: historyId,
          operation: 'create',
          payload: {'newStatus': 'REJECTED', 'version': 1},
        ));
    final second = await worker().runOnce();

    expect(second.conflicts, 1);
    expect(remote.documents['$orgId/qualityChecks/$docId']!['newStatus'], 'APPROVED');
  });

  test('an oversized payload parks the row instead of retrying forever', () async {
    final localId = await createLocalSample('P-10');
    await fixture.transaction((txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'P-10',
          localRef: localId,
          operation: 'update',
          payload: {'blob': 'y' * (InMemoryDataSource.maxPayloadBytes + 10)},
          baseVersion: 0,
        ));

    final report = await worker().runOnce();

    expect(report.conflicts, 1);
    final row = await queueRow('sample', 'P-10');
    expect(row['status'], 'conflict');
    expect('${row['last_error']}', contains('too large'));
  });

  test('an unknown entity type is parked as a conflict, not dropped', () async {
    await fixture.transaction((txn) => queue.enqueue(
          txn,
          entityType: 'mystery',
          entityId: 'x-1',
          operation: 'create',
          payload: const {},
        ));

    final report = await worker().runOnce();

    expect(report.conflicts, 1);
    expect('${(await queueRow('mystery', 'x-1'))['last_error']}', contains('mystery'));
    expect((await queue.listConflicts()).single['entity_type'], 'mystery');
  });

  test('a batch continues past a failing entry and reports honest totals',
      () async {
    await createLocalSample('P-11');
    await createLocalSample('P-12');
    // The remote already moved past P-12 (another device wrote it), so the
    // local create can no longer win.
    remote.documents[docKey('P-12')] = <String, dynamic>{'version': 7, 'entryCode': 'P-12'};

    final report = await worker().runOnce();

    expect(report.pushed, 1);
    expect(report.conflicts, 1);
    expect(remote.documents[docKey('P-11')]!['version'], 1);
    expect(remote.documents[docKey('P-12')]!['version'], 7, reason: 'not clobbered');
    expect((await queueRow('sample', 'P-12'))['status'], 'conflict');
    // One entry reached the server, so the cycle is not an error state; the
    // per-entry error still has to be visible on its own row.
    expect(await metadata.lastError(), isEmpty);
  });
}

/// Wraps the in-memory remote so every write fails the way a dropped
/// connection does: the session stays valid, only the call fails.
///
/// (`InMemoryDataSource.offline` also clears `isSignedIn`, which makes
/// `runOnce` return before it ever claims the queue - a different path.)
class _FlakyRemote implements RemoteDataSource {
  _FlakyRemote({required this.inner, this.failing = false});

  final InMemoryDataSource inner;
  final bool failing;

  Map<String, Map<String, dynamic>> get documents => inner.documents;

  @override
  bool get isConfigured => inner.isConfigured;

  @override
  bool get isSignedIn => inner.isSignedIn;

  @override
  Future<bool> isFresh() => inner.isFresh();

  @override
  Future<PushResult> setDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
    required Map<String, dynamic> data,
    required int baseVersion,
  }) async =>
      failing
          ? const PushResult.retryable('network down')
          : inner.setDocument(
              organizationId: organizationId,
              collection: collection,
              documentId: documentId,
              data: data,
              baseVersion: baseVersion,
            );

  @override
  Future<PushResult> appendDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
    required Map<String, dynamic> data,
  }) async =>
      failing
          ? const PushResult.retryable('network down')
          : inner.appendDocument(
              organizationId: organizationId,
              collection: collection,
              documentId: documentId,
              data: data,
            );

  @override
  Future<void> deleteTombstone({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
  }) async {
    if (failing) throw StateError('network down');
    return inner.deleteTombstone(
      organizationId: organizationId,
      collection: collection,
      documentId: documentId,
    );
  }

  @override
  Future<RemoteDocument> getDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
  }) =>
      inner.getDocument(
        organizationId: organizationId,
        collection: collection,
        documentId: documentId,
      );

  @override
  Future<RemotePage> listSince({
    required String organizationId,
    required SyncCollection collection,
    String startAtTs = '',
    String startAtId = '',
    int limit = 300,
  }) =>
      inner.listSince(
        organizationId: organizationId,
        collection: collection,
        startAtTs: startAtTs,
        startAtId: startAtId,
        limit: limit,
      );

  @override
  Future<RemoteDocument> readHeartbeat(String organizationId) =>
      inner.readHeartbeat(organizationId);

  @override
  Future<void> registerDevice({
    required String organizationId,
    required String deviceId,
    required Map<String, dynamic> data,
  }) =>
      inner.registerDevice(
        organizationId: organizationId,
        deviceId: deviceId,
        data: data,
      );

  @override
  Future<void> unregisterDevice({
    required String organizationId,
    required String deviceId,
  }) =>
      inner.unregisterDevice(organizationId: organizationId, deviceId: deviceId);

  @override
  Future<List<RemoteDocument>> listDevices(String organizationId) =>
      inner.listDevices(organizationId);
}
