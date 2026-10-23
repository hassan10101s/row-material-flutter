import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Lot-tracked inventory over a real database: FEFO order, mandatory
/// expiry, exact reversals, adjustments through lots, and the SUM invariant.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper dbHelper;
  late LabRepo repo;
  late Database db;

  Future<double> pool(int id) async {
    final rows = await db.query(
      'lab_inventory',
      columns: ['current_qty'],
      where: 'id = ?',
      whereArgs: [id],
    );
    return ((rows.single['current_qty'] as num?)?.toDouble() ?? 0.0);
  }

  Future<List<Map<String, dynamic>>> lotsOf(int id) =>
      repo.listInventoryLots(id, includeEmpty: true);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_lots');
    dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await dbHelper.database;
    repo = LabRepo(dbHelper: dbHelper);
    final ts = nowIso();
    await db.insert('lab_inventory', {
      'name': 'Acid',
      'category': 'liquid',
      'unit': 'mL',
      'current_qty': 0,
      'min_qty': 0,
      'created_at': ts,
      'updated_at': ts,
    });
  });

  tearDown(() async {
    await dbHelper.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('receive requires qty and expiry, pool equals lots sum', () async {
    expect(
      () => repo.receiveLot(inventoryId: 1, qty: 0, expiryDate: '2027-01-01'),
      throwsA(isA<ValidationError>()),
    );
    expect(
      () => repo.receiveLot(inventoryId: 1, qty: 10, expiryDate: ''),
      throwsA(isA<ValidationError>()),
    );
    expect(
      () => repo.receiveLot(
        inventoryId: 1,
        qty: 10,
        expiryDate: 'not-a-date',
      ),
      throwsA(isA<ValidationError>()),
    );
    final lot = await repo.receiveLot(
      inventoryId: 1,
      qty: 10,
      expiryDate: '2027-01-01',
      supplier: 'S1',
    );
    expect(lot['lot_no'], startsWith('L-'));
    expect(lot['qty_remaining'], 10.0);
    expect(await pool(1), 10.0);
    expect(await repo.lotBalance(db, 1), 10.0);
  });

  test('draws go earliest-expiry first, expired flagged', () async {
    await repo.receiveLot(
      inventoryId: 1,
      qty: 10,
      expiryDate: '2027-06-01',
    );
    await repo.receiveLot(
      inventoryId: 1,
      qty: 10,
      expiryDate: '2020-01-01',
    );
    final takes = await db.transaction((txn) async {
      final t = await repo.drawLotsFefo(txn, 1, 12);
      await repo.refreshInventoryCache(txn, 1);
      return t;
    });
    // Expired 2020 lot first, then 2 from the 2027 lot.
    expect(takes, hasLength(2));
    expect(takes[0]['qty'], 10.0);
    expect(takes[0]['expired'], isTrue);
    expect(takes[1]['qty'], 2.0);
    expect(takes[1]['expired'], isFalse);
    expect(await pool(1), 8.0);
  });

  test('undated legacy lots sort last', () async {
    final db2 = db;
    await db2.insert('lab_inventory', {
      'name': 'Legacy',
      'category': 'powder',
      'unit': 'g',
      'current_qty': 0,
      'min_qty': 0,
      'created_at': nowIso(),
      'updated_at': nowIso(),
    });
    // Opening balance without expiry -> undated lot.
    await repo.addInventoryItem(
      name: 'Fresh',
      category: 'powder',
      unit: 'g',
      qty: 5,
      minQty: 0,
      executor: db,
    );
    final freshId = 3;
    await repo.receiveLot(
      inventoryId: freshId,
      qty: 5,
      expiryDate: '2027-01-01',
    );
    final takes = await db.transaction((txn) async {
      final t = await repo.drawLotsFefo(txn, freshId, 7);
      await repo.refreshInventoryCache(txn, freshId);
      return t;
    });
    // Dated lot first despite arriving later.
    expect(takes.first['qty'], 5.0);
    expect(takes.first['expired'], isFalse);
    expect(takes.last['qty'], 2.0);
  });

  test('pool rows without lots self-heal on first draw', () async {
    await db.update(
      'lab_inventory',
      {'current_qty': 40},
      where: 'id = ?',
      whereArgs: [1],
    );
    final takes = await db.transaction((txn) async {
      final t = await repo.drawLotsFefo(txn, 1, 15);
      await repo.refreshInventoryCache(txn, 1);
      return t;
    });
    expect(takes, hasLength(1));
    expect(takes.single['qty'], 15.0);
    expect(await pool(1), 25.0);
    expect(await repo.lotBalance(db, 1), 25.0);
  });

  test('shortfall takes what exists, pool stays exact', () async {
    await repo.receiveLot(inventoryId: 1, qty: 6, expiryDate: '2027-01-01');
    final takes = await db.transaction((txn) async {
      final t = await repo.drawLotsFefo(txn, 1, 10);
      await repo.refreshInventoryCache(txn, 1);
      return t;
    });
    expect(takes.single['qty'], 6.0);
    expect(await pool(1), 0.0);
  });

  test('reversal credits the source lot back exactly', () async {
    final a = await repo.receiveLot(
      inventoryId: 1,
      qty: 10,
      expiryDate: '2027-01-01',
    );
    await repo.receiveLot(inventoryId: 1, qty: 10, expiryDate: '2028-01-01');
    final testId = 99;
    await db.transaction((txn) async {
      final takes = await repo.drawLotsFefo(txn, 1, 14);
      for (final take in takes) {
        await repo.insertConsumptionLine(
          txn,
          sampleTestId: testId,
          inventoryId: 1,
          qtyUsed: (take['qty'] as num).toDouble(),
          requestedQty: 14,
          appliedQty: (take['qty'] as num).toDouble(),
          shortfallQty: 0,
          eventType: 'CONSUMPTION',
          lotId: (take['lot_id'] as num).toInt(),
          lotNo: '${take['lot_no']}',
          lotRemoteId: '${take['lot_remote_id']}',
          timestamp: nowIso(),
        );
      }
      await repo.refreshInventoryCache(txn, 1);
      final reversed = await repo.reverseConsumptionToLots(
        txn,
        testId,
        timestamp: nowIso(),
      );
      expect(reversed, 2);
      await repo.refreshInventoryCache(txn, 1);
    });
    expect(await pool(1), 20.0);
    final lots = await lotsOf(1);
    final first = lots.firstWhere((l) => l['id'] == a['id']);
    expect(first['qty_remaining'], 10.0);
  });

  test('adjust increase needs expiry, decrease draws FEFO', () async {
    await repo.receiveLot(inventoryId: 1, qty: 10, expiryDate: '2027-01-01');
    expect(
      () => repo.adjustStock(itemId: 1, newQty: 15, executor: db),
      throwsA(isA<ValidationError>()),
    );
    final afterUp = await repo.adjustStock(
      itemId: 1,
      newQty: 15,
      expiryDate: '2028-06-01',
      reason: 'top-up',
      executor: db,
    );
    expect(afterUp['current_qty'], 15.0);
    expect((afterUp['lot_id'] as num?)?.toInt(), isNotNull);
    final afterDown = await repo.adjustStock(
      itemId: 1,
      newQty: 12,
      reason: 'spill',
      executor: db,
    );
    expect(afterDown['current_qty'], 12.0);
    // Oldest lot (2027) absorbed the decrease first.
    final lots = await repo.listInventoryLots(1, executor: db);
    expect(lots.first['expiry_date'], '2027-01-01');
    expect(lots.first['qty_remaining'], 7.0);
  });

  test('dispose zeroes only expired lots', () async {
    await repo.receiveLot(inventoryId: 1, qty: 10, expiryDate: '2020-05-05');
    await repo.receiveLot(inventoryId: 1, qty: 7, expiryDate: '2029-05-05');
    final disposed = await repo.disposeExpiredLots(1, executor: db);
    expect(disposed, 10.0);
    expect(await pool(1), 7.0);
    final lots = await lotsOf(1);
    expect(
      lots.where((l) => (l['qty_remaining'] as num) > 0),
      hasLength(1),
    );
  });

  test('backfill converts pooled stock into one undated lot', () async {
    await db.insert('lab_inventory', {
      'name': 'Old',
      'category': 'liquid',
      'unit': 'mL',
      'current_qty': 33,
      'min_qty': 0,
      'created_at': nowIso(),
      'updated_at': nowIso(),
    });
    // Guarantees (and the backfill) run on open: reopen to pick up the row
    // written after the first open, like an existing install updating.
    await dbHelper.close();
    dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await dbHelper.database;
    final lots = await repo.listInventoryLots(2, executor: db);
    expect(lots, hasLength(1));
    expect(lots.single['qty_remaining'], 33.0);
    expect(lots.single['expiry_date'], '');
  });
}
