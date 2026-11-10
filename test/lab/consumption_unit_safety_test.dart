import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/constants/app_errors.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/core/formula_engine.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Paths extends AppPaths {
  _Paths(this.root);
  final String root;
  @override
  Future<Directory> appSupportRoot() async => Directory('$root/MaterialLab');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();
  late Directory temp;
  late DatabaseHelper helper;
  late LabRepo repo;
  late Database db;
  late int stockId;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('consumption_units_');
    helper = DatabaseHelper(_Paths(temp.path));
    db = await helper.database;
    repo = LabRepo(dbHelper: helper);
    final item = await repo.addInventoryItem(
      name: 'Reagent',
      category: 'liquid',
      unit: 'L',
      qty: 1,
      minQty: 0,
      expiryDate: '2030-12-31',
    );
    stockId = (item['id'] as num).toInt();
  });

  tearDown(() async {
    await helper.close();
    temp.deleteSync(recursive: true);
  });

  Future<double> balance() async =>
      ((await repo.getInventoryItem(stockId))['current_qty'] as num).toDouble();

  Future<Map<String, dynamic>> run(int id, {Map<String, dynamic>? values}) =>
      repo.runSampleTest(
        analysisId: id,
        sourceType: 'sample',
        sourceName: 'Source',
        sampleName: 'Sample',
        dynamicValues: values,
      );

  test(
    '15 mL draws 0.015 L; fixed and variable draws, edits and reversals agree',
    () async {
      final analysis = await repo.createAnalysis(
        name: 'Combined volume',
        dynamicFields: ['Titer'],
        items: [
          {'inventory_id': stockId, 'qty_per_sample': 15, 'unit': 'mL'},
        ],
        fieldChemicalLinks: [
          {
            'dynamic_field': 'Titer',
            'kind': 'link',
            'inventory_id': stockId,
            'unit': 'mL',
          },
        ],
      );
      final saved = await run(analysis['id'] as int, values: {'Titer': '15'});
      final used = (saved['consumption'] as List).single as Map;
      expect(used['unit'], 'L');
      expect(used['qty_used'], closeTo(0.030, 1e-12));
      expect(await balance(), closeTo(0.970, 1e-12));
      final testId = (saved['test'] as Map)['id'] as int;
      await repo.updateSampleTest(testId, dynamicValues: {'Titer': '20'});
      expect(await balance(), closeTo(0.965, 1e-12));
      await repo.updateSampleTest(testId, dynamicValues: {'Titer': '10'});
      expect(await balance(), closeTo(0.975, 1e-12));
      await repo.deleteSampleTest(testId);
      expect(await balance(), closeTo(1, 1e-12));
    },
  );

  test(
    'unit and category cannot relabel existing stock or historical quantities',
    () async {
      final lotsBefore = await repo.listInventoryLots(stockId);
      for (final change in [
        {'unit': 'mL'},
        {'unit': 'g', 'category': 'powder'},
      ]) {
        await expectLater(
          repo.updateInventoryItem(stockId, change),
          throwsA(
            isA<ValidationError>().having(
              (e) => e.message,
              'message',
              AppErrors.inventoryUnitLocked,
            ),
          ),
        );
      }
      expect((await repo.getInventoryItem(stockId))['unit'], 'L');
      expect(await repo.listInventoryLots(stockId), lotsBefore);
      await repo.adjustStock(itemId: stockId, newQty: 0);
      expect(await balance(), 0);
      await expectLater(
        repo.updateInventoryItem(stockId, {'unit': 'mL'}),
        throwsA(isA<ValidationError>()),
      );
    },
  );

  test('unused empty inventory permits correcting its unit', () async {
    final empty = await repo.addInventoryItem(
      name: 'Unused',
      category: 'liquid',
      unit: 'L',
      qty: 0,
      minQty: 0,
    );
    final updated = await repo.updateInventoryItem(empty['id'] as int, {
      'unit': 'mL',
    });
    expect(updated['unit'], 'mL');
    expect(updated['current_qty'], 0);
  });

  test('linked chemical authoring rejects grams for a liquid', () async {
    await expectLater(
      repo.createAnalysis(
        name: 'Invalid link',
        dynamicFields: ['Titer'],
        fieldChemicalLinks: [
          {
            'dynamic_field': 'Titer',
            'kind': 'link',
            'inventory_id': stockId,
            'unit': 'g',
          },
        ],
      ),
      throwsA(isA<ValidationError>()),
    );
    expect(await balance(), 1);
  });

  for (final invalid in ['g', 'unknown']) {
    test(
      'legacy linked unit $invalid aborts the result without drawing stock',
      () async {
        final analysis = await repo.createAnalysis(
          name: 'Legacy',
          dynamicFields: ['Titer'],
          fieldChemicalLinks: [
            {
              'dynamic_field': 'Titer',
              'kind': 'link',
              'inventory_id': stockId,
              'unit': 'mL',
            },
          ],
        );
        await db.update(
          'lab_field_chemical_links',
          {'unit': invalid},
          where: 'analysis_id = ?',
          whereArgs: [analysis['id']],
        );
        await expectLater(
          run(analysis['id'] as int, values: {'Titer': '0.015'}),
          throwsA(isA<ValidationError>()),
        );
        expect(await balance(), 1);
        expect(await db.query('lab_sample_tests'), isEmpty);
        expect(await db.query('lab_consumption_log'), isEmpty);
        final decorated = await repo.getAnalysis(analysis['id'] as int);
        await expectLater(
          repo.worksheetConsumptionMap(decorated, {'Titer': '15'}, null),
          throwsA(isA<ValidationError>()),
        );
      },
    );
  }

  test('empty legacy consumption unit means the stock unit', () async {
    final analysis = await repo.createAnalysis(
      name: 'Legacy empty',
      items: [
        {'inventory_id': stockId, 'qty_per_sample': 0.015, 'unit': ''},
      ],
    );
    await run(analysis['id'] as int);
    expect(await balance(), closeTo(0.985, 1e-12));
  });

  test('strict conversion rejects matching unknown and missing units', () {
    expect(convertQuantityOrThrow(15, 'mL', 'L'), 0.015);
    for (final pair in [
      ('g', 'L'),
      ('unknown', 'unknown'),
      ('', 'L'),
      ('L', ''),
    ]) {
      expect(
        () => convertQuantityOrThrow(15, pair.$1, pair.$2),
        throwsArgumentError,
      );
    }
  });
}
