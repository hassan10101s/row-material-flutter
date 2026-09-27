import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';

import 'sync_test_fixture.dart';

/// `PullWorker` against the in-memory remote (plan §14-P6.3).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fixture;
  late SyncQueue queue;
  late SyncMetadata metadata;
  late ConflictResolver conflicts;
  late InMemoryDataSource remote;
  late AppSession session;

  setUp(() async {
    fixture = await openSyncFixture();
    queue = SyncQueue(fixture.helper);
    metadata = SyncMetadata(fixture.helper);
    remote = InMemoryDataSource();
    conflicts = ConflictResolver(queue: queue, remote: remote);
    session = const AppSession(
      uid: 'uid_admin',
      email: 'admin@material-lab.test',
      organizationId: orgId,
      memberId: 'member_1',
      role: 'admin',
      status: 'active',
      deviceId: 'dev_1',
    );
    await fixture.seedOrganization();
  });

  tearDown(() async => fixture.dispose());

  PullWorker worker({int pageSize = 300}) => PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: conflicts,
        source: SessionSource.empty(() => session),
        pageSize: pageSize,
      );

  /// A remote sample document, shaped exactly like `buildRemotePayload` output.
  Map<String, dynamic> remoteSample(
    String entryCode, {
    int version = 1,
    int? localId,
    String updatedAt = '2026-09-02T10:00:00.000',
    String decisionStatus = 'PENDING',
    String? deletedAt,
  }) =>
      <String, dynamic>{
        'entryCode': entryCode,
        'localId': localId,
        'organizationId': orgId,
        'materialId': 1,
        'materialName': 'Cement',
        'materialCode': 'M-CEM-01',
        'inspectionDate': '2026-09-01',
        'specialistName': 'Ahmed Ali',
        'physicalResultsJson': '{}',
        'chemicalResultsJson': '{}',
        'physicalReferenceJson': '{}',
        'chemicalReferenceJson': '{}',
        'sampleNamesJson': '[]',
        'snapshotJson': '{}',
        'decisionStatus': decisionStatus,
        'createdBy': 'uid_admin',
        'createdByName': 'Ahmed Ali',
        'version': version,
        'updatedBy': 'uid_admin',
        'deviceId': 'dev_2',
        'updatedAt': updatedAt,
        'createdAt': '2026-09-01T08:00:00.000',
        'deletedAt': deletedAt,
        'payloadBytes': 120,
      };

  test('a signed-out or unbound session pulls nothing', () async {
    remote.documents['$orgId/samples/R-1'] = remoteSample('R-1');
    remote.signedIn = false;
    expect((await worker().runOnce()).applied, 0);

    remote.signedIn = true;
    session = const AppSession(uid: 'uid_admin', status: 'active');
    expect((await worker().runOnce()).applied, 0);
    expect(await fixture.db.query('inspections'), isEmpty);
  });

  test('a document from another device is inserted locally as synced', () async {
    remote.documents['$orgId/samples/R-2'] = remoteSample('R-2', version: 3);

    final report = await worker().runOnce();

    expect(report.applied, 1);
    final rows = await fixture.db.query('inspections', where: 'entry_code = ?', whereArgs: ['R-2']);
    expect(rows, hasLength(1));
    expect(rows.single['decision_status'], 'PENDING');
    expect(rows.single['version'], 3);
    expect(rows.single['remote_version'], 3);
    expect(rows.single['sync_state'], 'synced');
    expect(rows.single['remote_synced_at'], isNotNull);
    expect(await metadata.lastPullAt(), isNotNull);
  });

  test('a newer remote version overwrites a clean local row', () async {
    final localId = await fixture.db.insert('inspections', sampleRow(entryCode: 'R-3'));
    await fixture.db.update(
      'inspections',
      {'remote_version': 1, 'version': 1, 'sync_state': 'synced'},
      where: 'id = ?',
      whereArgs: [localId],
    );
    remote.documents['$orgId/samples/R-3'] =
        remoteSample('R-3', version: 4, localId: localId, decisionStatus: 'APPROVED');

    final report = await worker().runOnce();

    expect(report.applied, 1);
    final row =
        (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [localId])).single;
    expect(row['decision_status'], 'APPROVED');
    expect(row['version'], 4);
    expect(row['remote_version'], 4);
    expect(row['sync_state'], 'synced');
  });

  test('the same version is skipped, so a no-op cycle changes nothing', () async {
    final localId = await fixture.db.insert('inspections', sampleRow(entryCode: 'R-4'));
    await fixture.db.update(
      'inspections',
      {'remote_version': 5, 'version': 5, 'sync_state': 'synced'},
      where: 'id = ?',
      whereArgs: [localId],
    );
    remote.documents['$orgId/samples/R-4'] = remoteSample('R-4', version: 5, localId: localId);

    final report = await worker().runOnce();

    expect(report.skipped, 1);
    expect(report.applied, 0);
    final row =
        (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [localId])).single;
    expect(row['sync_state'], 'synced');
  });

  test('an unsynced local edit wins over an older remote version', () async {
    final localId = await fixture.db.insert('inspections', sampleRow(entryCode: 'R-5'));
    await fixture.db.update(
      'inspections',
      {
        'remote_version': 2,
        'version': 4,
        'sync_state': 'queued',
        'decision_status': 'APPROVED',
      },
      where: 'id = ?',
      whereArgs: [localId],
    );
    remote.documents['$orgId/samples/R-5'] =
        remoteSample('R-5', version: 3, localId: localId, decisionStatus: 'PENDING');

    final report = await worker().runOnce();

    expect(report.pushedBack, 1);
    expect(report.applied, 0);
    final row =
        (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [localId])).single;
    expect(row['decision_status'], 'APPROVED', reason: 'the local edit is not lost');
    expect(row['sync_state'], 'queued');
    final queued = await queue.listQueue();
    expect(queued.any((r) => r['entity_id'] == 'R-5' && r['operation'] == 'update'), isTrue,
        reason: 'the local edit goes back to the queue on top of the remote');
  });

  test('a remote tombstone marks the local row deleted instead of dropping it',
      () async {
    final localId = await fixture.db.insert('inspections', sampleRow(entryCode: 'R-6'));
    await fixture.db.update(
      'inspections',
      {'remote_version': 1, 'version': 1, 'sync_state': 'synced'},
      where: 'id = ?',
      whereArgs: [localId],
    );
    remote.documents['$orgId/samples/R-6'] = remoteSample(
      'R-6',
      version: 2,
      localId: localId,
      deletedAt: '2026-09-03T09:00:00.000',
    );

    final report = await worker().runOnce();

    expect(report.applied, 1);
    final row =
        (await fixture.db.query('inspections', where: 'id = ?', whereArgs: [localId])).single;
    expect(row['deleted_at'], '2026-09-03T09:00:00.000');
    expect(row['entry_code'], 'R-6', reason: 'the row must stay for the audit trail');
  });

  test('a natural-key match applies a document that has no localId', () async {
    final localId = await fixture.db.insert('inspections', sampleRow(entryCode: 'R-7'));
    await fixture.db.update(
      'inspections',
      {'remote_version': 1, 'version': 1, 'sync_state': 'synced'},
      where: 'id = ?',
      whereArgs: [localId],
    );
    remote.documents['$orgId/samples/R-7'] =
        remoteSample('R-7', version: 2, decisionStatus: 'REJECTED');

    final report = await worker().runOnce();

    expect(report.applied, 1);
    final rows = await fixture.db.query('inspections', where: 'entry_code = ?', whereArgs: ['R-7']);
    expect(rows, hasLength(1), reason: 'no duplicate row may appear');
    expect(rows.single['decision_status'], 'REJECTED');
  });

  test('the cursor makes the next cycle incremental, not a full re-read',
      () async {
    remote.documents['$orgId/samples/R-8'] = remoteSample('R-8', version: 1);
    remote.documents['$orgId/samples/R-9'] = remoteSample(
      'R-9',
      version: 1,
      updatedAt: '2026-09-02T11:00:00.000',
    );

    expect((await worker().runOnce()).applied, 2);
    expect((await metadata.cursor('sample')).timestamp, '2026-09-02T11:00:00.000');

    // A third document that appeared after the cursor is picked up; the two
    // already applied are not re-applied.
    remote.documents['$orgId/samples/R-10'] = remoteSample(
      'R-10',
      version: 1,
      updatedAt: '2026-09-02T12:00:00.000',
    );
    final second = await worker().runOnce();

    expect(second.applied, 1);
    expect(second.skipped, 0);
    expect(await fixture.db.query('inspections'), hasLength(3));
  });

  test('paging walks the whole collection and reports hasMore', () async {
    for (var i = 0; i < 7; i++) {
      remote.documents['$orgId/samples/R-$i'] = remoteSample(
        'R-$i',
        version: 1,
        updatedAt: '2026-09-02T10:0$i:00.000',
      );
    }

    final report = await worker(pageSize: 2).runOnce();

    expect(report.applied, 7);
    expect(await fixture.db.query('inspections'), hasLength(7));
  });

  test('a remote failure is reported and recorded, and nothing is applied',
      () async {
    remote.documents['$orgId/samples/R-11'] = remoteSample('R-11', version: 1);

    final report = await PullWorker(
      queue: queue,
      metadata: metadata,
      remote: _ExplodingRemote(),
      conflicts: conflicts,
      source: SessionSource.empty(() => session),
    ).runOnce();

    expect(report.error, contains('boom'));
    expect(report.applied, 0);
    expect(await metadata.lastError(), contains('boom'));
    expect(await fixture.db.query('inspections'), isEmpty);
  });

  test('a pull never clobbers another organization', () async {
    remote.documents['org_other/samples/R-12'] = remoteSample('R-12', version: 1);

    await worker().runOnce();

    expect(await fixture.db.query('inspections'), isEmpty,
        reason: 'only the bound organization is pulled');
  });
}

/// A remote whose reads always fail, to cover the error path of a cycle.
class _ExplodingRemote implements RemoteDataSource {
  @override
  bool get isConfigured => true;

  @override
  bool get isSignedIn => true;

  @override
  Future<bool> isFresh() async => true;

  @override
  Future<RemotePage> listSince({
    required String organizationId,
    required SyncCollection collection,
    String startAtTs = '',
    String startAtId = '',
    int limit = 300,
  }) async =>
      throw StateError('boom');

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
