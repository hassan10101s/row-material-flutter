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
  expect(raw['chemical_reference_json'],
      '{"Moisture":{"min":"0","max":"0.5"},"Ash":{"min":"0","max":"2"}}');

  // parameters seeded only for params that carry a unit
  final params = await _repo.listParameters();
  final moisture = params.firstWhere((p) => p['parameter_name'] == 'Moisture');
  expect(moisture['unit'], '%');
  expect(moisture['parameter_type'], 'chemical');

  // getMaterial enriches unit text onto chemical reference
  final enriched = await _repo.getMaterial(id);
  expect(enriched['chemical_reference']['Moisture']['unit'], '%');
  expect(enriched['chemical_reference']['Moisture']['value'], contains('"max":'));
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
      params2.firstWhere((p) => p['parameter_name'] == 'Purity')['unit'], '%');

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
      containsAll({'Moisture', 'Ash', 'Purity'}));

  // ── Duplicate name rejected on update ─────────────────────────────
  await _repo.createMaterial(
    materialName: 'Other',
    materialCode: 'M-OTHER-01',
  );
  await expectLater(
    _repo.updateMaterial(
      id,
      materialName: 'Other',
      materialCode: 'M-SUGAR-01',
    ),
    throwsA(isA<ValidationError>()),
  );

  // ── Soft delete semantics ─────────────────────────────────────────
  expect(await _repo.listMaterials(), hasLength(2));
  await _repo.deleteMaterial(id);
  expect(await _repo.listMaterials(), hasLength(1));
  final all = await _repo.listAllMaterials();
  expect(all.length, 2);
  expect(all.firstWhere((m) => m['id'] == id)['active'], 0,
      reason: 'listAllMaterials includes deleted rows');

  // ── Parameter/unit CRUD parity ────────────────────────────────────
  await _repo.upsertParameter('Color', 'abs',
      parameterType: 'physical');
  final physical = await _repo.listParameters(parameterType: 'physical');
  expect(physical.firstWhere((p) => p['parameter_name'] == 'Color')['unit'], '',
      reason: 'physical params are unit-less');

  await _repo.upsertUnit('%', name: 'Percent', dimension: 'ratio');
  final units = await _repo.listUnits();
  expect(units.firstWhere((u) => u['symbol'] == '%')['dimension'], 'ratio');
  await _repo.deleteUnit('%');
  expect(await _repo.listUnits(), isEmpty);

  await _repo.deleteParameter('Purity');
  expect(
      (await _repo.listParameters(parameterType: 'chemical'))
          .any((p) => p['parameter_name'] == 'Purity'),
      isFalse);
}