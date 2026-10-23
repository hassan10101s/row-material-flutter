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

/// Salvage path for legacy `inventory_lots` documents pushed before the
/// parent-identity stamping existed (the remote document carries no
/// `inventoryRemoteId`). Before the fix these produced the endless
/// "transient: inventory lot without parent identity" pull skips on every
/// cycle.
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

  /// A legacy lot payload shaped exactly like `buildRemotePayload` produced
  /// it — minus `inventoryRemoteId`, which pre-stamping rows lacked.
  Map<String, dynamic> legacyLotDoc(int inventoryId) {
    final lot = syncEntities.firstWhere((e) => e.type == 'inventoryLot');
    final payload = buildRemotePayload(
      lot,
      {
        'id': 9,
        'inventory_id': inventoryId,
        'lot_no': 'L-0009',
        'qty_received': 10.0,
        'qty_remaining': 4.0,
        'expiry_date': '',
        'supplier': '',
        'note': '',
        'received_by': null,
        'received_at': '2026-01-01 08:00:00',
        'created_at': '2026-01-01 07:00:00',
        'updated_at': null,
        'version': 1,
        'sync_state': 'local',
        'remote_id': 'legacy_inventory_lots_9',
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
    )..remove('inventoryRemoteId');
    return payload;
  }

  test('a legacy lot heals through the deterministic legacy item name',
      () async {
    // The parent item, with the remote_id the origin device's open-time
    // backfill wrote for legacy rows.
    final itemId = await fx.db.rawInsert(
      "INSERT INTO lab_inventory (name, unit, current_qty, remote_id, "
      "created_at, updated_at) VALUES ('Cement Powder', 'kg', 100, 'x', "
      "'x', 'x')",
    );
    await fx.db.rawUpdate(
      "UPDATE lab_inventory SET remote_id = 'legacy_lab_inventory_$itemId' "
      'WHERE id = ?',
      [itemId],
    );

    remote.documents['$orgId/inventoryLots/legacy_inventory_lots_9'] =
        legacyLotDoc(itemId);

    final report = await worker.runOnce();
    expect(report.failed, 0,
        reason: 'the legacy lot must resolve, not skip as transient');

    final lots = await fx.db.query('inventory_lots');
    expect(lots, hasLength(1));
    final appliedLost = lots.single;
    // The parent pointer was remapped to THIS device's item id, and the
    // parent identity is stamped so the next push carries full identity.
    expect((appliedLost['inventory_id'] as num).toInt(), itemId);
    expect(
      appliedLost['inventory_remote_id'],
      'legacy_lab_inventory_$itemId',
    );
    expect(appliedLost['remote_id'], 'legacy_inventory_lots_9');

    // And the healed row persists: a later run does not fail again.
    final second = await worker.runOnce();
    expect(second.failed, 0);
  });
}
