import 'package:sqflite/sqflite.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/entity_registry.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/sync/sync_write.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/nir_validation_repository.dart';

/// Local implementation of [NirValidationRepository].
///
/// Read side (compute) is a pure SQLite query set: it pairs every محضر فحص
/// NIR reading (raw-material inspections + product batch samples, on or after
/// the active horizon) with the laboratory reference result
/// (`lab_sample_tests`) sharing the same `entry_code`, parameter and
/// (multi-sample) sample name. The write side (reset) appends one
/// `nir_validation_settings` row through the single write contract
/// (version bump + sync queue + audit).
class NirValidationRepo implements NirValidationRepository {
  NirValidationRepo({
    required this.dbHelper,
    required this.guard,
    required this.queue,
    required this.audit,
  });

  final DatabaseHelper dbHelper;
  final WriteGuard guard;
  final SyncQueue queue;
  final AuditLogger audit;

  static final SyncEntity _entity = syncEntities.firstWhere(
    (e) => e.type == 'nirValidationSettings',
  );

  @override
  Future<NirValidationSettings?> getSettings() async {
    final db = await dbHelper.readDatabase;
    final rows = await db.query(
      'nir_validation_settings',
      where: "COALESCE(scope, '') = ''",
      orderBy: 'id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return NirValidationSettings.fromMap(rows.first);
  }

  @override
  Future<List<NirValidationSettings>> listResetHistory({int limit = 50}) async {
    final db = await dbHelper.readDatabase;
    final rows = await db.query(
      'nir_validation_settings',
      orderBy: 'id DESC',
      limit: limit,
    );
    return [for (final r in rows) NirValidationSettings.fromMap(r)];
  }

  @override
  Future<NirValidationSettings> resetValidation(
    String startDate, {
    String note = '',
    NirScope? scope,
    int? entityId,
    String entityName = '',
    String parameter = '',
  }) async {
    final cleanDate = startDate.trim();
    if (parseIsoDate(cleanDate) == null) {
      throw ValidationError(AppText.t('التاريخ غير صالح', 'Invalid date'));
    }
    if (!guard.allows(Permission.labResultsUpdate.id)) {
      throw AuthorizationError(AppErrors.notAuthorizedForOperation);
    }
    final cleanParam = parameter.trim();
    final cleanEntity = entityName.trim();
    // A scoped reset must name the parameter it targets, otherwise it would
    // silently behave like a global reset.
    if (scope != null && cleanParam.isEmpty) {
      throw ValidationError(
        AppText.t('حدد التحليل المراد تصفيره', 'Pick the parameter to reset'),
      );
    }
    final scopeValue = scope == null
        ? ''
        : NirValidationSettings.scopeValue(scope);
    final entity = scope == null ? null : entityId;
    final now = nowIso();
    final row = <String, dynamic>{
      'start_date': cleanDate,
      'reset_note': note.trim(),
      'reset_by': guard.uid,
      'reset_by_name': guard.actorName,
      'scope': scopeValue,
      'entity_id': entity,
      'entity_name': scope == null ? '' : cleanEntity,
      'parameter': scope == null ? '' : cleanParam,
      'created_at': now,
      'updated_at': now,
    };
    final id = await dbHelper.businessTransaction((txn) async {
      final localId = await txn.insert('nir_validation_settings', row);
      await enqueueLocalChange(
        executor: txn,
        entity: _entity,
        row: {...row, 'id': localId},
        operation: 'create',
        queue: queue,
        audit: audit,
        auditAction: AuditAction.settingsUpdated,
        organizationId: guard.organizationId,
        uid: guard.uid,
        deviceId: guard.deviceId,
      );
      return localId;
    });
    return NirValidationSettings(
      id: id,
      startDate: cleanDate,
      resetNote: note.trim(),
      resetByName: guard.actorName,
      createdAt: now,
      scope: scopeValue,
      entityId: entity,
      entityName: scope == null ? '' : cleanEntity,
      parameter: scope == null ? '' : cleanParam,
    );
  }

  @override
  Future<NirValidationReport> compute({String? startDate}) async {
    final db = await dbHelper.readDatabase;
    final horizons = await _loadHorizons(db);
    final settings = startDate == null ? await getSettings() : null;
    final globalHorizon = (startDate ?? settings?.startDate ?? '').trim();

    final units = await _loadUnits(db);
    // Fetch only rows on/after the earliest horizon in play; the per-group
    // pass below then applies each group's own (scoped) or the global horizon.
    final fetchFrom = _earliestHorizon(horizons, globalHorizon);
    final rawInspections = await _listRawInspections(db, fetchFrom);
    final batchRows = await _listBatchSamples(db, fetchFrom);
    final labTests = await _listLabTests(db);

    final groups =
        <_GroupKey, List<({NirValidationPoint point, String unit})>>{};

    // ── Raw material: NIR = the محظر result values ──────────────────────
    _pairRaw(
      rawInspections: rawInspections,
      labTests: labTests,
      units: units,
      groups: groups,
    );

    // ── Product: NIR = each محضر تشغيلة sample's recorded results ───────
    _pairProduct(
      batchRows: batchRows,
      labTests: labTests,
      units: units,
      groups: groups,
    );

    final stats = <NirParameterStats>[];
    for (final entry in groups.entries) {
      final key = entry.key;
      final own = _scopedHorizon(horizons, key);
      final horizon = own ?? globalHorizon;
      final points = entry.value
          .where((p) => !p.point.nirValue.isNaN)
          .where(
            (p) =>
                horizon.isEmpty ||
                p.point.inspectionDate.compareTo(horizon) >= 0,
          )
          .map((p) => p.point)
          .toList();
      if (points.isEmpty) continue;
      final unit = entry.value
          .map((p) => p.unit.trim())
          .firstWhere((u) => u.isNotEmpty, orElse: () => '');
      stats.add(
        NirParameterStats(
          scope: key.scope,
          entityId: key.entityId,
          entityName: key.entityName,
          parameter: key.parameter,
          unit: unit,
          points: points,
          horizonStart: horizon,
          scopedHorizon: own != null,
        ),
      );
    }
    stats.sort((a, b) {
      final byEntity = a.entityName.compareTo(b.entityName);
      if (byEntity != 0) return byEntity;
      return a.parameter.compareTo(b.parameter);
    });
    return NirValidationReport(settings: settings, stats: stats);
  }

  Future<List<NirValidationSettings>> _loadHorizons(Database db) async {
    final rows = await db.query('nir_validation_settings', orderBy: 'id DESC');
    return [for (final r in rows) NirValidationSettings.fromMap(r)];
  }

  /// The oldest horizon we can safely cut at in SQL.
  ///
  /// With a global horizon every group has an effective horizon (its own or
  /// the global one), so fetching from the oldest of them is safe. Without a
  /// global horizon some groups have no horizon at all and must count every
  /// محضر — then no SQL-level cut is allowed (`''` fetches everything).
  String _earliestHorizon(
    List<NirValidationSettings> rows,
    String globalHorizon,
  ) {
    final global = substr10(globalHorizon.trim());
    if (global.isEmpty) return '';
    var min = global;
    for (final r in rows) {
      final d = substr10(r.startDate.trim());
      if (d.isEmpty) continue;
      if (d.compareTo(min) < 0) min = d;
    }
    return min;
  }

  /// The newest per-item horizon matching [key] (خامة/منتج × parameter), or
  /// null when the group has no scoped reset (it then uses the global one).
  /// Rows are loaded newest-first; entity id wins, then normalized name.
  String? _scopedHorizon(List<NirValidationSettings> rows, _GroupKey key) {
    final scopeValue = NirValidationSettings.scopeValue(key.scope);
    final paramNorm = _normKey(key.parameter);
    final entityNorm = _normKey(key.entityName);
    for (final r in rows) {
      if (r.isGlobal || r.scope != scopeValue) continue;
      if (_normKey(r.parameter) != paramNorm) continue;
      final idMatch = r.entityId != null && r.entityId == key.entityId;
      final nameMatch =
          entityNorm.isNotEmpty && _normKey(r.entityName) == entityNorm;
      if (!idMatch && !nameMatch) continue;
      final d = substr10(r.startDate.trim());
      if (d.isNotEmpty) return d;
    }
    return null;
  }

  // ── Pairing: raw-material inspections ────────────────────────────────

  void _pairRaw({
    required List<Map<String, Object?>> rawInspections,
    required List<Map<String, Object?>> labTests,
    required Map<String, String> units,
    required Map<_GroupKey, List<({NirValidationPoint point, String unit})>>
    groups,
  }) {
    final testsByEntry = <String, List<Map<String, Object?>>>{};
    for (final t in labTests) {
      if (t['source_type'] != 'raw_material') continue;
      final code = _normKey(t['entry_code']);
      if (code.isEmpty) continue;
      (testsByEntry[code] ??= []).add(t);
    }
    for (final ins in rawInspections) {
      final tests = testsByEntry[_normKey(ins['entry_code'])];
      if (tests == null || tests.isEmpty) continue;
      final insId = (ins['id'] as num?)?.toInt() ?? 0;
      final entryCode = '${ins['entry_code'] ?? ''}';
      final date = substr10('${ins['inspection_date'] ?? ''}');
      final sampleNames = jsonLoadsList(_asString(ins['sample_names_json']));
      final values = _flattenValues(
        jsonLoads(_asString(ins['physical_results_json'])),
        jsonLoads(_asString(ins['chemical_results_json'])),
      );
      for (final t in tests) {
        final param = _paramName(t);
        if (param.isEmpty) continue;
        final value = values[_normKey(param)];
        if (value == null) continue;
        final labValue = parseNumeric(t['result_text']);
        if (labValue == null) continue;
        final nirValue = _nirFor(value, sampleNames, t['sample_name']);
        if (nirValue == null) continue;
        final key = _GroupKey(
          scope: NirScope.rawMaterial,
          entityId: (ins['material_id'] as num?)?.toInt() ?? 0,
          entityName: '${ins['material_name'] ?? ''}',
          parameter: param,
        );
        (groups[key] ??= []).add((
          point: NirValidationPoint(
            inspectionId: insId,
            entryCode: entryCode,
            inspectionDate: date,
            sampleName: '${t['sample_name'] ?? ''}',
            nirValue: nirValue,
            labValue: labValue,
          ),
          unit: _unitOf(t, units),
        ));
      }
    }
  }

  // ── Pairing: product batch samples (محضر التشغيلة) ───────────────────

  void _pairProduct({
    required List<Map<String, Object?>> batchRows,
    required List<Map<String, Object?>> labTests,
    required Map<String, String> units,
    required Map<_GroupKey, List<({NirValidationPoint point, String unit})>>
    groups,
  }) {
    final testsByEntry = <String, List<Map<String, Object?>>>{};
    for (final t in labTests) {
      if (t['source_type'] != 'product') continue;
      final code = _normKey(t['entry_code']);
      if (code.isEmpty) continue;
      (testsByEntry[code] ??= []).add(t);
    }
    for (final b in batchRows) {
      final tests = testsByEntry[_normKey(b['entry_code'])];
      if (tests == null || tests.isEmpty) continue;
      // The lab test names the sample; batch rows carry both a number and a
      // name — the name wins, the number is the fallback.
      final batchSampleName = '${b['sample_no'] ?? ''}'.trim().isEmpty
          ? ''
          : '${b['sample_no'] ?? ''}';
      final batchName = '${b['batch_sample_name'] ?? ''}'.trim();
      final expectedSample = batchName.isEmpty ? batchSampleName : batchName;
      final displayName = batchName.isEmpty ? batchSampleName : batchName;
      final values = _flattenValues(
        jsonLoads(_asString(b['physical_results_json'])),
        _flattenChemical(jsonLoadsList(_asString(b['chemical_results_json']))),
      );
      if (values.isEmpty) continue;
      for (final t in tests) {
        final param = _paramName(t);
        if (param.isEmpty) continue;
        final raw = values[_normKey(param)];
        if (raw == null) continue;
        final labValue = parseNumeric(t['result_text']);
        if (labValue == null) continue;
        final nirValue = parseNumeric(raw);
        if (nirValue == null) continue;
        // Batch rows are per sample; accept the test when the sample names
        // agree, or when the lab test has no sample name of its own.
        final testName = '${t['sample_name'] ?? ''}'.trim();
        final agrees =
            testName.isEmpty || _normKey(testName) == _normKey(expectedSample);
        if (!agrees) continue;
        final key = _GroupKey(
          scope: NirScope.product,
          entityId: (b['product_id'] as num?)?.toInt() ?? 0,
          // The linked product name wins; legacy product inspections without
          // a `product_id` still carry the product name in `material_name`.
          entityName: _firstNonEmpty(b['product_name'], b['material_name']),
          parameter: param,
        );
        (groups[key] ??= []).add((
          point: NirValidationPoint(
            inspectionId: (b['inspection_id'] as num?)?.toInt() ?? 0,
            entryCode: '${b['entry_code'] ?? ''}',
            inspectionDate: substr10('${b['inspection_date'] ?? ''}'),
            sampleName: displayName,
            nirValue: nirValue,
            labValue: labValue,
          ),
          unit: _unitOf(t, units),
        ));
      }
    }
  }

  // ── Queries ──────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> _listRawInspections(
    Database db,
    String horizon,
  ) async {
    var where = "inspection_kind = 'raw' AND deleted_at IS NULL";
    final args = <Object?>[];
    if (horizon.isNotEmpty) {
      where += ' AND substr(inspection_date, 1, 10) >= ?';
      args.add(substr10(horizon));
    }
    return db.query(
      'inspections',
      columns: [
        'id',
        'entry_code',
        'inspection_date',
        'material_id',
        'material_name',
        'physical_results_json',
        'chemical_results_json',
        'sample_names_json',
      ],
      where: where,
      whereArgs: args,
      orderBy: 'inspection_date ASC, id ASC',
    );
  }

