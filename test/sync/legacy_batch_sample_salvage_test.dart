import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';

import 'sync_test_fixture.dart';

/// Salvage path for legacy `product_batch_samples` documents pushed before
/// the `batch_remote_id` stamping existed (the remote document carries no
/// `batchRemoteId`). Before the fix these produced the endless
/// "transient: product batch sample without parent identity" pull skips on
/// every cycle.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fx;
  late AppSession session;
  late InMemoryDataSource remote;
  late PullWorker worker;

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();
    session = const AppSession(
      uid: 'uid_admin',
      email: 'admin@material-lab.test',
      organizationId: orgId,
      memberId: 'member_1',
      role: 'admin',
      status: 'active',
      deviceId: 'dev_LOCAL',
    );
    remote = InMemoryDataSource(rolesByUid: const {'uid_admin': 'admin'});
    worker = PullWorker(
      queue: SyncQueue(fx.helper),
      metadata: SyncMetadata(fx.helper),
      remote: remote,
      conflicts: ConflictResolver(
        queue: SyncQueue(fx.helper),
        remote: remote,
      ),
      source: SessionSource.empty(() => session),
    );
  });

  tearDown(() async => fx.dispose());

  /// A legacy sample payload shaped exactly like `buildRemotePayload`
  /// produced it — minus `batchRemoteId`, which pre-stamping rows lacked.
  /// [docId] mirrors the `remoteIdDocId` fallback the origin device used.
  Map<String, dynamic> legacySampleDoc(int batchId, String docId) {
    final entity = syncEntities.firstWhere((e) => e.type == 'productBatchSample');
    return buildRemotePayload(
      entity,
      {
        'id': 9,
        'batch_id': batchId,
        'sample_no': 1,
        'sample_name': 'Batch A',
        'sample_taker': '',
        'physical_results_json': '{}',
        'chemical_results_json': '[]',
        'tested_by': null,
        'tested_by_name': 'Ahmed Ali',
        'tested_at': '2026-01-01 08:00:00',
        'decision_status': '',
        'decision_reason': null,
        'created_at': '2026-01-01 07:00:00',
        'updated_at': null,
        'remote_id': docId,
        'device_id': 'dev_OLD',
      },
      const SyncPayloadContext(
        organizationId: orgId,
        uid: 'uid_admin',
        deviceId: 'dev_OLD',
        version: 1,
        versionField: 'version',
      ),
      asCreate: true,
    )..remove('batchRemoteId');
  }

  /// Seeds a local product-batch header (a `product`-kind inspection).
  Future<int> seedBatchHeader(String remoteId) async {
    final id = await fx.db.rawInsert(
      "INSERT INTO inspections (entry_code, material_id, material_name, "
      "material_code, inspection_date, specialist_name, physical_results_json, "
      "chemical_results_json, physical_reference_json, chemical_reference_json, "
      "decision_status, snapshot_json, sample_names_json, decision_version, "
      "created_by, created_by_name, created_at, updated_at, inspection_kind, "
      "remote_id) "
      "VALUES ('BATCH-1', 1, 'Cement', 'M-CEM-01', '2026-09-01', "
      "'Ahmed Ali', '{}', '{}', '{}', '{}', 'PENDING', '{}', '[]', 1, 1, "
      "'Ahmed Ali', '2026-09-01T08:00:00.000', '2026-09-01T08:00:00.000', "
      "'product', ?)",
      [remoteId],
    );
    return id;
  }

  test('a foreign legacy sample heals through the origin device\'s backfilled '
      'legacy inspection name', () async {
    // The parent header on this device, carrying the remote_id the origin
    // device's open-time backfill wrote for its legacy rows.
    final headerId = await seedBatchHeader('legacy_inspections_4');

    remote.documents['$orgId/productBatchSamples/legacy_4'] =
        legacySampleDoc(4, 'legacy_4');

    final report = await worker.runOnce();
    expect(report.failed, 0,
        reason: 'the legacy sample must resolve, not skip as transient');

    final rows = await fx.db.query('product_batch_samples');
    expect(rows, hasLength(1));
    final applied = rows.single;
    // The parent pointer was remapped to THIS device's header id, and the
    // parent identity is stamped so the next push carries full identity.
    expect((applied['batch_id'] as num).toInt(), headerId);
    expect(applied['batch_remote_id'], 'legacy_inspections_4');
    expect(applied['remote_id'], 'legacy_4');

    // And the healed row persists: a later run does not fail again.
    final second = await worker.runOnce();
    expect(second.failed, 0);
  });

  test('salvaged legacy samples release the cursor so newer samples behind '
      'them land too', () async {
    // The viewer's real failure shape: the legacy sample sits early in the
    // document stream, so before the salvage its refusal kept the
    // productBatchSamples cursor pinned at the stream start — every document
    // beyond the first page was never downloaded and newer samples of other
    // batches silently stopped syncing ("العينات لم تظهر على الموبايل").
    // A tight page size reproduces the pin inside a single cycle.
    await seedBatchHeader('legacy_inspections_4');

    Map<String, dynamic> modernDoc(int no, String updatedAt) {
      final entity = syncEntities.firstWhere(
        (e) => e.type == 'productBatchSample',
      );
      final payload = buildRemotePayload(
        entity,
        {
          'id': 40 + no,
          'batch_id': 4,
          'batch_remote_id': 'legacy_inspections_4',
          'sample_no': no,
          'sample_name': 'Modern $no',
          'sample_taker': '',
          'physical_results_json': '{}',
          'chemical_results_json': '[]',
          'tested_by': null,
          'tested_by_name': 'Ahmed Ali',
          'tested_at': '2026-02-01 08:00:00',
          'decision_status': '',
          'decision_reason': null,
          'created_at': '2026-02-01 07:00:00',
          'updated_at': null,
          'remote_id': 'legacy_$no',
          'device_id': 'dev_OLD',
        },
        const SyncPayloadContext(
          organizationId: orgId,
          uid: 'uid_admin',
          deviceId: 'dev_OLD',
          version: 1,
          versionField: 'version',
        ),
        asCreate: true,
      )..['updatedAt'] = updatedAt;
      return payload;
    }

    // The oldest document, a legacy sample without the parent stamp.
    remote.documents['$orgId/productBatchSamples/legacy_4'] = Map.of(
      legacySampleDoc(4, 'legacy_4'),
    )..['updatedAt'] = '2026-01-04T00:00:00.000Z';
    remote.documents['$orgId/productBatchSamples/legacy_9'] =
        modernDoc(9, '2026-02-09T00:00:00.000Z');
    remote.documents['$orgId/productBatchSamples/legacy_10'] =
        modernDoc(10, '2026-02-10T00:00:00.000Z');
    // A third sample without the stamp, arriving after the stamped ones:
    // same salvage as legacy_4.
    remote.documents['$orgId/productBatchSamples/legacy_11'] = Map.of(
      modernDoc(11, '2026-02-11T00:00:00.000Z'),
    )..remove('batchRemoteId');

    // pageSize 2: the legacy doc (oldest) opens page 1; without the salvage
    // the cursor never advances past it and the newer samples stay behind.
    final report = await PullWorker(
      queue: SyncQueue(fx.helper),
      metadata: SyncMetadata(fx.helper),
      remote: remote,
      conflicts: ConflictResolver(queue: SyncQueue(fx.helper), remote: remote),
      source: SessionSource.empty(() => session),
      pageSize: 2,
      maxPagesPerCycle: 5,
    ).runOnce();
    expect(report.failed, 0, reason: 'all samples must apply');

    final rows = await fx.db.query(
      'product_batch_samples',
      orderBy: 'sample_no ASC',
    );
    expect(
      [for (final r in rows) r['sample_name']],
      ['Batch A', 'Modern 9', 'Modern 10', 'Modern 11'],
      reason: 'the cursor released after the healed legacy sample',
    );
    for (final r in rows) {
      expect(r['batch_remote_id'], 'legacy_inspections_4');
    }
  });

  test('a pre-stamp sample salvages its parent through its own row when the '
      'open-time heal has not stamped it yet', () async {
    // Local row already applied by an earlier cycle, still without the
    // parent-identity stamp; its header carries a UUID remote_id (so the
    // deterministic legacy name cannot help).
    final headerId = await seedBatchHeader('insp-uuid-1');
    await fx.db.insert('product_batch_samples', {
      'batch_id': headerId,
      'sample_no': 1,
      'sample_name': 'Batch A',
      'sample_taker': '',
      'physical_results_json': '{}',
      'chemical_results_json': '[]',
      'tested_by_name': 'Ahmed Ali',
      'tested_at': '2026-01-01 08:00:00',
      'decision_status': '',
      'created_at': '2026-01-01 07:00:00',
      'remote_id': 'legacy_5',
      'device_id': 'dev_OLD',
      'batch_remote_id': '',
    });

    remote.documents['$orgId/productBatchSamples/legacy_5'] =
        legacySampleDoc(99, 'legacy_5');

    final report = await worker.runOnce();
    expect(report.failed, 0,
        reason: 'the sample must salvage the parent through its own row');

    final rows = await fx.db.query('product_batch_samples');
    expect(rows, hasLength(1));
    final applied = rows.single;
    expect((applied['batch_id'] as num).toInt(), headerId);
    expect(applied['batch_remote_id'], 'insp-uuid-1');

    final second = await worker.runOnce();
    expect(second.failed, 0);
  });

  test('a legacy organization setting whose key collides with a stale '
      'sibling applies instead of tripping the UNIQUE constraint', () async {
    // Two local rows for what is really one setting: the sibling that
    // already holds the business key under an unrelated remote_id, and the
    // row the incoming document matches by remote_id (holding a different
    // key). The old code updated the second row's key and died with
    // "UNIQUE constraint failed: organization_settings.key" on every cycle.
    await fx.db.insert('organization_settings', {
      'key': 'org_name',
      'value': 'old value',
      'remote_id': 'legacy_organization_settings_20',
      'version': 1,
      'remote_version': 1,
      'sync_state': 'synced',
    });
    await fx.db.insert('organization_settings', {
      'key': 'temp_note',
      'value': 'stale',
      'remote_id': 'legacy_organization_settings_13',
      'version': 1,
      'remote_version': 1,
      'sync_state': 'synced',
    });

    final setting = syncEntities.firstWhere((e) => e.type == 'organizationSetting');
    final doc = buildRemotePayload(
      setting,
      {
        'id': 13,
        'key': 'org_name',
        'value': 'new value',
        'remote_id': 'legacy_organization_settings_13',
        'device_id': 'dev_OLD',
      },
      const SyncPayloadContext(
        organizationId: orgId,
        uid: 'uid_admin',
        deviceId: 'dev_OLD',
        version: 2,
        versionField: 'version',
      ),
      asCreate: false,
    );
    doc['version'] = 2;
    remote.documents['$orgId/organizationSettings/'
        'legacy_organization_settings_13'] = doc;

    final report = await worker.runOnce();
    expect(report.failed, 0,
        reason: 'the setting must merge over the stale sibling, not fail');

    final rows = await fx.db.query('organization_settings');
    expect(rows, hasLength(1), reason: 'one business key = one local row');
    final applied = rows.single;
    expect(applied['key'], 'org_name');
    expect(applied['value'], 'new value');
    expect(applied['remote_id'], 'legacy_organization_settings_13');
  });
}
