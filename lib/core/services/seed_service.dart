import 'dart:isolate';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sqflite/sqflite.dart';

import '../../features/reference/domain/parameter_type.dart';
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
    // Excel parsing is CPU-heavy: decode off the main isolate. The raw
    // bytes cross the isolate boundary once; only plain stringified cells
    // come back, so the result stays transferable.
    final raw = bytes.buffer.asUint8List();
    return Isolate.run(() {
      final excel = Excel.decodeBytes(raw);
      if (excel.tables.isEmpty) {
        throw ValidationError(AppErrors.seedNoWorksheet(label));
      }
      final table = excel.tables.values.first;
      final result = <List<dynamic>>[];
      for (final row in table.rows) {
        result.add([for (final cell in row) cell?.value]);
      }
      return result;
    });
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
    // Single batch + one commit: the old per-row `await db.execute()` issued
    // ~96 round-trips through the DB lock during startup.
    final batch = db.batch();
    for (var i = 1; i < sheet.length; i++) {
      final row = sheet[i];
      final materialName = '${_at(row, headerMap['Raw_Material_Name']) ?? ''}'.trim();
      if (materialName.isEmpty) continue;
      final materialCode = '${_at(row, headerMap['code']) ?? ''}'.trim();
      final physicalRaw = '${_at(row, headerMap['Physical_Aspects_Reference']) ?? '{}'}'.trim();
      final chemicalRaw = '${_at(row, headerMap['Chemical_Analysis_Reference']) ?? '{}'}'.trim();
      final physical = jsonLoads(physicalRaw);
      final chemical = jsonLoads(chemicalRaw);
      batch.execute(
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
    if (count > 0) await batch.commit(noResult: true);
    return count;
  }

  /// Element → type as curated in the `Type` column of units.xlsx (ground
  /// truth derived from Reference.xlsx usage). Shared with [repairParameterTypes]
  /// so seed and repair can never disagree.
  Future<Map<String, ParameterType>> _seedParameterTypes() async {
    final out = <String, ParameterType>{};
    ByteData bytes;
    try {
      bytes = await rootBundle.load(_unitsAsset);
    } catch (_) {
      return out;
    }
    final sheet = await _readSheet(bytes, 'units.xlsx');
    if (sheet.isEmpty) return out;
    final headers = [for (final v in sheet.first) '${v ?? ''}'.trim()];
    if (!headers.contains('Element Name')) return out;
    final nameIdx = headers.indexOf('Element Name');
    final typeIdx = headers.indexOf('Type');
    for (var i = 1; i < sheet.length; i++) {
      final row = sheet[i];
      final name = '${_at(row, nameIdx) ?? ''}'.trim().toLowerCase();
      if (name.isEmpty) continue;
      final raw = typeIdx < 0 ? '' : '${_at(row, typeIdx) ?? ''}';
      // Blank = data error, not a silent physical: matches the
      // `upsertParameter` default and [ParameterType.ofDb].
      out[name] = raw.trim().isEmpty
          ? ParameterType.chemical
          : ParameterType.parse(raw);
    }
    return out;
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
    final typeIdx = headers.indexOf('Type');
    final timestamp = nowIso();
    var count = 0;
    final batch = db.batch();
    for (var i = 1; i < sheet.length; i++) {
      final row = sheet[i];
      final name = '${_at(row, nameIdx) ?? ''}'.trim();
      if (name.isEmpty) continue;
      final unit = '${_at(row, unitIdx) ?? ''}'.trim();
      // Explicit type per row. The old statement omitted the column and the
      // table default silently filed every element — chemical assays included —
      // under physical, emptying the chemical tab.
      final raw = typeIdx < 0 ? '' : '${_at(row, typeIdx) ?? ''}';
      final type = raw.trim().isEmpty
          ? ParameterType.chemical
          : ParameterType.parse(raw);
      batch.execute(
        'INSERT INTO parameters (parameter_name, unit, parameter_type, imported_at) '
        'VALUES (?, ?, ?, ?) '
        'ON CONFLICT(parameter_name) DO UPDATE SET '
        'unit = excluded.unit, imported_at = excluded.imported_at',
        [name, unit, type.value, timestamp],
      );
      // Units registry: every seeded unit also lands in `lab_units` so the
      // Units table holds all program units and every picker inherits it.
      if (unit.isNotEmpty) {
        batch.execute(
          'INSERT OR IGNORE INTO lab_units (symbol, is_active, created_at) '
          'VALUES (?, 1, ?)',
          [unit, timestamp],
        );
      }
      count++;
    }
    if (count > 0) await batch.commit(noResult: true);
    return count;
  }

  /// Repairs rows mis-typed by the old typeless seed (everything defaulted to
  /// physical) on every startup. Idempotent: only rows that still look
  /// seed-defaulted move, and only uphill — a row explicitly typed chemical
  /// by a user is never downgraded, and names absent from the asset are
  /// untouched.
  ///
  /// A `physical` row carrying a unit is the fingerprint of the old seed:
  /// physical aspects are unit-less by design, so such a row was never
  /// hand-typed with intent.
  Future<int> repairParameterTypes() async {
    final assetTypes = await _seedParameterTypes();
    if (assetTypes.isEmpty) return 0;
    final db = await dbHelper.database;
    final rows = await db.rawQuery(
      'SELECT parameter_name, parameter_type, unit FROM parameters',
    );
    // Collect first, write once: the old per-row `rawUpdate` held the DB
    // lock across a full-table scan on every startup.
    final chemicalFixes = <String>[];
    final normalizeFixes = <String>[];
    for (final row in rows) {
      final name = '${row['parameter_name'] ?? ''}';
      final key = name.trim().toLowerCase();
      final asset = assetTypes[key];
      final current = '${row['parameter_type'] ?? ''}'.trim().toLowerCase();
      final unit = '${row['unit'] ?? ''}'.trim();
      if (current.isEmpty) {
        normalizeFixes.add(name);
      } else if (current == ParameterType.physical.value &&
          asset == ParameterType.chemical &&
          unit.isNotEmpty) {
        chemicalFixes.add(name);
      }
    }
    if (chemicalFixes.isEmpty && normalizeFixes.isEmpty) return 0;
    final batch = db.batch();
    for (final name in normalizeFixes) {
      batch.rawUpdate(
        'UPDATE parameters SET parameter_type = ? WHERE parameter_name = ?',
        [ParameterType.ofDb(null).value, name],
      );
    }
    for (final name in chemicalFixes) {
      batch.rawUpdate(
        'UPDATE parameters SET parameter_type = ? WHERE parameter_name = ?',
        [ParameterType.chemical.value, name],
      );
    }
    await batch.commit(noResult: true);
    return chemicalFixes.length + normalizeFixes.length;
  }

  dynamic _at(List<dynamic> row, int? index) {
    if (index == null || index >= row.length) return null;
    return row[index];
  }

  /// One-time bootstrap used at startup, plus the every-startup type repair:
  /// databases seeded before units.xlsx carried explicit types still file
  /// every element under physical.
  Future<void> ensureInitialImport() async {
    if (await isSeedDone()) {
      await repairParameterTypes();
      return;
    }
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
    await repairParameterTypes();
    await _markSeedDone();
  }
}