  Future<List<Map<String, Object?>>> _listBatchSamples(
    Database db,
    String horizon,
  ) async {
    var where = "i.inspection_kind = 'product' AND i.deleted_at IS NULL";
    final args = <Object?>[];
    if (horizon.isNotEmpty) {
      where += ' AND substr(i.inspection_date, 1, 10) >= ?';
      args.add(substr10(horizon));
    }
    return db.rawQuery('''
      SELECT b.id AS batch_sample_id, b.sample_no, b.sample_name AS batch_sample_name,
             b.physical_results_json, b.chemical_results_json,
             i.id AS inspection_id, i.entry_code, i.inspection_date,
             i.product_id, i.material_name, p.name AS product_name
      FROM product_batch_samples b
      JOIN inspections i ON i.id = b.batch_id
      LEFT JOIN lab_products p ON p.id = i.product_id
      WHERE $where
      ORDER BY i.inspection_date ASC, b.id ASC
      ''', args);
  }

  /// Resolves each lab result's canonical parameter name and its unit: the
  /// linked `parameters` name/unit win, the analysis name/unit fall back.
  Future<List<Map<String, Object?>>> _listLabTests(Database db) =>
      db.rawQuery('''
      SELECT t.id, t.source_type, t.entry_code, t.sample_name, t.result_text,
             a.name AS analysis_name, a.unit AS analysis_unit,
             p.parameter_name AS param_name, p.unit AS param_unit
      FROM lab_sample_tests t
      LEFT JOIN lab_analyses a ON a.id = t.analysis_id
      LEFT JOIN parameters p ON p.id = a.parameter_id
      ''');

