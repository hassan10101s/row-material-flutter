import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/constants/app_errors.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  final tmp = Directory.systemTemp.createTempSync('matlab_consumption');
  late DatabaseHelper dbHelper;
  late LabRepo repo;
  late Database db;
  late int h2so4Id, catalystId, titerId;
  late int analysisId;

  Future<Map<String, dynamic>> inventoryQty(int id) async {
    final rows = await db.query('lab_inventory', where: 'id = ?', whereArgs: [id]);
    return rows.single;
  }

  Future<int> logCount(int testId) async {
    final rows = await db.query('lab_consumption_log',
        where: 'sample_test_id = ?', whereArgs: [testId]);
    return rows.length;
  }

  Future<int> testCount() async {
    final rows = await db.query('lab_sample_tests');
    return rows.length;
  }

  setUpAll(() async {
    dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await dbHelper.database;
    repo = LabRepo(dbHelper: dbHelper);
    final ts = nowIso();

    h2so4Id = await db.insert('lab_inventory', {
      'name': 'H2SO4 Concentrated', 'category': 'liquid', 'unit': 'mL',
      'current_qty': 100, 'min_qty': 5, 'created_at': ts, 'updated_at': ts,
    });
    catalystId = await db.insert('lab_inventory', {
      'name': 'Kjeldahl Catalyst Tablet', 'category': 'powder', 'unit': 'pc',
      'current_qty': 10, 'min_qty': 2, 'created_at': ts, 'updated_at': ts,
    });
    titerId = await db.insert('lab_inventory', {
      'name': 'NaOH 0.1M', 'category': 'liquid', 'unit': 'mL',
      'current_qty': 0, 'min_qty': 0, 'created_at': ts, 'updated_at': ts,
    });

    final created = await repo.createAnalysis(
      name: 'Protein',
      unit: '%',
      description: 'Kjeldahl total protein',
      dynamicFields: ['Sample Name', 'Titer', 'Notes'],
      items: [
        {'inventory_id': h2so4Id, 'qty_per_sample': 15, 'unit': 'mL'},
        {'inventory_id': catalystId, 'qty_per_sample': 1, 'unit': 'pc'},
      ],
      fieldChemicalLinks: [
        {
          'dynamic_field': 'Titer',
          'kind': 'link',
          'inventory_id': titerId,
          'unit': 'mL',
        },
      ],
    );
    analysisId = created['id'] as int;
  });

  tearDownAll(() async {
    await dbHelper.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('protein-style test consumes fixed + field-linked chemicals', () async {
    await db.update('lab_inventory', {'current_qty': 40}, where: 'id = ?', whereArgs: [titerId]);

    final result = await repo.runSampleTest(
      analysisId: analysisId,
      sourceType: 'raw_material',
      sourceName: 'Wheat',
      sampleName: 'Sample A',
      dynamicValues: {'Titer': '3', 'Notes': 'ok'},
      user: null,
    );

    final consumption = (result['consumption'] as List)
        .cast<Map<String, dynamic>>();
    expect(consumption, hasLength(3), reason: 'two fixed + one linked');
    final byName = {
      for (final c in consumption) '${c['inventory_name']}': c,
    };
    expect(byName['H2SO4 Concentrated']!['qty_used'], 15.0);
    expect(byName['Kjeldahl Catalyst Tablet']!['qty_used'], 1.0);
    expect(byName['NaOH 0.1M']!['qty_used'], 3.0);
    expect(byName['NaOH 0.1M']!['shortfall_qty'], 0.0);

    expect((await inventoryQty(h2so4Id))['current_qty'], 85.0);
    expect((await inventoryQty(catalystId))['current_qty'], 9.0);
    expect((await inventoryQty(titerId))['current_qty'], 37.0);

    final testId = (result['test'] as Map)['id'] as int;
    expect(await logCount(testId), 3);
  });

  test('fixed consumption converts units to the inventory unit', () async {
    final saltId = await db.insert('lab_inventory', {
      'name': 'Salt Batch', 'category': 'powder', 'unit': 'kg',
      'current_qty': 5, 'min_qty': 1, 'created_at': nowIso(), 'updated_at': nowIso(),
    });
    final created = await repo.createAnalysis(
      name: 'Salinity',
      unit: '%',
      dynamicFields: ['Sample Name'],
      items: [
        {'inventory_id': saltId, 'qty_per_sample': 1500, 'unit': 'g'},
      ],
    );
    final analysisId = created['id'] as int;
    final result = await repo.runSampleTest(
      analysisId: analysisId,
      sourceType: 'product',
      sourceName: 'Product P',
      sampleName: 'Sample S',
      user: null,
    );
    final consumption = (result['consumption'] as List)
        .cast<Map<String, dynamic>>();
    expect(consumption.single['qty_used'], 1.5, reason: '1500 g -> 1.5 kg');
    expect((await inventoryQty(saltId))['current_qty'], 3.5);
  });

  test('insufficient stock blocks the test with a clear message', () async {
    await db.update('lab_inventory', {'current_qty': 2}, where: 'id = ?', whereArgs: [titerId]);
    final before = await testCount();

    await expectLater(
      repo.runSampleTest(
        analysisId: analysisId,
        sourceType: 'raw_material',
        sourceName: 'Wheat',
        sampleName: 'Sample B',
        dynamicValues: {'Titer': '3'},
        user: null,
      ),
      throwsA(isA<ValidationError>().having(
          (e) => e.message, 'message',
          contains(AppErrors.insufficientStock))),
    );
    expect(await testCount(), before, reason: 'no test row saved');
    expect((await inventoryQty(titerId))['current_qty'], 2.0,
        reason: 'stock untouched');
    expect(await logCount(before + 999), 0, reason: 'no consumption logged');
  });

  test('zero stock on a required fixed chemical blocks the test', () async {
    await db.update('lab_inventory', {'current_qty': 0}, where: 'id = ?', whereArgs: [catalystId]);
    final before = await testCount();

    await expectLater(
      repo.runSampleTest(
        analysisId: analysisId,
        sourceType: 'raw_material',
        sourceName: 'Wheat',
        sampleName: 'Sample C',
        dynamicValues: {'Titer': '1'},
        user: null,
      ),
      throwsA(isA<ValidationError>().having(
          (e) => e.message, 'message',
          contains(AppErrors.insufficientStock))),
    );

    expect(await testCount(), before);
    expect((await inventoryQty(catalystId))['current_qty'], 0.0);
  });
}