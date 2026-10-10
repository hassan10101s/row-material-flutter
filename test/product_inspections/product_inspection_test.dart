import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

import '../sync/sync_test_fixture.dart';

/// Product (batch) inspections: one `inspections` row per production batch
/// (`inspection_kind = 'product'`) with formula/batch numbers instead of
/// supplier/vehicle, reference from the product's analysis ranges, and the
/// same lab linkage as raw materials.
void main() {
  late SyncFixture fx;
  late InspectionRepo repo;
  late ReferenceRepo reference;
  late LabRepo lab;

  const admin = UserContext(id: 1, fullName: 'Tester', role: 'admin');

  Future<int> seedProduct() async {
    const ts = '2026-09-01T07:00:00.000';
    final productId = await fx.db.insert('lab_products', {
      'name': 'Protein 21%',
      'category': 'Feed',
      'description': '',
      'created_at': ts,
      'active': 1,
    });
    final analysisId = await fx.db.insert('lab_analyses', {
      'name': 'Protein',
      'unit': '%',
      'description': '',
      'dynamic_fields_json': '[]',
      'formula_json': '{}',
      'created_at': ts,
      'active': 1,
    });
    await fx.db.insert('lab_product_analyses', {
      'product_id': productId,
      'analysis_id': analysisId,
      'min_value': 20.0,
      'max_value': 22.0,
      'unit': '%',
    });
    return productId;
  }

  Map<String, dynamic> productPayload(int productId, String entryCode) =>
      <String, dynamic>{
        'inspection_kind': 'product',
        'product_id': productId,
        'formula_number': 'F-12',
        'batch_number': 'B-77',
        'entry_code': entryCode,
        'inspection_date': '2026-09-27',
        'quantity': '500',
        'sample_taken_by': 'taker name',
        'sample_names': ['Result'],
        'physical_results': <String, dynamic>{},
        'chemical_results': <String, dynamic>{'Protein': '21'},
        'decision_status': 'APPROVED',
      };

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();
    reference = ReferenceRepo(dbHelper: fx.helper);
    lab = LabRepo(dbHelper: fx.helper);
    repo = InspectionRepo(dbHelper: fx.helper, referenceRepo: reference);
  });

  tearDown(() async => fx.dispose());

  group('reference product context', () {
    test('lists products with minted codes and ranges', () async {
      final productId = await seedProduct();
      final products = await reference.listProductsForInspection();
      expect(products, hasLength(1));
      expect(products.first['id'], productId);
      expect('${products.first['product_code']}', isNotEmpty);
      expect((products.first['ranges'] as List), hasLength(1));
    });

    test('builds chemical reference from ranges + next entry code',
        () async {
      final productId = await seedProduct();
      final ctx = await reference.getProductForInspection(
        productId,
        inspectionDate: '2026-09-27',
      );
      expect(ctx['product_name'], 'Protein 21%');
      final chemical =
          Map<String, dynamic>.from(ctx['chemical_reference'] as Map);
      expect(chemical.keys, contains('Protein'));
      expect('${ctx['next_entry_code']}', contains('20260927'));
    });
  });

  group('product inspection records', () {
    test('creates a batch row with formula/batch and no supplier',
        () async {
      final productId = await seedProduct();
      final row =
          await repo.create(productPayload(productId, 'PPRO-20260927-001'), admin);
      expect(row['inspection_kind'], 'product');
      expect(row['product_id'], productId);
      expect(row['formula_number'], 'F-12');
      expect(row['batch_number'], 'B-77');
      expect(row['supplier'], isEmpty);
      expect(row['material_name'], 'Protein 21%');
      final chemical =
          Map<String, dynamic>.from(row['chemical_results'] as Map);
      expect('${chemical['Protein']}', '21');
    });

    test('mints an entry code from the product code when blank', () async {
      final productId = await seedProduct();
      final payload = productPayload(productId, '');
      final row = await repo.create(payload, admin);
      expect('${row['entry_code']}', contains('20260927'));
    });

    test('rejects a missing formula or batch number', () async {
      final productId = await seedProduct();
      final noFormula = productPayload(productId, 'PPRO-20260927-010')
        ..['formula_number'] = '';
      expect(
        () => repo.create(noFormula, admin),
        throwsA(isA<ValidationError>()),
      );
      final noBatch = productPayload(productId, 'PPRO-20260927-011')
        ..['batch_number'] = '  ';
      expect(
        () => repo.create(noBatch, admin),
        throwsA(isA<ValidationError>()),
      );
    });

    test('raw and product registers stay separated', () async {
      final productId = await seedProduct();
      await repo.create(productPayload(productId, 'PPRO-20260927-001'), admin);
      await repo.create(<String, dynamic>{
        'material_id': 1,
        'entry_code': 'M-CEM-01-20260927-001',
        'inspection_date': '2026-09-27',
        'supplier': 'supplier xyz',
        'quantity': '10',
        'sample_taken_by': 'taker name',
        'sample_names': ['Result'],
        'physical_results': <String, dynamic>{},
        'chemical_results': <String, dynamic>{},
        'decision_status': 'APPROVED',
      }, admin);

      final raw = await repo.list(kind: 'raw');
      final products = await repo.list(kind: 'product');
      expect(raw, hasLength(1));
      expect(products, hasLength(1));
      expect(await repo.count(kind: 'raw'), 1);
      expect(await repo.count(kind: 'product'), 1);
      // Search matches formula/batch numbers.
      final found = await repo.list(query: 'B-77', kind: 'product');
      expect(found, hasLength(1));
    });

    test('updates formula/batch and records decisions', () async {
      final productId = await seedProduct();
      final created =
          await repo.create(productPayload(productId, 'PPRO-20260927-001'), admin);
      final id = created['id'] as int;
      final updated = await repo.update(id, {
        'formula_number': 'F-13',
        'batch_number': 'B-78',
      }, admin);
      expect(updated['formula_number'], 'F-13');
      expect(updated['batch_number'], 'B-78');

      final decided = await repo.updateStatus(id, {
        'decision_status': 'FULL_REJECTION',
        'decision_reason': 'protein below range',
      }, admin);
      expect(decided['decision_status'], 'FULL_REJECTION');
      expect(decided['inspection_kind'], 'product');
    });
  });

  group('lab linkage', () {
    test('product records resolve for run-test pickers', () async {
      final productId = await seedProduct();
      await repo.create(productPayload(productId, 'PPRO-20260927-001'), admin);

      final materials = await lab.listProductInspectionMaterials();
      expect(materials, hasLength(1));

      final records = await lab.listProductInspectionRecords(productId);
      expect(records, hasLength(1));
      expect(records.first['batch_number'], 'B-77');
      expect(records.first['sample_names'], contains('Result'));

      // Raw pickers stay empty: the batch must not leak into them.
      expect(await lab.listInspectionMaterials(), isEmpty);
      expect(await lab.listInspectionRecords(1), isEmpty);

      final resolved = await lab.resolveInspection('PPRO-20260927-001');
      expect(resolved!['inspection_kind'], 'product');
      expect(resolved['product_id'], productId);
    });

    test('running a test against the batch entry code links + range-checks',
        () async {
      final productId = await seedProduct();
      await repo.create(productPayload(productId, 'PPRO-20260927-001'), admin);
      final analyses = await lab.listAnalyses();
      final analysisId = (analyses
              .firstWhere((a) => '${a['name']}' == 'Protein')['id'] as num)
          .toInt();

      final result = await lab.runSampleTest(
        analysisId: analysisId,
        sourceType: 'product',
        sourceRefId: productId,
        sourceName: 'Protein 21%',
        sampleName: 'Result',
        resultText: '21',
        dynamicValues: const {},
        entryCode: 'PPRO-20260927-001',
      );
      final test = Map<String, dynamic>.from(result['test'] as Map);
      expect(test['entry_code'], 'PPRO-20260927-001');
      final range = result['range_check'] as Map?;
      expect(range, isNotNull);
      expect(range!['out_of_range'], isFalse);

      final linked =
          await lab.listSampleTestsForEntryCode('PPRO-20260927-001');
      expect(linked, hasLength(1));
    });
  });
}
