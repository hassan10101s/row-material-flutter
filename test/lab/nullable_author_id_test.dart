import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_dates.dart';
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

  final tmp = Directory.systemTemp.createTempSync('matlab_nullable_author');
  late DatabaseHelper dbHelper;
  late LabRepo repo;
  late Database db;
  late int reagentId;
  late int analysisId;

  setUpAll(() async {
    dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await dbHelper.database;
    repo = LabRepo(dbHelper: dbHelper);
    final ts = nowIso();

    reagentId = await db.insert('lab_inventory', {
      'name': 'Reagent Bottle',
      'category': 'liquid',
      'unit': 'mL',
      'current_qty': 100,
      'min_qty': 5,
      'created_at': ts,
      'updated_at': ts,
    });

    final created = await repo.createAnalysis(
      name: 'Purity',
      unit: '%',
      description: 'Assay',
      dynamicFields: const ['Sample Name'],
      items: [
        {'inventory_id': reagentId, 'qty_per_sample': 2, 'unit': 'mL'},
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

  List<Map<String, dynamic>> rowsWithResult(String result) => [
        {
          'source_type': 'raw_material',
          'source_name': 'Wheat',
          'sample_name': 'Sample 1',
          'entry_code': '',
          'tests': {
            '$analysisId': {'result_text': result},
          },
        },
      ];

  test('saveWorksheet accepts a V2 author map whose id is null', () async {
    final result = await repo.saveWorksheet(
      rowsWithResult('0.2'),
      {'id': null, 'username': 'inspector', 'full_name': 'Ahmed Ali'},
    );

    expect(result['created'], 1);
    final rows = await db.query('lab_sample_tests');
    expect(rows, hasLength(1));
    expect(rows.single['result_text'], '0.2');
    expect(rows.single['created_by'], isNull);
  });

  test('saveWorksheet still records a local id when one is present', () async {
    final userId = await db.insert('users', {
      'email': 'inspector@lab.test',
      'full_name': 'Ahmed Ali',
      'role': 'admin',
      'status': 'active',
      'created_at': nowIso(),
    });

    await repo.saveWorksheet(
      rowsWithResult('0.2'),
      {'id': userId, 'username': 'inspector', 'full_name': 'Ahmed Ali'},
    );

    final rows = await db.query('lab_sample_tests',
        where: 'result_text = ?', whereArgs: ['0.2']);
    expect(rows, isNotEmpty);
    expect(rows.last['created_by'], userId);
  });

  test('saveWorksheet tolerates a non-numeric author id', () async {
    final result = await repo.saveWorksheet(
      rowsWithResult('0.2'),
      {'id': 'firebase-uid-abc', 'full_name': 'Ahmed Ali'},
    );
    expect(result['created'], 1);
  });

  test('runSampleTest accepts a V2 author map whose id is null', () async {
    final result = await repo.runSampleTest(
      analysisId: analysisId,
      sourceType: 'raw_material',
      sourceName: 'Barley',
      sampleName: 'Sample 9',
      dynamicValues: const {},
      user: {'id': null, 'full_name': 'Ahmed Ali'},
    );
    expect(result['test'], isNotNull);
    expect((result['test'] as Map)['tested_by'], isNull);
  });

  test('consumption still applies while the author id is null', () async {
    final before =
        (await db.query('lab_inventory', where: 'id = ?', whereArgs: [reagentId]))
            .single['current_qty'] as num;

    final result = await repo.runSampleTest(
      analysisId: analysisId,
      sourceType: 'raw_material',
      sourceName: 'Oats',
      sampleName: 'Sample 10',
      dynamicValues: const {},
      user: {'id': null, 'full_name': 'Ahmed Ali'},
    );

    final consumption = (result['consumption'] as List).cast<Map<String, dynamic>>();
    expect(consumption, hasLength(1));
    final after =
        (await db.query('lab_inventory', where: 'id = ?', whereArgs: [reagentId]))
            .single['current_qty'] as num;
    expect(before - after, 2.0);
  });
}
