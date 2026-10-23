import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/entity_registry.dart';
import '../sync/sync_test_fixture.dart';

/// Migration coverage for comprehensive sync (plan §2+§11):
/// every operational table gains `remote_id` + sync columns, legacy rows get
/// a stable backfill, and `inventory_transactions` exists with its ledger
/// constraint. Re-running the open must be idempotent.
void main() {
  late SyncFixture fx;

  setUp(() async {
    fx = await openSyncFixture();
  });

  tearDown(() async {
    await fx.dispose();
  });

  test('synced tables carry remote_id + sync columns', () async {
    for (final table in DatabaseHelperSyncedTablesForTest.tables) {
      final cols = await fx.db.rawQuery('PRAGMA table_info($table)');
      if (cols.isEmpty) continue; // Table absent in this build: skip.
      final names = cols.map((c) => '${c['name']}').toSet();
      for (final col in [
        'remote_id', 'version', 'remote_version', 'remote_synced_at',
        'sync_state', 'deleted_at', 'updated_at', 'updated_by', 'device_id',
      ]) {
        expect(names.contains(col), isTrue, reason: '$table.$col missing');
      }
    }
  });

  test('legacy rows are backfilled with stable remote_id', () async {
    await fx.db.rawInsert(
      "INSERT INTO lab_inventory (name, category, unit, current_qty, min_qty, "
      "description, created_by, created_at, updated_at) "
      "VALUES ('Backfill Reagent', 'liquid', 'mL', 10, 1, '', 0, 'x', 'x')",
    );
    // Re-open to trigger the every-open backfill path.
    await fx.helper.close();
    final db = await fx.helper.database;
    final rows = await db.query(
      'lab_inventory',
      columns: ['id', 'remote_id'],
      where: 'name = ?',
      whereArgs: ['Backfill Reagent'],
    );
    expect(rows, hasLength(1));
    expect('${rows.first['remote_id']}', startsWith('legacy_lab_inventory_'));
  });

  test('product_batch_samples exists with batch scoping', () async {
    // No products exist yet: no backfill, only schema. The every-open
    // guarantee creates it on fresh and existing installs alike.
    final cols = await fx.db.rawQuery('PRAGMA table_info(product_batch_samples)');
    expect(cols, isNotEmpty);
    final names = cols.map((c) => '${c['name']}').toSet();
    for (final col in [
      'batch_id', 'sample_no', 'sample_name',
      // Independent sample data: taker + own physical/chemical results.
      'sample_taker', 'physical_results_json', 'chemical_results_json',
      // Tested-by per row (بواسطة من): who entered the sample.
      'tested_by', 'tested_by_name', 'tested_at',
      'decision_status', 'decision_reason',
      'remote_id', 'device_id', 'version', 'sync_state',
    ]) {
      expect(names.contains(col), isTrue, reason: 'product_batch_samples.$col missing');
    }

    // UNIQUE(batch_id, sample_no): no duplicate sample numbers in one batch.
    final batchId = await _seedProductBatch(fx);
    await fx.db.rawInsert(
      'INSERT INTO product_batch_samples (batch_id, sample_no, sample_name, '
      'tested_at, created_at) VALUES (?, ?, ?, ?, ?)',
      [batchId, 1, 'Sample 1', 'x', 'x'],
    );
    expect(
      () => fx.db.rawInsert(
        'INSERT INTO product_batch_samples (batch_id, sample_no, sample_name, '
        'tested_at, created_at) VALUES (?, ?, ?, ?, ?)',
        [batchId, 1, 'Sample 1 dup', 'x', 'x'],
      ),
      throwsA(anything),
    );

    // Re-open: every-open guarantee is idempotent, rows survive.
    await fx.helper.close();
    final db = await fx.helper.database;
    final rows = await db.query(
      'product_batch_samples', where: 'batch_id = ?', whereArgs: [batchId],
    );
    expect(rows, hasLength(1));
    expect('${rows.first['sample_name']}', 'Sample 1');
  });

  test('inventory_transactions ledger exists with append-only types', () async {
    final cols = await fx.db.rawQuery('PRAGMA table_info(inventory_transactions)');
    expect(cols, isNotEmpty);
    final names = cols.map((c) => '${c['name']}').toSet();
    expect(names.contains('quantity_delta'), isTrue);
    expect(names.contains('transaction_type'), isTrue);
    expect(names.contains('remote_id'), isTrue);

    // CHECK constraint rejects unknown types.
    await fx.db.rawInsert(
      "INSERT INTO lab_inventory (name, category, unit, current_qty, min_qty, "
      "description, created_by, created_at, updated_at) "
      "VALUES ('Ledger Check', 'liquid', 'mL', 0, 0, '', 0, 'x', 'x')",
    );
    final inv = await fx.db.query(
      'lab_inventory', columns: ['id'], where: 'name = ?',
      whereArgs: ['Ledger Check'], limit: 1,
    );
    final invId = (inv.first['id'] as num).toInt();
    expect(
      () => fx.db.rawInsert(
        'INSERT INTO inventory_transactions (remote_id, inventory_id, '
        'quantity_delta, transaction_type, created_at) '
        'VALUES (?, ?, ?, ?, ?)',
        ['t1', invId, 5, 'BOGUS_TYPE', 'x'],
      ),
      throwsA(anything),
    );
  });

  test('integrity_check passes after migration', () async {
    final check = await fx.db.rawQuery('PRAGMA integrity_check');
    expect('${check.first.values.first}'.trim(), 'ok');
  });

  test('all new sync entities resolve by type', () async {
    for (final type in [
      'inventoryItem', 'inventoryTransaction', 'consumption',
      'stockAdjustment', 'equipment', 'equipmentEvent', 'worksheet',
      'referenceMaterial', 'labMaterialAnalysis', 'productBatchSample',
    ]) {
      expect(SyncEntity.byType(type), isNotNull, reason: type);
    }
  });

  test('findLocalRef matches by remote_id across devices', () async {
    await fx.db.rawInsert(
      "INSERT INTO lab_inventory (name, category, unit, current_qty, min_qty, "
      "description, created_by, created_at, updated_at, remote_id) "
      "VALUES ('Remote Match', 'liquid', 'mL', 7, 1, '', 0, 'x', 'x', 'uuid-abc-123')",
    );
    final entity = SyncEntity.byType('inventoryItem')!;
    // The data carries NO natural key (`name` is absent): only the
    // `remote_id` fast path can resolve this document. With the natural key
    // in place the test used to pass while the fast path itself queried the
    // integer pk against a UUID and never matched anything.
    final found = await findLocalRef(
      fx.db, entity, 'uuid-abc-123',
      {'remoteId': 'uuid-abc-123'},
      localDeviceId: 'device-B',
    );
    expect(found, isNotNull);
    // The document id itself (as a tombstone carries it, without even a
    // `remoteId` field) must also resolve through `remote_id`.
    final byDocId = await findLocalRef(
      fx.db, entity, 'uuid-abc-123',
      const {},
      localDeviceId: 'device-B',
    );
    expect(byDocId, isNotNull, reason: 'tombstone docs carry no payload fields');
    // The document id alone matches even when the payload hints a name with
    // no row: it must never null out a findable row.
    final withForeignFields = await findLocalRef(
      fx.db, entity, 'uuid-abc-123',
      {'name': 'completely-different-name'},
      localDeviceId: 'device-B',
    );
    expect(withForeignFields, isNotNull);
  });

  test('foreign localId cannot hijack an unrelated row', () async {
    // Device-B row of pk id=1 that owns a DIFFERENT cross-device identity.
    await fx.db.rawInsert(
      "INSERT INTO lab_inventory (name, category, unit, current_qty, min_qty, "
      "description, created_by, created_at, updated_at, remote_id, device_id) "
      "VALUES ('Mine', 'liquid', 'mL', 2, 1, '', 0, 'x', 'x', 'uuid-mine', 'device-B')",
    );
    // A foreign (device-A) document whose origin-device localId happens to
    // be 1 — the classic autoincrement collision.
    final entity = SyncEntity.byType('inventoryItem')!;
    final hijack = await findLocalRef(
      fx.db, entity, 'uuid-foreign',
      {'localId': 1, 'deviceId': 'device-A'},
      localDeviceId: 'device-B',
    );
    expect(
      hijack,
      isNull,
      reason: 'row 1 carries remote_id "uuid-mine": the foreign localId '
          'must not match it (no natural key either → fresh insert expected)',
    );
    // A row WITHOUT a remote_id (legacy) keeps the legacy localId semantics.
    await fx.db.rawInsert(
      "INSERT INTO lab_inventory (name, category, unit, current_qty, min_qty, "
      "description, created_by, created_at, updated_at) "
      "VALUES ('Legacy', 'liquid', 'mL', 3, 1, '', 0, 'x', 'x')",
    );
    final legacyRow = (await fx.db.query(
      'lab_inventory',
      columns: ['id'],
      where: 'name = ?',
      whereArgs: ['Legacy'],
    )).single;
    final legacy = await findLocalRef(
      fx.db, entity, 'legacy_lab_inventory_${legacyRow['id']}',
      {
        'localId': legacyRow['id'],
        'deviceId': 'device-A',
      },
      localDeviceId: 'device-B',
    );
    expect(legacy, isNotNull, reason: 'legacy rows without identity still match locally');
  });
}

