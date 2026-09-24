import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';

/// AppPaths override that avoids path_provider (tests run headless).
class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();
  final tmp = Directory.systemTemp.createTempSync('matlab_field_config');
  late DatabaseHelper dbHelper;
  late LabRepo repo;
  late int inventoryId;
  late int analysisId;

  setUpAll(() async {
    dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
    await dbHelper.database;
    repo = LabRepo(dbHelper: dbHelper);

    final db = await dbHelper.database;
    final ts = nowIso();
    inventoryId = await db.insert('lab_inventory', {
      'name': 'Reagent X',
      'category': 'liquid',
      'unit': 'mL',
      'current_qty': 100,
      'min_qty': 5,
      'created_at': ts,
      'updated_at': ts,
    });
    analysisId = await db.insert('lab_analyses', {
      'name': 'Titration',
      'unit': '%',
      'description': 'three-mode fields',
      'dynamic_fields_json': '["V","C","L"]',
      'formula_json': '{"expression":"V * C"}',
      'created_at': ts,
    });
    await repo.saveFieldChemicalLinks(analysisId, [
      {
        'dynamic_field': 'V',
        'kind': 'value',
        'inventory_id': 0,
        'fixed_value': 2.5,
      },
      {
        'dynamic_field': 'C',
        'kind': 'list',
        'inventory_id': 0,
        'list_values': [1, 2, 4],
      },
      {
        'dynamic_field': 'L',
        'kind': 'link',
        'inventory_id': inventoryId,
        'unit': 'mL',
      },
    ]);
  });

  test('getFieldChemicalLinks round-trips the three kinds', () async {
    final links = await repo.getFieldChemicalLinks(analysisId);
    final byField = {for (final l in links) '${l['dynamic_field']}': l};
    expect(byField['V']!['kind'], 'value');
    expect(byField['V']!['fixed_value'], 2.5);
    expect(byField['C']!['kind'], 'list');
    expect(byField['C']!['list_values'], [1, 2, 4]);
    expect(byField['L']!['kind'], 'link');
    expect(byField['L']!['inventory_name'], 'Reagent X');
    expect(byField['L']!['inventory_unit'], 'mL');
  });

  test('getAnalysis and batchLoadAnalyses decode kinds', () async {
    final a = await repo.getAnalysis(analysisId);
    final links = (a['field_chemical_links'] as List)
        .cast<Map<String, dynamic>>();
    final byField = {for (final l in links) '${l['dynamic_field']}': l};
    expect(a['dynamic_fields'], ['V', 'C', 'L']);
    expect(byField['V']!['fixed_value'], 2.5);
    expect(byField['C']!['list_values'], [1, 2, 4]);

    final batch = await repo.batchLoadAnalyses(null, {analysisId});
    final blinks = (batch[analysisId]!['field_chemical_links'] as List)
        .cast<Map<String, dynamic>>();
    final bByField = {for (final l in blinks) '${l['dynamic_field']}': l};
    expect(bByField['C']!['list_values'], [1, 2, 4]);
  });

  test('runSampleTest injects fixed value, uses list selection, skips non-link consumption', () async {
    final result = await repo.runSampleTest(
      analysisId: analysisId,
      sourceType: 'product',
      sourceName: 'Product P',
      sampleName: 'Sample S',
      dynamicValues: {'C': '2', 'L': '3'},
      user: null,
    );
    final testRow = result['test'] as Map;
    expect(testRow['result_text'], '5.0',
        reason: 'fixed V=2.5 × selected C=2');
    final consumption =
        (result['consumption'] as List).cast<Map<String, dynamic>>();
    expect(consumption, hasLength(1),
        reason: 'only the link field consumes inventory');
    expect('${consumption.first['inventory_name']}', 'Reagent X');
    expect(consumption.first['qty_used'], 3.0);
  });

  group('legacy schema migration', () {
    final tmp = Directory.systemTemp.createTempSync('matlab_legacy_mig');
    late DatabaseHelper helper;
    late LabRepo repo;
    late int invId;
    late int analysisId;

    setUpAll(() async {
      helper = DatabaseHelper(_FakeAppPaths(tmp.path));
      await helper.database;
      repo = LabRepo(dbHelper: helper);
      final db = await helper.database;
      final ts = nowIso();
      invId = await db.insert('lab_inventory', {
        'name': 'Reagent Legacy',
        'category': 'liquid',
        'unit': 'mL',
        'current_qty': 50,
        'min_qty': 5,
        'created_at': ts,
        'updated_at': ts,
      });
      analysisId = await db.insert('lab_analyses', {
        'name': 'Old Analysis',
        'unit': '%',
        'description': 'pre-3-mode schema',
        'dynamic_fields_json': '["V","C","L"]',
        'formula_json': '{"expression":"C"}',
        'created_at': ts,
      });
      // Downgrade the links table to the pre-3-mode schema (NOT NULL FK,
      // no kind/fixed_value/list_values columns) and seed a legacy row.
      await db.execute('DROP TABLE lab_field_chemical_links');
      await db.execute('''
        CREATE TABLE lab_field_chemical_links (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          analysis_id INTEGER NOT NULL REFERENCES lab_analyses(id) ON DELETE CASCADE,
          dynamic_field TEXT NOT NULL,
          inventory_id INTEGER NOT NULL REFERENCES lab_inventory(id),
          unit TEXT NOT NULL DEFAULT 'mL',
          created_at TEXT NOT NULL,
          UNIQUE(analysis_id, dynamic_field)
        )
      ''');
      await db.insert('lab_field_chemical_links', {
        'analysis_id': analysisId,
        'dynamic_field': 'L',
        'inventory_id': invId,
        'unit': 'mL',
        'created_at': ts,
      });
    });

    test('existing legacy DB gets kind columns on open and saves all kinds',
        () async {
      await helper.close();
      helper = DatabaseHelper(_FakeAppPaths(tmp.path));
      await helper.database;
      repo = LabRepo(dbHelper: helper);
      final db = await helper.database;

      final cols =
          await db.rawQuery('PRAGMA table_info(lab_field_chemical_links)');
      final names = cols.map((c) => c['name']).toSet();
      expect(names.contains('kind'), isTrue,
          reason: 'legacy DB must be migrated on plain open');
      expect(names.contains('fixed_value'), isTrue);
      expect(names.contains('list_values'), isTrue);

      final legacy = await db.query('lab_field_chemical_links',
          where: 'dynamic_field = ?', whereArgs: ['L']);
      expect(legacy, hasLength(1),
          reason: 'legacy rows survive the rebuild');
      expect(legacy.single['kind'], 'link');

      await repo.saveFieldChemicalLinks(analysisId, [
        {
          'dynamic_field': 'V',
          'kind': 'value',
          'inventory_id': 0,
          'fixed_value': 1.5,
        },
        {
          'dynamic_field': 'C',
          'kind': 'list',
          'inventory_id': 0,
          'list_values': [1, 2, 4],
        },
        {
          'dynamic_field': 'L',
          'kind': 'link',
          'inventory_id': invId,
          'unit': 'mL',
        },
      ]);
      final links = await repo.getFieldChemicalLinks(analysisId);
      final byField = {for (final l in links) '${l['dynamic_field']}': l};
      expect(byField['V']!['fixed_value'], 1.5);
      expect(byField['C']!['list_values'], [1, 2, 4]);
      expect(byField['L']!['inventory_name'], 'Reagent Legacy');
    });
  });
}