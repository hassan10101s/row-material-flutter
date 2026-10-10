import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

/// AppPaths override that avoids path_provider (tests run headless).
class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

late DatabaseHelper _dbHelper;
late ReferenceRepo _repo;
late LabRepo _lab;

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();
  final tmp = await Directory.systemTemp.createTemp('matlab_ref_repo');
  _dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
  await _dbHelper.database;
  _repo = ReferenceRepo(dbHelper: _dbHelper);
  _lab = LabRepo(dbHelper: _dbHelper);

  final db = await _dbHelper.database;
  await db.insert('lab_analyses', {
    'name': 'Moisture',
    'unit': '%',
    'description': 'Moisture content',
    'created_at': nowIso(),
  });
  await db.insert('lab_analyses', {
    'name': 'Ash',
    'unit': '%',
    'description': 'Ash content',
    'created_at': nowIso(),
  });

  test('reference repo save flow', () async {
    await _run();
  });
}

Future<void> _run() async {
  // ── Create: JSON refs + units -> parameters upsert ───────────────
  final id = await _repo.createMaterial(
    materialName: 'Sugar  EN | AR',
    materialCode: 'M-SUGAR-01',
    physicalReference: {'Granulation': 'fine'},
    chemicalReference: {
      'Moisture': {'min': '0', 'max': '0.5'},
      'Ash': {'min': '0', 'max': '2'},
    },
    units: {'Moisture': '%', 'Ash': '%'},
  );
  expect(id, greaterThan(0));

  final raw = await _repo.getMaterialRaw(id);
  expect(raw!['material_name'], 'Sugar  EN | AR');
  expect(raw['active'], 1);
  expect(raw['physical_reference_json'], '{"Granulation":"fine"}');
  expect(
    raw['chemical_reference_json'],
    '{"Moisture":{"min":"0","max":"0.5"},"Ash":{"min":"0","max":"2"}}',
  );

  // parameters seeded only for params that carry a unit
  final params = await _repo.listParameters();
  final moisture = params.firstWhere((p) => p['parameter_name'] == 'Moisture');
  expect(moisture['unit'], '%');
  expect(moisture['parameter_type'], 'chemical');

  // getMaterial enriches unit text onto chemical reference
  final enriched = await _repo.getMaterial(id);
  expect(enriched['chemical_reference']['Moisture']['unit'], '%');
  expect(
    enriched['chemical_reference']['Moisture']['value'],
    contains('"max":'),
  );
  expect(enriched['physical_reference']['Granulation'], 'fine');

  // entry code generated from material code + date
  expect(enriched['next_entry_code'], startsWith('M-SUGAR-01-'));

  // ── Editor save path: updateMaterial + saveMaterialBounds ──────────
  await _repo.updateMaterial(
    id,
    materialName: 'Refined Sugar EN | AR',
    materialCode: 'M-SUGAR-01',
    chemicalReference: {
      'Moisture': {'min': '0', 'max': '0.4'},
      'Ash': {'min': '0', 'max': '1.5'},
      'Purity': {'min': '98', 'max': '100'},
    },
    units: {'Moisture': '%', 'Purity': '%'},
  );
  final saved = await _lab.saveMaterialBounds(id, [
    {
      'parameter_name': 'Moisture',
      'parameter_type': 'chemical',
      'unit': '%',
      'min_value': '0',
      'max_value': '0.4',
    },
    {
      'parameter_name': 'Ash',
      'parameter_type': 'chemical',
      'unit': '%',
      'min_value': '0',
      'max_value': '1.5',
    },
    {
      'parameter_name': 'Purity',
      'parameter_type': 'chemical',
      'unit': '%',
      'min_value': '98',
      'max_value': '100',
    },
  ]);
  expect(saved['saved'], 3);

  final updatedRaw = await _repo.getMaterialRaw(id);
  expect(updatedRaw!['material_name'], 'Refined Sugar EN | AR');
  expect(updatedRaw['active'], 1, reason: 'update reactivates material');

  final params2 = await _repo.listParameters(parameterType: 'chemical');
  expect(params2.any((p) => p['parameter_name'] == 'Purity'), isTrue);
  expect(
    params2.firstWhere((p) => p['parameter_name'] == 'Purity')['unit'],
    '%',
  );

  // Bounds are persisted per parameter and resolved through the reference.
  final analyses = await _lab.getMaterialAnalyses(id);
  final chemFields = ((analyses['chemical']?['fields']) as List)
      .cast<Map<String, dynamic>>();
  final purity = chemFields.firstWhere((f) => f['parameter_name'] == 'Purity');
  expect(purity['min'], 98);
  expect(purity['max'], 100);
  expect(purity['unit'], '%');
  expect(
    chemFields.map((f) => f['parameter_name']).toSet(),
    containsAll({'Moisture', 'Ash', 'Purity'}),
  );

  await _repo.upsertParameter(
    'Bulk Density',
    'g/cm3',
    parameterType: 'physical',
  );
  final bulkDensity = (await _repo.listParameters(
    parameterType: 'physical',
  )).firstWhere((p) => p['parameter_name'] == 'Bulk Density');
  final physicalMaterialId = await _repo.createMaterial(
    materialName: 'Physical reference material',
    materialCode: 'M-PHYSICAL-01',
    physicalReference: {
      'Bulk Density': {'value': '0.5-0.8', 'unit': 'g/cm3'},
    },
  );
  await _lab.saveMaterialBounds(physicalMaterialId, [
    {
      'parameter_name': 'Bulk Density',
      'parameter_type': 'physical',
      'unit': 'g/cm3',
      'min_value': '0.5',
      'max_value': '0.8',
    },
  ]);
  final physicalReference = await _repo.getMaterial(physicalMaterialId);
  expect(
    physicalReference['physical_reference']['Bulk Density']['unit'],
    'g/cm3',
  );
  final physicalAnalyses = await _lab.getMaterialAnalyses(physicalMaterialId);
  final physicalFields = ((physicalAnalyses['physical']?['fields']) as List)
      .cast<Map<String, dynamic>>();
  expect(physicalFields.single['unit'], 'g/cm3');

  final linkedAnalysis = (await _lab.listAnalyses()).firstWhere(
    (analysis) => analysis['parameter_id'] == bulkDensity['id'],
  );
  final product = await _lab.createProduct(
    name: 'Bulk Density Product',
    ranges: [
      {
        'analysis_id': linkedAnalysis['id'],
        'min_value': 0.5,
        'max_value': 0.8,
        'unit': 'legacy-unit',
      },
    ],
  );
  final productId = int.parse('${product['id']}');
  expect(
    (await _lab.getProductRanges(productId)).single['unit'],
    'g/cm3',
    reason: 'product ranges inherit the linked analysis unit',
  );

  await _repo.upsertParameter(
    'Bulk Density',
    'kg/m3',
    parameterType: 'physical',
  );
  final canonicalAnalysis = await _lab.getAnalysis(
    int.parse('${linkedAnalysis['id']}'),
  );
  expect(canonicalAnalysis['parameter_id'], bulkDensity['id']);
  expect(canonicalAnalysis['unit'], 'kg/m3');
  final canonicalPhysical = await _lab.getMaterialAnalyses(physicalMaterialId);
  expect(
    ((canonicalPhysical['physical']?['fields']) as List).single['unit'],
    'kg/m3',
  );
  expect((await _lab.getProductRanges(productId)).single['unit'], 'kg/m3');

  // ── Duplicate name rejected on update ─────────────────────────────
  await _repo.createMaterial(materialName: 'Other', materialCode: 'M-OTHER-01');
  await expectLater(
    _repo.updateMaterial(id, materialName: 'Other', materialCode: 'M-SUGAR-01'),
    throwsA(isA<ValidationError>()),
  );

  // ── Soft delete semantics ─────────────────────────────────────────
  expect(await _repo.listMaterials(), hasLength(3));
  await _repo.deleteMaterial(id);
  expect(await _repo.listMaterials(), hasLength(2));
  final all = await _repo.listAllMaterials();
  expect(all.length, 3);
  expect(
    all.firstWhere((m) => m['id'] == id)['active'],
    0,
    reason: 'listAllMaterials includes deleted rows',
  );

  // ── Parameter/unit CRUD parity ────────────────────────────────────
  await _repo.upsertParameter('Color', 'abs', parameterType: 'physical');
  final physical = await _repo.listParameters(parameterType: 'physical');
  expect(
    physical.firstWhere((p) => p['parameter_name'] == 'Color')['unit'],
    'abs',
    reason: 'physical parameters inherit their reference unit',
  );

  // The units registry is pre-seeded with defaults on every open, so the
  // parity check uses a dedicated symbol and asserts only its own lifecycle.
  await _repo.upsertUnit('T-UNIT', name: 'Test Unit', dimension: 'test-dim');
  final units = await _repo.listUnits();
  expect(
    units.firstWhere((u) => u['symbol'] == 'T-UNIT')['dimension'],
    'test-dim',
  );
  await _repo.deleteUnit('T-UNIT');
  expect(
    (await _repo.listUnits()).any((u) => u['symbol'] == 'T-UNIT'),
    isFalse,
  );

  await _repo.deleteParameter('Purity');
  expect(
    (await _repo.listParameters(
      parameterType: 'chemical',
    )).any((p) => p['parameter_name'] == 'Purity'),
    isFalse,
  );

  // ── Device-scoped entry codes (two-device collision guard) ──────────
  // Without a provider the legacy global-per-day sequence is kept.
  final legacy =
      await _repo.generateEntryCode('M-SUGAR-01', '2026-09-01');
  expect(legacy, 'M-SUGAR-01-20260901-001');

  // With a provider the sequence is scoped per device: two offline devices
  // mint disjoint code spaces, so their rows can never share a sync
  // document id (which IS the entry code).
  final devA = ReferenceRepo(
    dbHelper: _dbHelper,
    deviceTagProvider: () async => 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
  );
  final devB = ReferenceRepo(
    dbHelper: _dbHelper,
    deviceTagProvider: () async => 'ffffffff-ffff-ffff-ffff-ffffffffffff',
  );
  final codeA = await devA.generateEntryCode('M-SUGAR-01', '2026-09-01');
  final codeB = await devB.generateEntryCode('M-SUGAR-01', '2026-09-01');
  expect(codeA, 'M-SUGAR-01-20260901-A1B2C3-001');
  expect(codeB, 'M-SUGAR-01-20260901-FFFFFF-001');
  expect(codeA, isNot(codeB));

  // A failing/empty provider degrades to the legacy format, never throws.
  final flaky = ReferenceRepo(
    dbHelper: _dbHelper,
    deviceTagProvider: () async => throw StateError('no id yet'),
  );
  expect(
    await flaky.generateEntryCode('M-SUGAR-01', '2026-09-01'),
    'M-SUGAR-01-20260901-001',
  );
}
