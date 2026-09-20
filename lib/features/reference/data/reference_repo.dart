import 'package:sqflite/sqflite.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/domain/rules.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';

/// Reference materials / parameters / units repository
/// (port of core/services/reference.py).
class ReferenceRepo {
  final DatabaseHelper dbHelper;

  ReferenceRepo({required this.dbHelper});

  Future<Database> get _db => dbHelper.database;

  // ── Materials ────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listMaterials() async {
    final db = await _db;
    final rows = await db.query('reference_materials',
        where: 'active = 1',
        orderBy: 'material_name COLLATE NOCASE ASC');
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  Future<List<Map<String, dynamic>>> listAllMaterials() async {
    final db = await _db;
    final rows = await db.query('reference_materials',
        orderBy: 'active DESC, material_name COLLATE NOCASE ASC');
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  Future<Map<String, dynamic>?> getMaterialRaw(int id) async {
    final db = await _db;
    final rows = await db.query('reference_materials', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  Future<Map<String, dynamic>> getMaterial(
      int id, {String? inspectionDate}) async {
    final rows = await _params();
    final raw = await getMaterialRaw(id);
    if (raw == null) throw const NotFoundError('Material not found.');
    final physical = jsonLoads('${raw['physical_reference_json']}');
    final chemicalMap = jsonLoads('${raw['chemical_reference_json']}');
    final enrichedPhysical = <String, dynamic>{};
    for (final e in physical.entries) {
      enrichedPhysical[e.key] = referenceValueText(e.value);
    }
    final enrichedChemical = <String, dynamic>{};
    for (final e in chemicalMap.entries) {
      enrichedChemical[e.key] = withReferenceUnit(e.value, rows[e.key] ?? '');
    }
    final material = <String, dynamic>{
      'id': raw['id'],
      'material_name': raw['material_name'],
      'material_code': raw['material_code'],
      'physical_reference': enrichedPhysical,
      'chemical_reference': enrichedChemical,
      'active': raw['active'],
      'next_entry_code':
          generateEntryCode('${raw['material_code']}', inspectionDate ?? todayIso()),
    };
    return material;
  }

  Future<Map<String, String>> _params() async {
    final db = await _db;
    final rows = await db.query('parameters', columns: ['parameter_name', 'unit']);
    return {for (final r in rows) '${r['parameter_name']}': '${r['unit'] ?? ''}'};
  }

  Future<int> createMaterial({
    required String materialName,
    required String materialCode,
    Map<String, dynamic> physicalReference = const {},
    Map<String, dynamic> chemicalReference = const {},
    Map<String, dynamic> units = const {},
  }) async {
    if (materialName.trim().isEmpty) throw const ValidationError('Material name is required.');
    if (materialCode.trim().isEmpty) throw const ValidationError('Material code is required.');
    final db = await _db;
    final existing = await db.query('reference_materials',
        where: 'material_name = ?', whereArgs: [materialName.trim()]);
    if (existing.isNotEmpty) {
      throw ValidationError("Material '${materialName.trim()}' already exists.");
    }
    final id = await db.insert('reference_materials', {
      'material_name': materialName.trim(),
      'material_code': materialCode.trim(),
      'physical_reference_json': jsonDumps(physicalReference),
      'chemical_reference_json': jsonDumps(chemicalReference),
      'active': 1,
      'imported_at': nowIso(),
    });
    await _batchUpsertParameters(chemicalReference, units, db);
    return id;
  }

  Future<void> updateMaterial(
    int id, {
    required String materialName,
    required String materialCode,
    Map<String, dynamic>? physicalReference,
    Map<String, dynamic>? chemicalReference,
    Map<String, dynamic> units = const {},
  }) async {
    final db = await _db;
    final existing = await getMaterialRaw(id);
    if (existing == null) throw const NotFoundError('Material not found.');
    final dup = await db.query('reference_materials',
        where: 'material_name = ? AND id != ?', whereArgs: [materialName, id]);
    if (dup.isNotEmpty) {
      throw ValidationError("Material '$materialName' already exists.");
    }
    final physicalRef = physicalReference ??
        jsonLoads('${existing['physical_reference_json']}');
    final chemicalRef = chemicalReference ??
        jsonLoads('${existing['chemical_reference_json']}');
    await db.update('reference_materials', {
      'material_name': materialName,
      'material_code': materialCode,
      'physical_reference_json': jsonDumps(physicalRef),
      'chemical_reference_json': jsonDumps(chemicalRef),
      'active': 1,
    }, where: 'id = ?', whereArgs: [id]);
    await _batchUpsertParameters(chemicalRef, units, db);
  }

  Future<void> deleteMaterial(int id) async {
    final db = await _db;
    await db.update('reference_materials', {'active': 0},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> _batchUpsertParameters(
      Map<String, dynamic> chemicalRef, Map<String, dynamic> units, Database db) async {
    final batch = db.batch();
    for (final e in chemicalRef.entries) {
      final unit = '${units[e.key] ?? ''}'.trim();
      if (unit.isEmpty) continue;
      batch.insert(
        'parameters',
        {
          'parameter_name': e.key,
          'unit': unit,
          'parameter_type': 'chemical',
          'imported_at': nowIso(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  // ── Entry code ───────────────────────────────────────────

  Future<String> generateEntryCode(String materialCode, String inspectionDate) async {
    final db = await _db;
    final dateFragment = inspectionDate.replaceAll('-', '');
    final prefix = '$materialCode-$dateFragment-';
    final rows = await db.rawQuery(
      'SELECT MAX(CAST(SUBSTR(entry_code, ?) AS INTEGER)) AS max_seq '
      'FROM inspections WHERE entry_code LIKE ?',
      [prefix.length + 1, '$prefix%'],
    );
    final maxSeq = rows.isNotEmpty
        ? (rows.first['max_seq'] as num?)?.toInt() ?? 0
        : 0;
    return '$prefix${(maxSeq + 1).toString().padLeft(3, '0')}';
  }

  // ── Parameters ───────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listParameters({String? parameterType}) async {
    final db = await _db;
    final rows = parameterType == null
        ? await db.query('parameters',
            orderBy: 'parameter_name COLLATE NOCASE ASC')
        : await db.query('parameters',
            where: 'parameter_type = ?',
            whereArgs: [parameterType],
            orderBy: 'parameter_name COLLATE NOCASE ASC');
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  Future<void> upsertParameter(String name, String unit, {String parameterType = 'chemical'}) async {
    final db = await _db;
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const ValidationError('Parameter name is required.');
    if (parameterType != 'chemical' && parameterType != 'physical') {
      throw const ValidationError("parameter_type must be 'chemical' or 'physical'.");
    }
    await db.insert(
      'parameters',
      {
        'parameter_name': trimmed,
        'unit': parameterType == 'physical' ? '' : unit.trim(),
        'parameter_type': parameterType,
        'imported_at': nowIso(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteParameter(String name) async {
    final db = await _db;
    await db.delete('parameters', where: 'parameter_name = ?', whereArgs: [name]);
  }

  // ── Lab units ────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listUnits() async {
    final db = await _db;
    final rows = await db.query('lab_units',
        orderBy: 'symbol COLLATE NOCASE ASC');
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  Future<void> upsertUnit(String symbol, {String name = '', String dimension = ''}) async {
    final db = await _db;
    final trimmed = symbol.trim();
    if (trimmed.isEmpty) throw const ValidationError('Unit symbol is required.');
    await db.insert(
      'lab_units',
      {
        'symbol': trimmed,
        'name': name.trim(),
        'dimension': dimension.trim(),
        'is_active': 1,
        'created_at': nowIso(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteUnit(String symbol) async {
    final db = await _db;
    await db.delete('lab_units', where: 'symbol = ?', whereArgs: [symbol]);
  }

  // ── Enrichment ───────────────────────────────────────────

  static Map<String, dynamic> decisionMetaOfRow(
      String status, Map<String, dynamic> row) {
    final meta = decisionMeta(status);
    return {...row, 'decision_label_ar': meta['ar'], 'decision_label_en': meta['en']};
  }
}

/// Serialize an inspection row into the shape the report/label need
/// (quantities to 3 decimals + parsed JSON fields).
Map<String, dynamic> serializeInspectionRow(Map<String, dynamic> row) {
  final out = Map<String, dynamic>.from(row);
  for (final key in ['quantity', 'rejected_quantity']) {
    final val = out[key];
    if (val != null) {
      final t = '$val'.trim();
      if (t.isNotEmpty && t != '-') {
        final n = double.tryParse(t);
        if (n != null) out[key] = n.toStringAsFixed(3);
      }
    }
  }
  out['physical_results'] = jsonLoads('${out['physical_results_json'] ?? out['physical_results']}');
  out['chemical_results'] = jsonLoads('${out['chemical_results_json'] ?? out['chemical_results']}');
  out['physical_reference'] = jsonLoads('${out['physical_reference_json'] ?? out['physical_reference']}');
  out['chemical_reference'] = jsonLoads('${out['chemical_reference_json'] ?? out['chemical_reference']}');
  out['snapshot'] = jsonLoads('${out['snapshot_json'] ?? out['snapshot']}');
  out['sample_names'] = jsonLoadsList('${out['sample_names_json'] ?? out['sample_names']}');
  out['decision_label_ar'] =
      decisionLabels['${out['decision_status']}']?['ar'] ??
          '${out['decision_status']}';
  out['decision_label_en'] =
      decisionLabels['${out['decision_status']}']?['en'] ??
          '${out['decision_status']}';
  return out;
}

/// decision_meta port: label_ar / label_en / css_class (keeps ar/en aliases).
Map<String, String> decisionMeta(String status) {
  final entry = decisionLabels[status];
  if (entry == null) {
    return {
      'label_ar': status,
      'label_en': status,
      'css_class': status,
      'ar': status,
      'en': status,
    };
  }
  return {
    ...entry,
    'label_ar': entry['ar']!,
    'label_en': entry['en']!,
    'css_class': entry['css'] ?? 'Unknown',
  };
}