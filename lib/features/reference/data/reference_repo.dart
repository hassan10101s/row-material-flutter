import 'package:sqflite/sqflite.dart';

import '../../../core/constants/app_errors.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/domain/rules.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';
import '../domain/reference_repository.dart';

/// Reference materials / parameters / units repository
/// (port of core/services/reference.py).
class ReferenceRepo implements ReferenceRepository {
  final DatabaseHelper dbHelper;

  /// Resolves the current device tag used to scope minted entry codes.
  ///
  /// Two offline devices must never mint the same `entry_code`: the sync
  /// document id of an inspection IS its entry code, so a collision means one
  /// device's push overwrites (or version-conflicts with) the other's and a
  /// human has to untangle it on the Sync screen. Scoping the sequence per
  /// device (`CODE-DATE-TAG-SEQ`) makes collisions structurally impossible.
  /// Null (tests, pre-registration) keeps the legacy `CODE-DATE-SEQ` format.
  final Future<String> Function()? deviceTagProvider;

  ReferenceRepo({required this.dbHelper, this.deviceTagProvider});

  Future<Database> get _db => dbHelper.database;

  // ── Materials ─────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> listMaterials() async {
    final db = await _db;
    final rows = await db.query('reference_materials',
        where: 'active = 1',
        orderBy: 'material_name COLLATE NOCASE ASC');
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  @override
  Future<List<Map<String, dynamic>>> listAllMaterials() async {
    final db = await _db;
    // The `__PRODUCT_SENTINEL__` row is storage plumbing for product
    // inspections, never a catalog entry.
    final rows = await db.query('reference_materials',
        where: 'material_name != ?',
        whereArgs: [DatabaseHelper.productSentinelMaterialName],
        orderBy: 'active DESC, material_name COLLATE NOCASE ASC');
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  /// The optional [exec] lets a caller that already owns a transaction (P7.3)
  /// reuse it: opening a second connection while the transaction holds the
  /// write lock would deadlock.
  @override
  Future<Map<String, dynamic>?> getMaterialRaw(int id, {DatabaseExecutor? exec}) async {
    final db = exec ?? await _db;
    final rows = await db.query('reference_materials', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return Map<String, dynamic>.from(rows.first);
  }

  @override
  Future<Map<String, dynamic>> getMaterial(
      int id, {String? inspectionDate, DatabaseExecutor? exec}) async {
    final rows = await _params(exec: exec);
    final raw = await getMaterialRaw(id, exec: exec);
    if (raw == null) throw NotFoundError(AppErrors.materialNotFound);
    final physical = jsonLoads('${raw['physical_reference_json']}');
    final chemicalMap = jsonLoads('${raw['chemical_reference_json']}');
    final enrichedPhysical = <String, dynamic>{};
    for (final e in physical.entries) {
      enrichedPhysical[e.key] = withReferenceUnit(e.value, rows[e.key] ?? '');
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
          await generateEntryCode('${raw['material_code']}',
              inspectionDate ?? todayIso(), exec: exec),
    };
    return material;
  }

  Future<Map<String, String>> _params({DatabaseExecutor? exec}) async {
    final db = exec ?? await _db;
    final rows = await db.query('parameters', columns: ['parameter_name', 'unit']);
    return {for (final r in rows) '${r['parameter_name']}': '${r['unit'] ?? ''}'};
  }

  @override
  Future<int> createMaterial({
    required String materialName,
    required String materialCode,
    Map<String, dynamic> physicalReference = const {},
    Map<String, dynamic> chemicalReference = const {},
    Map<String, dynamic> units = const {},
    DatabaseExecutor? exec,
  }) async {
    if (materialName.trim().isEmpty) throw ValidationError(AppErrors.referenceMaterialNameRequired);
    if (materialCode.trim().isEmpty) throw ValidationError(AppErrors.referenceMaterialCodeRequired);
    final db = exec ?? await _db;
    final existing = await db.query('reference_materials',
        where: 'material_name = ?', whereArgs: [materialName.trim()]);
    if (existing.isNotEmpty) {
      throw ValidationError(AppErrors.referenceMaterialExists(materialName.trim()));
    }
    final id = await db.insert('reference_materials', {
      'material_name': materialName.trim(),
      'material_code': materialCode.trim(),
      'physical_reference_json': jsonDumps(physicalReference),
      'chemical_reference_json': jsonDumps(chemicalReference),
      'active': 1,
      'imported_at': nowIso(),
    });
    await _upsertMaterialParameters(
      physicalReference,
      chemicalReference,
      units,
      db,
    );
    return id;
  }

  @override
  Future<void> updateMaterial(
    int id, {
    required String materialName,
    required String materialCode,
    Map<String, dynamic>? physicalReference,
    Map<String, dynamic>? chemicalReference,
    Map<String, dynamic> units = const {},
    DatabaseExecutor? exec,
  }) async {
    final db = exec ?? await _db;
    final existing = await getMaterialRaw(id, exec: exec);
    if (existing == null) throw NotFoundError(AppErrors.materialNotFound);
    final cleanName = materialName.trim();
    final cleanCode = materialCode.trim();
    final dup = await db.query('reference_materials',
        where: 'material_name = ? AND id != ?',
        whereArgs: [cleanName.isEmpty ? '${existing['material_name']}' : cleanName, id]);
    if (dup.isNotEmpty) {
      throw ValidationError(AppErrors.referenceMaterialExists(cleanName));
    }
    final physicalRef = physicalReference ??
        jsonLoads('${existing['physical_reference_json']}');
    final chemicalRef = chemicalReference ??
        jsonLoads('${existing['chemical_reference_json']}');
    await db.update('reference_materials', {
      'material_name': cleanName.isEmpty ? '${existing['material_name']}' : cleanName,
      'material_code': cleanCode.isEmpty ? '${existing['material_code']}' : cleanCode,
      'physical_reference_json': jsonDumps(physicalRef),
      'chemical_reference_json': jsonDumps(chemicalRef),
      'active': 1,
    }, where: 'id = ?', whereArgs: [id]);
    await _upsertMaterialParameters(physicalRef, chemicalRef, units, db);
  }

  @override
  Future<void> deleteMaterial(int id, [DatabaseExecutor? exec]) async {
    final db = exec ?? await _db;
    await db.update('reference_materials', {'active': 0},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<void> _upsertMaterialParameters(
    Map<String, dynamic> physical,
    Map<String, dynamic> chemical,
    Map<String, dynamic> units,
    DatabaseExecutor db,
  ) async {
    final fields = <(String, String, Object?)>[
      for (final entry in physical.entries) ('physical', entry.key, entry.value),
      for (final entry in chemical.entries) ('chemical', entry.key, entry.value),
    ];
    for (final (type, rawName, value) in fields) {
      final name = rawName.trim();
      if (name.isEmpty) continue;
      final requestedUnit = units.containsKey(name)
          ? '${units[name] ?? ''}'.trim()
          : referenceUnitText(value);
      final existing = await db.query(
        'parameters',
        where: 'parameter_name = ? COLLATE NOCASE',
        whereArgs: [name],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        if ('${existing.first['parameter_type'] ?? ''}' != type) {
          throw ValidationError(AppErrors.parameterTypeInvalid);
        }
        final unit = requestedUnit.isNotEmpty || units.containsKey(name)
            ? requestedUnit
            : '${existing.first['unit'] ?? ''}';
        await db.update(
          'parameters',
          {'unit': unit},
          where: 'id = ?',
          whereArgs: [existing.first['id']],
        );
      } else {
        await db.insert('parameters', {
          'parameter_name': name,
          'unit': requestedUnit,
          'parameter_type': type,
          'imported_at': nowIso(),
        });
      }
    }
  }

  // ── Products (for product inspections) ────────────────────────

  /// Active lab products with their analysis ranges, for the
  /// product-inspection form's product picker.
  @override
  Future<List<Map<String, dynamic>>> listProductsForInspection() async {
    final db = await _db;
    final products = await db.query(
      'lab_products',
      where: 'active = 1',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    if (products.isEmpty) return [];
    final ranges = await db.rawQuery('''
      SELECT lpa.product_id, lpa.min_value, lpa.max_value,
             CASE WHEN a.parameter_id IS NOT NULL THEN COALESCE(p.unit, '')
                  ELSE COALESCE(NULLIF(a.unit, ''), lpa.unit) END AS unit,
             COALESCE(lpa.is_required, 0) AS is_required,
             a.name AS analysis_name
      FROM lab_product_analyses lpa
      JOIN lab_analyses a ON a.id = lpa.analysis_id
      LEFT JOIN parameters p ON p.id = a.parameter_id
      ORDER BY lpa.product_id ASC, a.name ASC
    ''');
    final byProduct = <int, List<Map<String, dynamic>>>{};
    for (final r in ranges) {
      final pid = (r['product_id'] as num?)?.toInt() ?? 0;
      byProduct.putIfAbsent(pid, () => []).add(Map<String, dynamic>.from(r));
    }
    return [
      for (final p in products)
        {
          ...Map<String, dynamic>.from(p),
          'product_code': productCodeFor('${p['name'] ?? ''}'),
          'ranges': byProduct[(p['id'] as num?)?.toInt() ?? 0] ??
              const <Map<String, dynamic>>[],
        },
    ];
  }

  /// Product inspection context: name/code, next entry code and the
  /// physical/chemical reference maps.
  ///
  /// Reference-first (mirrors materials): when the product carries
  /// `physical/chemical_reference_json` those maps are used (مطلوب flags
  /// included); otherwise the legacy `lab_product_analyses` ranges are
  /// converted (products saved before the reference editor existed).
  @override
  Future<Map<String, dynamic>> getProductForInspection(
    int id, {
    String? inspectionDate,
    DatabaseExecutor? exec,
  }) async {
    final db = exec ?? await _db;
    final rows = await db.query(
      'lab_products',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) throw NotFoundError(AppErrors.productNotFound);
    final product = Map<String, dynamic>.from(rows.first);
    if ((product['active'] as num?) != 1) {
      throw const ValidationError(
          'Selected product is inactive (archived) and cannot be used in a new inspection.');
    }
    final paramUnits = await _params(exec: exec);
    Map<String, dynamic> physical = {};
    Map<String, dynamic> chemical = {};
    final physJson =
        jsonLoads('${product['physical_reference_json'] ?? ''}');
    final chemJson =
        jsonLoads('${product['chemical_reference_json'] ?? ''}');
    if (physJson.isNotEmpty || chemJson.isNotEmpty) {
      for (final e in physJson.entries) {
        physical[e.key] =
            withReferenceUnit(e.value, paramUnits[e.key] ?? '');
      }
      for (final e in chemJson.entries) {
        chemical[e.key] =
            withReferenceUnit(e.value, paramUnits[e.key] ?? '');
      }
    } else {
      final ranges = await db.rawQuery(
        '''
        SELECT lpa.min_value, lpa.max_value,
               CASE WHEN a.parameter_id IS NOT NULL THEN COALESCE(p.unit, '')
                    ELSE COALESCE(NULLIF(a.unit, ''), lpa.unit) END AS unit,
               COALESCE(lpa.is_required, 0) AS is_required,
               a.name AS analysis_name
        FROM lab_product_analyses lpa
        JOIN lab_analyses a ON a.id = lpa.analysis_id
        LEFT JOIN parameters p ON p.id = a.parameter_id
        WHERE lpa.product_id = ?
        ORDER BY a.name ASC
        ''',
        [id],
      );
      for (final r in ranges) {
        final name = '${r['analysis_name'] ?? ''}'.trim();
        if (name.isEmpty) continue;
        final required =
            r['is_required'] == 1 || r['is_required'] == true;
        final withUnit = withReferenceUnit(
          _productRangeText(r['min_value'], r['max_value']),
          '${r['unit'] ?? ''}',
        );
        chemical[name] =
            required ? withReferenceRequired(withUnit, true) : withUnit;
      }
    }
    final code = productCodeFor('${product['name'] ?? ''}');
    return {
      'id': product['id'],
      'product_name': '${product['name'] ?? ''}',
      'product_code': code,
      'physical_reference': physical,
      'chemical_reference': chemical,
      'active': product['active'],
      'next_entry_code': await generateEntryCode(
        code,
        inspectionDate ?? todayIso(),
        exec: exec,
      ),
    };
  }

  /// Stable short code Minted from the product name for entry codes
  /// (`P` + up to 3 latin alphanumerics, else `PRD`): entry codes stay
  /// readable (`PPRO-20260101-001`) while the date+sequence keeps them unique.
  static String productCodeFor(String name) {
    final stripped =
        name.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final core = stripped.isEmpty
        ? 'PRD'
        : stripped.substring(0, stripped.length.clamp(0, 3));
    return 'P$core';
  }

  static String _productRangeText(Object? min, Object? max) {
    final lo = min == null ? '' : '$min'.trim();
    final hi = max == null ? '' : '$max'.trim();
    if (lo.isNotEmpty && hi.isNotEmpty) {
      if (lo == hi) return lo;
      return '$lo-$hi';
    }
    if (lo.isNotEmpty) return 'min $lo';
    if (hi.isNotEmpty) return 'max $hi';
    return '';
  }

  // ── Entry code ────────────────────────────────────────────────

  /// Mints the next entry code for [materialCode] on [inspectionDate].
  ///
  /// The sequence is per (material, day, device): with a device tag two
  /// offline devices mint disjoint code spaces, so their rows can never share
  /// a sync document id. Without a tag the legacy global-per-day sequence is
  /// kept (single-device history and every existing test).
  @override
  Future<String> generateEntryCode(String materialCode, String inspectionDate,
      {DatabaseExecutor? exec}) async {
    final db = exec ?? await _db;
    final dateFragment = inspectionDate.replaceAll('-', '');
    final tag = await _deviceTag();
    final prefix = tag.isEmpty
        ? '$materialCode-$dateFragment-'
        : '$materialCode-$dateFragment-$tag-';
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

  /// Uppercase alphanumeric tag (6 chars) identifying this device inside
  /// minted codes, or empty when no provider is wired (legacy format).
  Future<String> _deviceTag() async {
    final provider = deviceTagProvider;
    if (provider == null) return '';
    try {
      final raw = await provider();
      final clean = raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      if (clean.isEmpty) return '';
      return clean.length <= 6 ? clean : clean.substring(0, 6);
    } on Object {
      return '';
    }
  }

  // ── Parameters ────────────────────────────────────────────────

  @override
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

  @override
  Future<void> upsertParameter(String name, String unit,
      {String parameterType = 'chemical', DatabaseExecutor? exec}) async {
    final db = exec ?? await _db;
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ValidationError(AppErrors.parameterNameRequired);
    if (parameterType != 'chemical' && parameterType != 'physical') {
      throw ValidationError(AppErrors.parameterTypeInvalid);
    }
    final existing = await db.query(
      'parameters',
      where: 'parameter_name = ? COLLATE NOCASE',
      whereArgs: [trimmed],
      limit: 1,
    );
    if (existing.isNotEmpty &&
        '${existing.first['parameter_type'] ?? ''}' != parameterType) {
      throw ValidationError(AppErrors.parameterTypeInvalid);
    }
    await registerUnit(db, unit);
    final values = {
      'parameter_name': trimmed,
      'unit': unit.trim(),
      'parameter_type': parameterType,
      'imported_at': nowIso(),
    };
    if (existing.isEmpty) {
      await db.insert('parameters', values);
    } else {
      await db.update(
        'parameters',
        values,
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    }
  }

  @override
  Future<void> deleteParameter(String name, [DatabaseExecutor? exec]) async {
    final db = exec ?? await _db;
    // Bounds rows and analysis links inherit the NAME from this origin; clear
    // them so a reference parameter can be removed without FK violations.
    final rows = await db.query('parameters',
        columns: ['id'], where: 'parameter_name = ?', whereArgs: [name]);
    final pid = rows.isEmpty ? null : rows.first['id'];
    if (pid != null) {
      await db.delete('material_parameter_bounds',
          where: 'parameter_id = ?', whereArgs: [pid]);
      await db.update('lab_analyses', <String, Object?>{'parameter_id': null},
          where: 'parameter_id = ?', whereArgs: [pid]);
    }
    await db.delete('parameters', where: 'parameter_name = ?', whereArgs: [name]);
  }

  // ── Lab units ─────────────────────────────────────────────────

  @override
  Future<List<Map<String, dynamic>>> listUnits() async {
    final db = await _db;
    final rows = await db.query('lab_units',
        orderBy: 'symbol COLLATE NOCASE ASC');
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  @override
  Future<void> upsertUnit(String symbol,
      {String name = '', String dimension = '', DatabaseExecutor? exec}) async {
    final db = exec ?? await _db;
    final trimmed = symbol.trim();
    if (trimmed.isEmpty) throw ValidationError(AppErrors.unitSymbolRequired);
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

  /// Batch/transaction-safe registry write. Static (not virtual) so saves
  /// running inside a transaction never re-enter through an override.
  static Future<void> registerUnit(
      DatabaseExecutor db, String symbol) async {
    final trimmed = symbol.trim();
    if (trimmed.isEmpty) return;
    try {
      await db.rawInsert(
        'INSERT OR IGNORE INTO lab_units (symbol, is_active, created_at) '
        'VALUES (?, 1, ?)',
        [trimmed, nowIso()],
      );
    } catch (_) {}
  }

  /// Units registry: silently registers a unit symbol used by a save so the
  /// Units table holds every program unit. Never throws and never overwrites
  /// curated name/dimension — use [upsertUnit] for that.
  @override
  Future<void> ensureUnit(String symbol, [DatabaseExecutor? exec]) async {
    await registerUnit(exec ?? await _db, symbol);
  }

  @override
  Future<void> deleteUnit(String symbol, [DatabaseExecutor? exec]) async {
    final db = exec ?? await _db;
    await db.delete('lab_units', where: 'symbol = ?', whereArgs: [symbol]);
  }

  /// Every table/column whose unit strings belong to the `lab_units` registry.
  static const List<(String, String)> unitSources = [
    ('parameters', 'unit'),
    ('lab_analyses', 'unit'),
    ('lab_analysis_items', 'unit'),
    ('lab_inventory', 'unit'),
    ('lab_constants', 'unit'),
    ('lab_product_analyses', 'unit'),
    ('lab_field_chemical_links', 'unit'),
    ('material_parameter_bounds', 'unit'),
    ('qc_items', 'unit'),
    ('qc_inspections', 'qty_unit'),
    ('qc_findings_nc', 'qty_unit'),
    ('qc_goals', 'target_unit'),
    ('qc_goal_kpis', 'unit'),
  ];

  /// How many rows reference each unit symbol across the program — what the
  /// Units table shows as inheritance ("used in N places") and what guards
  /// deletion of a unit that is still in use.
  @override
  Future<Map<String, int>> unitUsageCounts([DatabaseExecutor? exec]) async {
    final db = exec ?? await _db;
    final out = <String, int>{};
    late final Set<String> tables;
    try {
      tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((r) => '${r['name']}').toSet();
    } catch (_) {
      return out;
    }
    for (final (table, column) in unitSources) {
      if (!tables.contains(table)) continue;
      try {
        final rows = await db.rawQuery(
          'SELECT TRIM("$column") AS s, COUNT(*) AS c FROM "$table" '
          'WHERE TRIM(COALESCE("$column", \'\')) <> \'\' '
          'GROUP BY TRIM("$column")',
        );
        for (final r in rows) {
          final s = '${r['s'] ?? ''}';
          if (s.isEmpty) continue;
          out[s] = (out[s] ?? 0) + ((r['c'] as num?)?.toInt() ?? 0);
        }
      } catch (_) {}
    }
    return out;
  }

  // ── Enrichment ────────────────────────────────────────────────

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