import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sqflite/sqflite.dart';

import '../constants/app_errors.dart';
import '../database/database_helper.dart';
import '../utils/app_dates.dart';
import '../utils/app_exceptions.dart';
import '../utils/app_format.dart';

/// First-run seed service (port of ReferenceService.ensure_initial_import /
/// import_reference / import_units).
class SeedService {
  final DatabaseHelper dbHelper;

  SeedService({required this.dbHelper});

  static const String _referenceAsset = 'assets/Reference.xlsx';
  static const String _unitsAsset = 'assets/units.xlsx';
  static const Set<String> _requiredColumns = {
    'Raw_Material_Name',
    'Physical_Aspects_Reference',
    'Chemical_Analysis_Reference',
    'code',
  };

  Future<bool> isSeedDone() async {
    final db = await dbHelper.database;
    final rows = await db
        .query('settings', where: 'key = ?', whereArgs: ['reference_seed_done']);
    return rows.isNotEmpty && '${rows.first['value']}' == '1';
  }

  Future<void> _markSeedDone() async {
    final db = await dbHelper.database;
    await db.insert('settings', {'key': 'reference_seed_done', 'value': '1'},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<List<dynamic>>> _readSheet(
      ByteData bytes, String label) async {
    final excel = Excel.decodeBytes(bytes.buffer.asUint8List());
    if (excel.tables.isEmpty) {
      throw ValidationError(AppErrors.seedNoWorksheet(label));
    }
    final table = excel.tables.values.first;
    final rows = table.rows;
    final result = <List<dynamic>>[];
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final values = <dynamic>[];
      for (final cell in row) {
        values.add(cell?.value);
      }
      result.add(values);
    }
    return result;
  }

  Future<int> importReference() async {
    final db = await dbHelper.database;
    final bytes = await rootBundle.load(_referenceAsset);
    final sheet = await _readSheet(bytes, 'Reference.xlsx');
    if (sheet.isEmpty) return 0;
    final headers = [
      for (final v in sheet.first) '${v ?? ''}'.trim(),
    ];
    final missing = _requiredColumns.difference(headers.toSet());
    if (missing.isNotEmpty) {
      throw ValidationError(AppErrors.seedMissingColumns(missing.join(', ')));
    }
    final headerMap = {for (var i = 0; i < headers.length; i++) headers[i]: i};
    final timestamp = nowIso();
    var count = 0;
    for (var i = 1; i < sheet.length; i++) {
      final row = sheet[i];
      final materialName = '${_at(row, headerMap['Raw_Material_Name']) ?? ''}'.trim();
      if (materialName.isEmpty) continue;
      final materialCode = '${_at(row, headerMap['code']) ?? ''}'.trim();
      final physicalRaw = '${_at(row, headerMap['Physical_Aspects_Reference']) ?? '{}'}'.trim();
      final chemicalRaw = '${_at(row, headerMap['Chemical_Analysis_Reference']) ?? '{}'}'.trim();
      final physical = jsonLoads(physicalRaw);
      final chemical = jsonLoads(chemicalRaw);
      await db.execute(
        'INSERT INTO reference_materials '
        '(material_name, material_code, physical_reference_json, '
        'chemical_reference_json, source_row, imported_at) '
        'VALUES (?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(material_name) DO UPDATE SET '
        'material_code = excluded.material_code, '
        'physical_reference_json = excluded.physical_reference_json, '
        'chemical_reference_json = excluded.chemical_reference_json, '
        'source_row = excluded.source_row, '
        'imported_at = excluded.imported_at',
        [
          materialName,
          materialCode,
          jsonDumps(physical),
          jsonDumps(chemical),
          i + 1,
          timestamp,
        ],
      );
      count++;
    }
    return count;
  }

  Future<int> importUnits() async {
    final db = await dbHelper.database;
    ByteData bytes;
    try {
      bytes = await rootBundle.load(_unitsAsset);
    } catch (_) {
      return 0;
    }
    final sheet = await _readSheet(bytes, 'units.xlsx');
    if (sheet.isEmpty) return 0;
    final headers = [for (final v in sheet.first) '${v ?? ''}'.trim()];
    if (!headers.contains('Element Name') || !headers.contains('Unit')) return 0;
    final nameIdx = headers.indexOf('Element Name');
    final unitIdx = headers.indexOf('Unit');
    final timestamp = nowIso();
    var count = 0;
    for (var i = 1; i < sheet.length; i++) {
      final row = sheet[i];
      final name = '${_at(row, nameIdx) ?? ''}'.trim();
      if (name.isEmpty) continue;
      final unit = '${_at(row, unitIdx) ?? ''}'.trim();
      await db.execute(
        'INSERT INTO parameters (parameter_name, unit, imported_at) '
        'VALUES (?, ?, ?) '
        'ON CONFLICT(parameter_name) DO UPDATE SET '
        'unit = excluded.unit, imported_at = excluded.imported_at',
        [name, unit, timestamp],
      );
      count++;
    }
    return count;
  }

  dynamic _at(List<dynamic> row, int? index) {
    if (index == null || index >= row.length) return null;
    return row[index];
  }

  /// One-time bootstrap used at startup.
  Future<void> ensureInitialImport() async {
    if (await isSeedDone()) return;
    final db = await dbHelper.database;
    final count = Sqflite.firstIntValue(
        await db.rawQuery('SELECT COUNT(*) AS c FROM reference_materials'));
    if (count == 0) {
      await importReference();
      await importUnits();
    } else {
      final paramCount = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) AS c FROM parameters'));
      if (paramCount == 0) await importUnits();
    }
    await _markSeedDone();
  }
}