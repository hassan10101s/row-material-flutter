import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/lab/domain/chemical_consumption_report.dart';
import 'package:material_lab/features/lab/data/server_confirmed_lab_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/sync/audit_logger.dart';

class _Db extends Mock implements DatabaseHelper {}

class _Guard extends Mock implements WriteGuard {}

class _Queue extends Mock implements SyncQueue {}

class _Audit extends Mock implements AuditLogger {}

void main() {
  sqfliteFfiInit();
  late Database db;
  late LabRepo repo;
  final period = ConsumptionPeriod(DateTime(2026, 8, 1), DateTime(2026, 11, 1));

  setUp(() async {
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
      'CREATE TABLE lab_inventory(id INTEGER PRIMARY KEY, name TEXT, unit TEXT, deleted_at TEXT)',
    );
    await db.execute(
      'CREATE TABLE lab_consumption_log(id INTEGER PRIMARY KEY, inventory_id INTEGER, sample_test_id INTEGER, qty_used REAL, applied_qty REAL, shortfall_qty REAL, event_type TEXT, created_at TEXT, deleted_at TEXT)',
    );
    // The mirrored ledger is deliberately present: reading both would double consumption.
    await db.execute(
      'CREATE TABLE inventory_transactions(inventory_id INTEGER, quantity_delta REAL, transaction_type TEXT)',
    );
    await db.insert('lab_inventory', {'id': 1, 'name': 'HCl', 'unit': 'mL'});
    await db.insert('lab_inventory', {'id': 2, 'name': 'Salt', 'unit': 'kg'});
    await db.insert('lab_inventory', {
      'id': 3,
      'name': 'Catalyst',
      'unit': 'pc',
    });
    final helper = _Db();
    when(() => helper.readDatabase).thenAnswer((_) async => db);
    repo = LabRepo(dbHelper: helper);
  });
  tearDown(() => db.close());

  test(
    'guarded report denies unauthorized reads before opening the database',
    () async {
      final helper = _Db(), guard = _Guard();
      when(() => guard.allows(any())).thenReturn(false);
      when(() => guard.online).thenReturn(true);
      final guarded = ServerConfirmedLabRepository(
        dbHelper: helper,
        guard: guard,
        queue: _Queue(),
        audit: _Audit(),
      );
      await expectLater(
        () => guarded.chemicalConsumptionReport(period: period),
        throwsA(isA<AuthorizationError>()),
      );
      verifyNoMoreInteractions(helper);
    },
  );

  Future<void> line(
    double qty, {
    int item = 1,
    String type = 'CONSUMPTION',
    String at = '2026-09-10 10:00:00',
    double? applied,
    bool legacy = false,
    bool deleted = false,
  }) => db
      .insert('lab_consumption_log', {
        'inventory_id': item,
        'sample_test_id': 7,
        'qty_used': qty,
        'applied_qty': legacy ? null : applied ?? qty.abs(),
        'shortfall_qty': 0,
        'event_type': type,
        'created_at': at,
        'deleted_at': deleted ? '2026-09-11' : null,
      })
      .then((_) {});

  test(
    'three calendar months clamp end-of-month, preserve leap days and cross year',
    () {
      expect(
        ConsumptionPeriod.lastThreeMonths(DateTime(2026, 5, 31)).label,
        '2026-02-28 - 2026-05-31',
      );
      expect(
        ConsumptionPeriod.lastThreeMonths(DateTime(2024, 5, 31)).label,
        '2024-02-29 - 2024-05-31',
      );
      expect(
        ConsumptionPeriod.lastThreeMonths(DateTime(2026, 1, 31)).label,
        '2025-10-31 - 2026-01-31',
      );
      expect(
        ConsumptionPeriod.lastThreeMonths(DateTime(2026, 11, 1, 15)).label,
        '2026-08-01 - 2026-11-01',
      );
      expect(
        () => ConsumptionPeriod(DateTime(2026, 11, 2), DateTime(2026, 11, 1)),
        throwsA(isA<ValidationError>()),
      );
    },
  );

  test(
    'inclusive whole days with ISO and space timestamps; no shortfalls or mirrored movements counted',
    () async {
      await line(100, at: '2026-07-31 23:59:59');
      await line(10, at: '2026-08-01T00:00:00');
      await line(4, at: '2026-11-01 23:59:59.999');
      await line(100, at: '2026-11-02T00:00:00');
      await line(50, applied: 0); // Nothing was actually dispensed.
      await line(2, legacy: true);
      await line(-3, type: 'REVERSAL');
      await line(90, deleted: true);
      await line(800, type: 'RECEIPT');
      await db.insert('inventory_transactions', {
        'inventory_id': 1,
        'quantity_delta': -16,
        'transaction_type': 'CONSUMPTION',
      });
      final report = await repo.chemicalConsumptionReport(period: period);
      final row = report.rows.singleWhere((row) => row.inventoryId == 1);
      expect(row.consumed, 16);
      expect(row.returned, 3);
      expect(row.net, 13);
      expect(report.rows, hasLength(3));
      expect(report.rows.singleWhere((row) => row.inventoryId == 2).net, 0);
    },
  );

  test(
    'lot splits are summed; units stay separate and selected material filters only output',
    () async {
      await line(2);
      await line(3);
      await line(0.0015, item: 2);
      await line(2, item: 3);
      final report = await repo.chemicalConsumptionReport(
        period: period,
        inventoryId: 2,
      );
      expect(report.rows, hasLength(1));
      expect(report.rows.single.unit, 'kg');
      expect(report.rows.single.consumed, 0.0015);
      expect(
        report.chemicals.singleWhere((row) => row.inventoryId == 1).consumed,
        5,
      );
      expect(
        report.chemicals.singleWhere((row) => row.inventoryId == 3).unit,
        'pc',
      );
    },
  );

  test(
    'return-only period keeps negative net and archived material history without a live test row',
    () async {
      await line(8, at: '2026-07-31 12:00:00');
      await line(-8, type: 'REVERSAL');
      await db.update('lab_inventory', {
        'deleted_at': '2026-10-01',
      }, where: 'id = 1');
      await db.update('lab_inventory', {
        'deleted_at': '2026-10-01',
      }, where: 'id = 3');
      final report = await repo.chemicalConsumptionReport(period: period);
      final row = report.rows.singleWhere((row) => row.inventoryId == 1);
      expect(row.consumed, 0);
      expect(row.returned, 8);
      expect(row.net, -8);
      expect(report.rows.any((row) => row.inventoryId == 3), false);
      final selected = await repo.chemicalConsumptionReport(
        period: period,
        inventoryId: 3,
      );
      expect(selected.rows.single.net, 0);
    },
  );

  test(
    'offset-aware timestamps use local calendar dates and reading never changes data',
    () async {
      final instant = DateTime.utc(2026, 9, 30, 23, 30);
      await line(6, at: instant.toIso8601String());
      final before = await db.query('lab_consumption_log');
      final local = instant.toLocal();
      final report = await repo.chemicalConsumptionReport(
        period: ConsumptionPeriod(local, local),
      );
      expect(
        report.rows.singleWhere((row) => row.inventoryId == 1).consumed,
        6,
      );
      expect(await db.query('lab_consumption_log'), before);
      expect(await db.query('inventory_transactions'), isEmpty);
    },
  );

  test(
    'quantity formatting preserves meaningful small amounts and negative returns',
    () {
      expect(ChemicalConsumptionRow.quantity(0), '0');
      expect(ChemicalConsumptionRow.quantity(100), '100');
      expect(ChemicalConsumptionRow.quantity(0.0015), '0.0015');
      expect(ChemicalConsumptionRow.quantity(-8), '-8');
      expect(
        double.parse(ChemicalConsumptionRow.quantity(0.00000001)),
        closeTo(0.00000001, 1e-15),
      );
    },
  );
}
