import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/core/lab_result_format.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import '../sync/sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture f;
  late LabRepo repo;
  late int fixed, variable, analysis;
  setUp(() async {
    f = await openSyncFixture();
    repo = LabRepo(dbHelper: f.helper);
    Future<int> stock(String name, double qty) => f.db.insert('lab_inventory', {
      'name': name,
      'category': 'liquid',
      'unit': 'mL',
      'current_qty': qty,
      'min_qty': 0,
      'created_at': '2026-11-03',
      'updated_at': '2026-11-03',
    });
    fixed = await stock('Fixed reagent', 100);
    variable = await stock('Variable reagent', 50);
    final row = await repo.createAnalysis(
      name: 'Measured analysis',
      dynamicFields: ['Weight', 'Volume', 'Titer', 'Notes'],
      formula: 'Weight / Volume',
      items: [
        {'inventory_id': fixed, 'qty_per_sample': 2, 'unit': 'mL'},
      ],
      fieldChemicalLinks: [
        {
          'dynamic_field': 'Titer',
          'kind': 'link',
          'inventory_id': variable,
          'unit': 'mL',
        },
      ],
    );
    analysis = row['id'] as int;
  });
  tearDown(() => f.dispose());
  Future<double> quantity(int id) async =>
      ((await f.db.query(
                'lab_inventory',
                where: 'id = ?',
                whereArgs: [id],
              )).single['current_qty']
              as num)
          .toDouble();
  Future<Map<String, dynamic>> run({
    String result = '',
    Map<String, dynamic> values = const {},
  }) => repo.runSampleTest(
    analysisId: analysis,
    sourceType: 'sample',
    sourceName: 'Sample A',
    sampleName: 'Sample A',
    resultText: result,
    dynamicValues: values,
    user: null,
  );

  test(
    'failure skips missing formula inputs and keeps fixed and entered variable consumption',
    () async {
      final saved = await run(
        result: labFailureResult,
        values: {'Titer': '٣٫٥', 'Notes': 'attempt failed'},
      );
      final test = saved['test'] as Map;
      expect(test['result_text'], labFailureResult);
      expect(await quantity(fixed), 98);
      expect(await quantity(variable), 46.5);
      final read = await repo.enrichTest(
        await repo.getSampleTest(test['id'] as int),
      );
      expect(read['range_state'], 'failed');
      expect(read['value'], isNull);
      expect((saved['consumption'] as List), hasLength(2));
    },
  );
  test(
    'missing variable consumption stays unknown; failure still uses fixed reagent',
    () async {
      await run(result: labFailureResult);
      expect(await quantity(fixed), 98);
      expect(await quantity(variable), 50);
    },
  );
  test(
    'normal formula still requires its inputs and saves nothing on refusal',
    () async {
      await expectLater(run(), throwsA(isA<ValidationError>()));
      expect(await f.db.query('lab_sample_tests'), isEmpty);
      expect(await quantity(fixed), 100);
    },
  );
  test(
    'approved tombstones disappear from the lab dashboard and active history',
    () async {
      final saved = await run(result: labFailureResult);
      final id = (saved['test'] as Map)['id'] as int;
      expect((await repo.dashboardSummary())['kpis']['total_tests'], 1);
      await f.db.update(
        'lab_sample_tests',
        {'deleted_at': '2026-11-03'},
        where: 'id = ?',
        whereArgs: [id],
      );
      expect((await repo.dashboardSummary())['kpis']['total_tests'], 0);
      expect(await repo.listSampleTests(), isEmpty);
      await expectLater(
        repo.updateSampleTest(id, resultText: '5'),
        throwsA(isA<NotFoundError>()),
      );
    },
  );

  test(
    'deleting after a partial consumption return restores only the remainder',
    () async {
      final saved = await run(result: labFailureResult, values: {'Titer': '3'});
      final id = (saved['test'] as Map)['id'] as int;
      expect(await quantity(variable), 47);
      await repo.updateSampleTest(id, dynamicValues: {'Titer': '1'});
      expect(await quantity(variable), 49);
      await repo.deleteSampleTest(id);
      expect(await quantity(fixed), 100);
      expect(await quantity(variable), 50);
      expect(
        await f.db.transaction(
          (txn) =>
              repo.reverseConsumptionToLots(txn, id, timestamp: '2026-11-03'),
        ),
        0,
      );
      expect(await quantity(variable), 50);
    },
  );

  test('invalid entered weights are rejected even in failure mode', () async {
    for (final bad in ['abc', '1.2.3', 'NaN', 'Infinity', '-2']) {
      await expectLater(
        run(result: labFailureResult, values: {'Weight': bad}),
        throwsA(isA<ValidationError>()),
      );
    }
    expect(await quantity(fixed), 100);
    expect(await f.db.query('lab_sample_tests'), isEmpty);
  });
  test(
    'changing a result to failure inside a transaction preserves consumption',
    () async {
      final saved = await run(
        values: {'Weight': '١٢٫٥', 'Volume': '٢٫٥', 'Titer': '1'},
      );
      expect((saved['test'] as Map)['result_text'], '5.000');
      final updated = await f.db
          .transaction(
            (txn) => repo.updateSampleTest(
              (saved['test'] as Map)['id'] as int,
              resultText: labFailureResult,
              dynamicValues: {'Weight': '12.5', 'Volume': '2.5', 'Titer': '1'},
              executor: txn,
            ),
          )
          .timeout(const Duration(seconds: 5));
      expect(updated['result_text'], labFailureResult);
      expect(await quantity(fixed), 98);
      expect(await quantity(variable), 49);
    },
  );
}