  /// Every parameter's unit from the `parameters` master table, keyed by the
  /// normalized parameter name.
  Future<Map<String, String>> _loadUnits(Database db) async {
    final rows = await db.query(
      'parameters',
      columns: ['parameter_name', 'unit'],
    );
    return {
      for (final r in rows) _normKey(r['parameter_name']): '${r['unit'] ?? ''}',
    };
  }

  static String? _asString(Object? value) =>
      value == null ? null : value as String;

  /// First non-empty, trimmed value among [first]/[second] (e.g. the linked
  /// product name, then the legacy `material_name`); empty when both are blank.
  static String _firstNonEmpty(Object? first, Object? second) {
    for (final value in [first, second]) {
      final s = '${value ?? ''}'.trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  // ── Helpers ──────────────────────────────────────────────────────────

  static String _paramName(Map<String, Object?> test) =>
      '${test['param_name'] ?? test['analysis_name'] ?? ''}'.trim();

  static String _unitOf(Map<String, Object?> test, Map<String, String> units) {
    final unit = '${test['param_unit'] ?? ''}'.trim();
    if (unit.isNotEmpty) return unit;
    final analysisUnit = '${test['analysis_unit'] ?? ''}'.trim();
    if (analysisUnit.isNotEmpty) return analysisUnit;
    return units[_normKey(test['param_name'])] ?? '';
  }

  static String substr10(String value) =>
      value.length >= 10 ? value.substring(0, 10) : value;

  static String _normKey(Object? key) {
    final s = '$key'.trim().toLowerCase();
    return s.replaceAll(RegExp(r'[\u0640\s]+'), '').replaceAll('%', '');
  }

  /// Merges the physical + chemical result maps of one record into
  /// `normalizedKey -> scalar-or-list` (keeps raw strings; parsing happens at
  /// the pairing site).
  static Map<String, Object?> _flattenValues(
    Map<String, dynamic> physical,
    Map<String, dynamic> chemical,
  ) => {
    for (final e in {...physical, ...chemical}.entries)
      _normKey(e.key): e.value,
  };

  /// `chemical_results_json` of a batch sample is a list of
  /// `{name, result, unit}` — flatten it back into a name→result map.
  static Map<String, dynamic> _flattenChemical(List<dynamic> items) => {
    for (final e in items)
      if (e is Map && '${e['name'] ?? ''}'.trim().isNotEmpty)
        '${e['name'] ?? ''}': e['result'],
  };

  /// Picks the NIR number for this test inside a results value.
  ///
  /// Scalars (and single-element multi-sample lists) pair directly; true
  /// multi-sample lists pair by sample-name equality against
  /// `sample_names_json` — an unmatched multi-sample value is skipped rather
  /// than guessed.
  double? _nirFor(Object? value, List<dynamic> sampleNames, Object? testName) {
    if (value is List) {
      if (value.isEmpty) return null;
      if (value.length == 1) return parseNumeric(value.first);
      if ('$testName'.trim().isEmpty) return null;
      final target = _normKey(testName);
      for (var i = 0; i < sampleNames.length && i < value.length; i++) {
        if (_normKey(sampleNames[i]) == target) {
          return parseNumeric(value[i]);
        }
      }
      return null;
    }
    return parseNumeric(value);
  }
}

/// Grouping key: one stats row per (scope × entity × parameter).
class _GroupKey {
  const _GroupKey({
    required this.scope,
    required this.entityId,
    required this.entityName,
    required this.parameter,
  });

  final NirScope scope;
  final int entityId;
  final String entityName;
  final String parameter;

  @override
  bool operator ==(Object other) =>
      other is _GroupKey &&
      other.scope == scope &&
      other.entityId == entityId &&
      other.entityName == entityName &&
      other.parameter == parameter;

  @override
  int get hashCode => Object.hash(scope, entityId, entityName, parameter);
}

/// Parses a numeric lab/NIR result: keeps the leading number out of any
/// trailing text (`%`, units). Returns null for non-numeric results.
double? parseNumeric(Object? value) {
  final raw = '${value ?? ''}'.trim();
  if (raw.isEmpty || raw == '-') return null;
  final m = RegExp(r'-?\s*\d+(?:\.\d+)?').firstMatch(raw);
  if (m == null) return null;
  return double.tryParse(m.group(0)!.replaceAll(' ', ''));
}