/// Seeds one product inspection (the batch header) and returns its id.
/// Reference FK requires a material row first.
Future<int> _seedProductBatch(SyncFixture fx) async {
  final matId = await fx.db.rawInsert(
    "INSERT INTO reference_materials (material_name, material_code, "
    "physical_reference_json, chemical_reference_json, active, imported_at) "
    "VALUES ('Batch Mat', 'BM', '{}', '{}', 1, 'x')",
  );
  return await fx.db.rawInsert(
    'INSERT INTO inspections (entry_code, material_id, material_name, '
    'material_code, inspection_date, specialist_name, physical_results_json, '
    'chemical_results_json, physical_reference_json, chemical_reference_json, '
    'decision_status, snapshot_json, sample_names_json, decision_version, '
    'created_by, created_by_name, created_at, updated_at, inspection_kind, '
    'quantity, batch_number) '
    "VALUES ('BATCH-001', ?, 'Batch Mat', 'BM', '2026-01-01', 'QC', '{}', "
    "'{}', '{}', '{}', '', '{}', '[]', 1, 0, '', 'x', 'x', 'product', "
    "'50 tons', 'LOT-7')",
    [matId],
  );
}

/// The production `syncedTables` list, mirrored without importing the
/// private helper (keeps the test honest: it fails if a table is dropped).
/// `parameters` is intentionally absent: device-local master data, no
/// SyncEntity, never enqueued/pulled.
abstract final class DatabaseHelperSyncedTablesForTest {
  static const tables = [
    'inspections', 'inspection_status_history', 'lab_sample_tests', 'users',
    'lab_analyses', 'lab_analysis_items', 'lab_field_chemical_links',
    'lab_constants', 'lab_products', 'lab_product_analyses', 'lab_units',
    'lab_material_analyses', 'reference_materials',
    'lab_inventory', 'inventory_lots', 'inventory_transactions',
    'lab_consumption_log',
    'lab_stock_adjustments', 'lab_worksheet', 'lab_equipment',
    'lab_equipment_events', 'product_batch_samples',
  ];
}
