import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/lab/core/formula_engine.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import '../sync/sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('inline metadata normalizes choices, keeps only link markers and round-trips idempotently', () {
    final formula = normalizeFormulaValue({'expression': 'A+B', 'field_configs': [
      {'dynamic_field': ' A ', 'kind': 'value', 'fixed_value': '2.5'},
      {'dynamic_field': 'B', 'kind': 'list', 'list_values': [1, '2', 'bad']},
      {'dynamic_field': 'C', 'kind': 'link', 'inventory_id': 987},
    ]});
    expect(normalizeFormulaValue(formula), formula);
    final configs = formula['field_configs'] as List;
    expect(configs[0]['dynamic_field'], 'A');
    expect(configs[1]['list_values'], [1.0, 2.0]);
    expect(configs[2], {'dynamic_field': 'C', 'kind': 'link'});
  });
  test('packed settings replace old choices without activating unrelated old chemical rows', () {
    final analysis = {'id': 1, 'formula': normalizeFormulaValue({'field_configs': [
      {'dynamic_field': 'A', 'kind': 'value', 'fixed_value': 4},
      {'dynamic_field': 'C', 'kind': 'link'},
    ]})};
    final links = mergeAnalysisFieldConfigurations(analysis, [
      {'id': 9, 'dynamic_field': 'A', 'kind': 'list', 'list_values': [999]},
      {'id': 10, 'dynamic_field': 'C', 'kind': 'link', 'inventory_id': 7},
      {'id': 11, 'dynamic_field': 'Removed', 'kind': 'link', 'inventory_id': 8},
    ]);
    expect(links, hasLength(2));
    expect(links.first['fixed_value'], 4.0);
    expect(links.last['id'], 10);
    expect(links.last['inventory_id'], 7);
  });
  test('empty packed settings explicitly clear the active configuration; legacy rows stay compatible', () {
    final legacy = [{'dynamic_field': 'C', 'kind': 'link', 'inventory_id': 7}];
    expect(mergeAnalysisFieldConfigurations({'id': 1, 'formula': {}}, legacy), legacy);
    expect(mergeAnalysisFieldConfigurations({'id': 1, 'formula': {'field_configs': []}}, legacy), isEmpty);
  });
  test('all analysis read paths and formula evaluation use inline values, and formula edits retain them', () async {
    final f = await openSyncFixture();
    try {
      final repo = LabRepo(dbHelper: f.helper);
      final created = await repo.createAnalysis(name: 'Inline calculation', dynamicFields: ['A', 'B'], formula: {
        'expression': 'A+B', 'field_configs': [
          {'dynamic_field': 'A', 'kind': 'value', 'fixed_value': 2.5},
          {'dynamic_field': 'B', 'kind': 'list', 'list_values': [1, 2]},
        ],
      });
      final id = created['id'] as int;
      final batch = await repo.batchLoadAnalyses(null, {id});
      expect(batch[id]!['field_chemical_links'], created['field_chemical_links']);
      expect((await repo.getFieldChemicalLinks(id)), created['field_chemical_links']);
      expect((await repo.listAnalyses()).single['field_chemical_links'], created['field_chemical_links']);
      final result = await repo.runSampleTest(analysisId: id, sourceType: 'sample', sourceName: 'Standalone',
        sampleName: 'S1', dynamicValues: {'B': 2}, user: null);
      expect((result['test'] as Map)['result_text'], '4.500');
      await repo.updateAnalysis(analysisId: id, formula: 'A*B');
      expect((await repo.getAnalysis(id))['field_chemical_links'], created['field_chemical_links']);
      await repo.updateAnalysis(analysisId: id, formula: '');
      final cleared = await repo.getAnalysis(id);
      expect((cleared['formula'] as Map)['expression'], isNull);
      expect(cleared['field_chemical_links'], created['field_chemical_links']);
    } finally { await f.dispose(); }
  });
}
