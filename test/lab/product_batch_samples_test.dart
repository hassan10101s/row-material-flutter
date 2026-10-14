import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';

import '../sync/sync_test_fixture.dart';

/// Product batch samples (محضر التشغيلة rows):
/// - samples append under a product inspection (the batch header),
/// - each sample carries its own taker + physical map + multiple chemical
///   rows on its row, independent of lab chemistry,
/// - per-sample decisions, soft-delete, legacy product-scoped cleanup,
/// - `runSampleTest(keepSourceRefId: true)` keeps the sample scope
///   (default path still resolves to the product id),
/// - raw-material rows are never touched.
void main() {
  late SyncFixture fx;
  late LabRepo repo;
  late int batchId;
  late int rawId;
  late int productId;
  late int analysisId;

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();
    repo = LabRepo(dbHelper: fx.helper);

    productId = await fx.db.rawInsert(
      "INSERT INTO lab_products (name, category, description, created_at) "
      "VALUES ('Flour 50T', 'Food', '', 'x')",
    );
    analysisId = await fx.db.rawInsert(
      "INSERT INTO lab_analyses (name, unit, created_at) "
      "VALUES ('Protein', '%', 'x')",
    );
    batchId = await fx.db.rawInsert(
      'INSERT INTO inspections (entry_code, material_id, material_name, '
      'material_code, inspection_date, specialist_name, '
      'physical_results_json, chemical_results_json, '
      'physical_reference_json, chemical_reference_json, decision_status, '
      'snapshot_json, sample_names_json, decision_version, created_by, '
      'created_by_name, created_at, updated_at, inspection_kind, '
      'product_id, batch_number, quantity) '
      "VALUES ('BATCH-50T', 1, 'Flour 50T', 'PFLO', '2026-01-01', 'QC', "
      "'{}', '{}', '{}', '{}', '', '{}', '[]', 1, 1, 'Ahmed Ali', 'x', 'x', "
      "'product', ?, 'LOT-7', '50 tons')",
      [productId],
    );
    rawId = await fx.db.rawInsert(
      'INSERT INTO inspections (entry_code, material_id, material_name, '
      'material_code, inspection_date, specialist_name, '
      'physical_results_json, chemical_results_json, '
      'physical_reference_json, chemical_reference_json, decision_status, '
      'snapshot_json, sample_names_json, decision_version, created_by, '
      'created_by_name, created_at, updated_at, inspection_kind, quantity) '
      "VALUES ('RAW-001', 1, 'Cement', 'M-CEM-01', '2026-01-01', 'QC', "
      "'{}', '{}', '{}', '{}', 'APPROVED', '{}', '[]', 1, 1, 'Ahmed Ali', "
      "'x', 'x', 'raw', '10 tons')",
    );
  });

  tearDown(() async {
    await fx.dispose();
  });

  test('samples append with auto numbering + tester attribution', () async {
    final s1 = await repo.addBatchSample(batchId: batchId);
    final s2 = await repo.addBatchSample(
      batchId: batchId,
      sampleName: 'Edge',
      user: {'id': 1},
    );
    expect(s1['sample_no'], 1);
    expect(s1['sample_name'], 'Sample 1');
    expect(s2['sample_no'], 2);

    final rows = await repo.listBatchSamples(batchId);
    expect(rows, hasLength(2));
    expect(rows[1]['tested_by_name_resolved'], 'Ahmed Ali');
  });

  test('duplicate sample_no in one batch is rejected', () async {
    await repo.addBatchSample(batchId: batchId);
    expect(
      () => fx.db.rawInsert(
        'INSERT INTO product_batch_samples (batch_id, sample_no, '
        'sample_name, tested_at, created_at) VALUES (?, ?, ?, ?, ?)',
        [batchId, 1, 'Dup', 'x', 'x'],
      ),
      throwsA(anything),
    );
  });

  test('adding to a raw inspection is rejected', () async {
    expect(() => repo.addBatchSample(batchId: rawId), throwsA(isA<AppError>()));
  });

  test('sample taker + own results round-trip (lab untouched)', () async {
    final s = await repo.addBatchSample(
      batchId: batchId,
      sampleName: 'S1',
      sampleTaker: 'Karim',
      physicalResults: {'اللون': 'أبيض'},
      chemicalResults: [
        {'name': 'Protein', 'result': '12.5', 'unit': '%'},
        {'name': 'Moisture', 'result': '13', 'unit': '%'},
      ],
    );
    expect(s['sample_taker'], 'Karim');
    final rows = await repo.listBatchSamples(batchId);
    expect(rows.single['sample_taker'], 'Karim');
    expect(rows.single['physical_results_json'], contains('اللون'));
    expect(rows.single['chemical_results_json'], contains('Protein'));
    // Nothing flowed into the lab pipeline.
    expect(await fx.db.query('lab_sample_tests'), isEmpty);
  });

  test('updateBatchSample edits identity + own results', () async {
    final s = await repo.addBatchSample(batchId: batchId);
    final id = (s['id'] as num).toInt();
    await repo.updateBatchSample(
      id,
      sampleName: 'S1-edited',
      sampleTaker: 'Mona',
      physicalResults: {'القوام': 'ناعم'},
      chemicalResults: [
        {'name': 'Protein', 'result': '11', 'unit': '%'},
      ],
    );
    final rows = await repo.listBatchSamples(batchId);
    expect(rows.single['sample_name'], 'S1-edited');
    expect(rows.single['sample_taker'], 'Mona');
    expect(rows.single['physical_results_json'], contains('القوام'));
    expect(rows.single['chemical_results_json'], contains('11'));
  });

  test('per-sample decision round-trips', () async {
    final s = await repo.addBatchSample(batchId: batchId);
    final id = (s['id'] as num).toInt();
    await repo.setBatchSampleDecision(
      id,
      status: 'APPROVED',
      reason: 'in range',
    );
    final rows = await repo.listBatchSamples(batchId);
    expect(rows.single['decision_status'], 'APPROVED');
    expect(rows.single['decision_reason'], 'in range');
  });

  test('sample results resolve tester names (بواسطة من)', () async {
    final s = await repo.addBatchSample(batchId: batchId);
    final id = (s['id'] as num).toInt();
    await fx.db.rawInsert(
      'INSERT INTO lab_sample_tests (analysis_id, source_type, '
      'source_ref_id, source_name, sample_name, result_text, tested_by, '
      'tested_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [analysisId, 'product', id, 'Flour 50T', 'Sample 1', '12.5', 1, 'x'],
    );
    final res = await repo.listSampleResults(id);
    expect(res, hasLength(1));
    expect(res.first['analysis_name'], 'Protein');
    expect(res.first['tested_by_name'], 'Ahmed Ali');
  });

  test('keepSourceRefId keeps the sample scope', () async {
    final s = await repo.addBatchSample(batchId: batchId);
    final id = (s['id'] as num).toInt();
    final out = await repo.runSampleTest(
      analysisId: analysisId,
      sourceType: 'product',
      sourceRefId: id,
      sourceName: 'Flour 50T',
      sampleName: 'Sample 1',
      resultText: '12.5',
      user: {'id': 1},
      entryCode: 'BATCH-50T',
      keepSourceRefId: true,
    );
    final test = out['test'] as Map<String, dynamic>;
    expect((test['source_ref_id'] as num).toInt(), id);

    // Default path still resolves to the product id (raw + old flows).
    final out2 = await repo.runSampleTest(
      analysisId: analysisId,
      sourceType: 'product',
      sourceRefId: id,
      sourceName: 'Flour 50T',
      sampleName: 'Sample 1',
      resultText: '12.6',
      user: {'id': 1},
      entryCode: 'BATCH-50T',
    );
    final test2 = out2['test'] as Map<String, dynamic>;
    expect((test2['source_ref_id'] as num).toInt(), productId);
  });

  test('delete removes sample from list + drops its tests only', () async {
    final s = await repo.addBatchSample(batchId: batchId);
    final id = (s['id'] as num).toInt();
    await fx.db.rawInsert(
      'INSERT INTO lab_sample_tests (analysis_id, source_type, '
      'source_ref_id, source_name, sample_name, result_text, tested_at, '
      'entry_code) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        analysisId,
        'product',
        id,
        'Flour 50T',
        'Sample 1',
        '12.5',
        'x',
        'BATCH-50T',
      ],
    );
    // A raw result that must survive.
    await fx.db.rawInsert(
      'INSERT INTO lab_sample_tests (analysis_id, source_type, '
      'source_ref_id, source_name, sample_name, result_text, tested_at, '
      'entry_code) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [analysisId, 'raw_material', 1, 'Cement', 'R1', '9.0', 'x', 'RAW-001'],
    );

    await repo.deleteBatchSample(id);
    expect(await repo.listBatchSamples(batchId), isEmpty);
    final left = await fx.db.query('lab_sample_tests');
    expect(left, hasLength(1));
    expect(left.single['entry_code'], 'RAW-001');

    // Raw header untouched.
    final raw = await fx.db.query(
      'inspections',
      where: 'id = ?',
      whereArgs: [rawId],
    );
    expect(raw.single['decision_status'], 'APPROVED');
  });
}
