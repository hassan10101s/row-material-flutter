import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/sync/sync_write.dart' as sync_write;
import 'sync_test_fixture.dart';

/// End-to-end ledger semantics for comprehensive sync (plan §4+§12):
/// balance = SUM(deltas); concurrent devices merge instead of overwriting;
/// reversal restores; recompute recovers the cache.
void main() {
  late SyncFixture fx;
  late SyncQueue queue;

  setUp(() async {
    fx = await openSyncFixture();
    queue = SyncQueue(fx.helper);
  });

  tearDown(() async {
    await fx.dispose();
  });

  Future<int> seedInventory(String name, double qty) async {
    final id = await fx.db.rawInsert(
      "INSERT INTO lab_inventory (name, category, unit, current_qty, min_qty, "
      "description, created_by, created_at, updated_at, remote_id) "
      "VALUES (?, 'liquid', 'mL', ?, 0, '', 0, 'x', 'x', ?)",
      [name, qty, sync_write.newRemoteId()],
    );
    return id;
  }

  Future<void> recordTxn(
    int invId,
    double delta,
    String type, {
    String ref = 'test',
  }) async {
    final now = '2026-10-11T00:00:00.000';
    final remoteId = sync_write.newRemoteId();
    await fx.db.rawInsert(
      'INSERT INTO inventory_transactions (remote_id, inventory_id, '
      'quantity_delta, transaction_type, reference_type, reason, created_at, '
      'updated_at, device_id, version, sync_state) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)',
      [remoteId, invId, delta, type, ref, ref, now, now, 'd1', 'queued'],
    );
  }

  test('two-device scenario converges to 102, not last-writer-wins', () async {
    // Device A: opening 100.
    final invId = await seedInventory('Two-Device Reagent', 100);
    await recordTxn(invId, 100, 'OPENING_BALANCE');
    // Device A consumes 5 (analysis).
    await recordTxn(invId, -5, 'CONSUMPTION');
    // Device B (after pull) sees 95, adds 10, consumes 3.
    await recordTxn(invId, 10, 'RECEIPT');
    await recordTxn(invId, -3, 'CONSUMPTION');

    final balance = await sync_write.recomputeBalance(fx.db, invId);
    // 100 (opening row mirrored) +100 opening? No: opening is the ledger row
    // itself. Seed qty is the cache; ledger holds 100-5+10-3 = 102.
    expect(balance, 102);
  });

  test('reversal restores balance without deleting history', () async {
    final invId = await seedInventory('Reversal Reagent', 0);
    await recordTxn(invId, 50, 'RECEIPT');
    await recordTxn(invId, -20, 'CONSUMPTION');
    await recordTxn(invId, 20, 'REVERSAL', ref: 'void');
    final balance = await sync_write.recomputeBalance(fx.db, invId);
    expect(balance, 50);
    final rows = await fx.db.query(
      'inventory_transactions',
      where: 'inventory_id = ?',
      whereArgs: [invId],
    );
    // Nothing deleted: receipt + consumption + reversal all present.
    expect(rows.length, 3);
  });

  test('enqueueLocalChange stamps version + queue in one txn', () async {
    final invId = await seedInventory('Queue Reagent', 5);
    final rows = await fx.db.query(
      'lab_inventory', where: 'id = ?', whereArgs: [invId], limit: 1,
    );
    final entity = SyncEntity.byType('inventoryItem')!;
    await fx.db.transaction((txn) async {
      await sync_write.enqueueLocalChange(
        executor: txn,
        entity: entity,
        row: Map<String, dynamic>.from(rows.first),
        operation: 'update',
        queue: queue,
        organizationId: 'org1',
        uid: 'u1',
        deviceId: 'd1',
      );
    });
    final queueRows = await fx.db.query(
      'sync_queue',
      where: 'entity_type = ?',
      whereArgs: ['inventoryItem'],
    );
    expect(queueRows, hasLength(1));
    expect(queueRows.first['operation'], 'update');
    final stamped = await fx.db.query(
      'lab_inventory', where: 'id = ?', whereArgs: [invId], limit: 1,
    );
    expect(stamped.first['sync_state'], 'queued');
  });

  test('negative balance is detectable from the ledger', () async {
    final invId = await seedInventory('Negative Reagent', 0);
    await recordTxn(invId, 10, 'RECEIPT');
    await recordTxn(invId, -15, 'CONSUMPTION');
    final balance = await sync_write.recomputeBalance(fx.db, invId);
    expect(balance, lessThan(0));
  });
}
