import '../../../core/security/secure_field_access.dart';
import 'dart:convert';
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
import '../../../core/utils/decimal_input.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/nir_validation_repository.dart';
import '../core/lab_result_format.dart';

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
    this.secureAccess,
  });

  final DatabaseHelper dbHelper;
  final WriteGuard guard;
  final SyncQueue queue;
  final AuditLogger audit;
  final SecureFieldAccess? secureAccess;

  static final SyncEntity _entity = syncEntities.firstWhere(
    (e) => e.type == 'nirValidationSettings',
  );

  // Local row numbers depend on download order, not the reset's chronology.
  static const _resetOrder =
      'julianday(created_at) DESC, remote_id DESC, id DESC';

  @override
  Future<void> setPointIncluded(NirValidationPoint point, bool included) async {
    if (!guard.allows(Permission.labResultsUpdate.id)) {
      throw AuthorizationError(AppErrors.notAuthorizedForOperation);
    }
    if (point.selectionKey.isEmpty ||
        point.referenceRemoteId.isEmpty ||
        point.referenceId <= 0) {
      throw ValidationError(
        AppText.t(
          'حدّث البيانات قبل تغيير القراءة',
          'Refresh data before changing this reading',
        ),
      );
    }
    if (point.included == included) return;
    await dbHelper.businessTransaction((txn) async {
      final report = await _computeWithDb(txn);
      final matches = [
        for (final stats in report.stats)
          for (final current in stats.allPoints)
            if (current.selectionKey == point.selectionKey &&
                current.referenceRemoteId == point.referenceRemoteId)
              current,
      ];
      if (matches.length != 1 ||
          matches.single.referenceVersion != point.referenceVersion ||
          matches.single.nirValue != point.nirValue ||
          matches.single.labValue != point.labValue ||
          matches.single.included != point.included) {
        throw ValidationError(
          AppText.t(
            'تغيّرت القراءة؛ حدّث البيانات وراجعها مجددًا',
            'The reading changed; refresh and review it again',
          ),
        );
      }
      final rows = await txn.query(
        'lab_sample_tests',
        where: 'id = ? AND remote_id = ? AND deleted_at IS NULL',
        whereArgs: [point.referenceId, point.referenceRemoteId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw ValidationError(
          AppText.t('القراءة غير متاحة', 'Reading unavailable'),
        );
      }
      final row = Map<String, dynamic>.from(rows.single);
      final excluded = _excludedKeys(row['nir_exclusions_json']);
      if (included) {
        excluded.remove(point.selectionKey);
      } else {
        excluded.add(point.selectionKey);
      }
      final encoded = jsonEncode(excluded.toList()..sort());
      if (utf8.encode(encoded).length > 65536) {
        throw ValidationError(
          AppText.t(
            'تجاوز سجل الاستبعاد الحد المسموح',
            'Calibration exclusions exceed the allowed size',
          ),
        );
      }
      row['nir_exclusions_json'] = encoded;
      row['updated_at'] = nowIso();
      await txn.update(
        'lab_sample_tests',
        {'nir_exclusions_json': encoded, 'updated_at': row['updated_at']},
        where: 'id = ?',
        whereArgs: [point.referenceId],
      );
      await enqueueLocalChange(
        executor: txn,
        entity: SyncEntity.byType('labResult')!,
        row: row,
        operation: 'update',
        queue: queue,
        organizationId: guard.organizationId,
        uid: guard.uid,
        deviceId: guard.deviceId,
      );
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labResult',
        entityId: point.referenceRemoteId,
        details: {
          'action': 'nir_point_inclusion',
          'selectionKey': point.selectionKey,
          'included': included,
          'entryCode': point.entryCode,
          'sampleName': point.sampleName,
          'actor': guard.actorName,
        },
      );
    });
  }

  static Set<String> _excludedKeys(Object? raw) {
    if (raw == null || raw == '') return {};
    try {
      final values = jsonDecode('$raw');
      if (values is List && values.every((key) => key is String)) {
        return values.cast<String>().toSet();
      }
    } on FormatException {
      /* reported as a data error below */
    }
    throw ValidationError(
      AppText.t(
        'سجل استبعاد قراءات NIR غير صالح',
        'Invalid NIR exclusion data',
      ),
    );
  }

  String _selectionKey(
    Map<String, Object?> source,
    String parameter,
    String sample, {
    bool batch = false,
  }) {
    final inspection =
        '${source[batch ? 'inspection_remote_id' : 'remote_id'] ?? ''}';
    final batchId = batch ? '${source['batch_remote_id'] ?? ''}' : '';
    if (inspection.isEmpty || (batch && batchId.isEmpty)) return '';
    return jsonEncode([
      1,
      inspection,
      batchId,
      _normKey(parameter),
      _normKey(sample),
    ]);
  }

  @override
  Future<NirValidationSettings?> getSettings() async {
    final db = await dbHelper.readDatabase;
    return _getSettings(db);
  }

  Future<NirValidationSettings?> _getSettings(DatabaseExecutor db) async {
    final rows = await db.query(
      'nir_validation_settings',
      where: "COALESCE(scope, '') = '' AND deleted_at IS NULL",
      orderBy: _resetOrder,
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
      where: 'deleted_at IS NULL',
      orderBy: _resetOrder,
      limit: limit,
    );
    final visible = [
      for (final r in rows)
        if (r['secure_result'] != 1 || secureAccess?.enabled == true)
          Map<String, dynamic>.from(r),
    ];
    final revealed = secureAccess == null
        ? visible
        : await secureAccess!.revealMany('nirValidationSettings', visible);
    return [
      for (final r in revealed)
        if (r['secure_result'] != 1 || secureAccess?.enabled == true)
          NirValidationSettings.fromMap(
            secureAccess?.enabled == true
                ? r
                : SecureFieldAccess.publicRecord(r),
          ),
    ];
  }

  @override
  Future<NirValidationSettings> resetValidation(
    String startDate, {
    String note = '',
    NirScope? scope,
    int? entityId,
    String entityName = '',
    String parameter = '',
    NirAppliedCorrection? appliedCorrection,
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
    if (appliedCorrection != null &&
        (scope == null ||
            !appliedCorrection.slope.isFinite ||
            !appliedCorrection.intercept.isFinite)) {
      throw ValidationError(
        AppText.t(
          'أدخل معاملات تصحيح صالحة لتحليل محدد',
          'Enter finite correction coefficients for one analysis',
        ),
      );
    }
    final entity = scope == null ? null : entityId;
    final now = nowIso();
    final row = <String, dynamic>{
      'start_date': cleanDate,
      'reset_note': note.trim(),
      'reset_by': guard.uid,
      'reset_by_name': guard.actorName,
      'scope': scopeValue,
      'reference_version': 1,
      'entity_id': entity,
      'entity_name': scope == null ? '' : cleanEntity,
      'parameter': scope == null ? '' : cleanParam,
      'created_at': now,
      'updated_at': now,
    };
    late NirCalibrationSnapshot snapshot;
    final id = await dbHelper.businessTransaction((txn) async {
      if (scope != null) {
        if (entityId == null || entityId <= 0) {
          throw ValidationError(
            AppText.t(
              'حدد الخامة أو المنتج المراد تصفيره',
              'Pick the material or product to reset',
            ),
          );
        }
        final raw = scope == NirScope.rawMaterial;
        final targets = await txn.query(
          raw ? 'reference_materials' : 'lab_products',
          columns: [raw ? 'material_name' : 'name'],
          where: 'id = ? AND deleted_at IS NULL',
          whereArgs: [entityId],
          limit: 1,
        );
        if (targets.isEmpty) {
          throw ValidationError(
            AppText.t(
              'مرجع التصفير غير متاح؛ حدّث البيانات أولًا',
              'Reset target unavailable; refresh data first',
            ),
          );
        }
        row[raw ? 'material_id' : 'product_id'] = entityId;
        row['entity_name'] = targets.single[raw ? 'material_name' : 'name'];
      }
      // Capture the previous cycle from the same transaction before changing
      // its horizon. Snapshot and reset are approved as one business effect.
      final report = await _computeWithDb(txn);
      snapshot = NirCalibrationSnapshot(
        capturedAt: now,
        appliedCorrection: appliedCorrection,
        summaries: [
          for (final stat in report.stats)
            if (scope == null ||
                (stat.scope == scope &&
                    stat.entityId == entityId &&
                    _normKey(stat.parameter) == _normKey(cleanParam)))
              _calibrationSummary(stat),
        ],
      );
      row['calibration_snapshot_json'] = jsonEncode(snapshot.toMap());
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
      materialId: row['material_id'] as int?,
      productId: row['product_id'] as int?,
      referenceVersion: 1,
      calibrationSnapshot: snapshot,
      entityName: '${row['entity_name']}',
      parameter: scope == null ? '' : cleanParam,
    );
  }

  @override
  Future<NirValidationReport> compute({String? startDate}) async {
    final db = await dbHelper.readDatabase;
    return db.transaction((txn) => _computeWithDb(txn, startDate: startDate));
  }

  Map<String, dynamic> _calibrationSummary(NirParameterStats stat) {
    double? finite(double value) => value.isFinite ? value : null;
    return {
      'scope': NirValidationSettings.scopeValue(stat.scope),
      'entityName': stat.entityName,
      'parameter': stat.parameter,
      'unit': stat.unit,
      'entityRemoteId': stat.entityRemoteId,
      'horizonStart': stat.horizonStart,
      'count': stat.count,
      'excludedCount': stat.excludedCount,
      'excludedReadings': [
        for (final point in stat.allPoints)
          if (!point.included)
            {
              'referenceRemoteId': point.referenceRemoteId,
              'selectionKey': point.selectionKey,
            },
      ],
      'bias': finite(stat.bias),
      'meanNir': finite(stat.meanNir),
      'meanLab': finite(stat.meanLab),
      'slopeOnly': finite(stat.slopeOnly),
      'slope': stat.count < 2 ? null : finite(stat.slope),
      'intercept': stat.count < 2 ? null : finite(stat.intercept),
      'r2': stat.count < 2 ? null : finite(stat.r2),
      'rmse': stat.count < 2 ? null : finite(stat.rmse),
      'reliability': stat.reliability.name,
      'recommendedMode': stat.adjustmentAdvice.recommended.name,
    };
  }

  Future<NirValidationReport> _computeWithDb(
    DatabaseExecutor db, {
    String? startDate,
  }) async {
    final horizons = await _loadHorizons(db);
    final legacyTargets = await _legacyTargets(db);
    final settings = startDate == null ? await _getSettings(db) : null;
    final globalHorizon = (startDate ?? settings?.startDate ?? '').trim();

    final units = await _loadUnits(db);
    // Fetch only rows on/after the earliest horizon in play; the per-group
    // pass below then applies each group's own (scoped) or the global horizon.
    final fetchFrom = _earliestHorizon(horizons, globalHorizon);
    var rawInspections = await _listRawInspections(db, fetchFrom);
    var batchRows = await _listBatchSamples(db, fetchFrom);
    var labTests = await _listLabTests(db);
    if (secureAccess?.enabled == true) {
      rawInspections = await secureAccess!.revealMany(
        'sample',
        rawInspections.map((r) => Map<String, dynamic>.from(r)).toList(),
      );
      batchRows = await secureAccess!.revealMany(
        'productBatchSample',
        batchRows.map((r) => Map<String, dynamic>.from(r)).toList(),
      );
      labTests = await secureAccess!.revealMany(
        'labResult',
        labTests.map((r) => Map<String, dynamic>.from(r)).toList(),
      );
    }

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
      final own = _scopedHorizon(horizons, key, legacyTargets);
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
          entityRemoteId: key.entityRemoteId,
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

  Future<List<NirValidationSettings>> _loadHorizons(DatabaseExecutor db) async {
    final rows = await db.query(
      'nir_validation_settings',
      where: 'deleted_at IS NULL',
      orderBy: _resetOrder,
    );
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
  /// Legacy records have no global parent. Accept only an unambiguous current
  /// catalogue name; never compare another device's numeric entity_id.
  Future<Map<(String, String), int?>> _legacyTargets(
    DatabaseExecutor db,
  ) async {
    final result = <(String, String), int?>{};
    for (final spec in [
      ('raw_material', 'reference_materials', 'material_name'),
      ('product', 'lab_products', 'name'),
    ]) {
      for (final row in await db.query(
        spec.$2,
        columns: ['id', spec.$3],
        where: 'deleted_at IS NULL',
      )) {
        final key = (spec.$1, _normKey(row[spec.$3]));
        result[key] = result.containsKey(key)
            ? null
            : (row['id'] as num).toInt();
      }
    }
    return result;
  }

  String? _scopedHorizon(
    List<NirValidationSettings> rows,
    _GroupKey key,
    Map<(String, String), int?> legacyTargets,
  ) {
    final scopeValue = NirValidationSettings.scopeValue(key.scope);
    final paramNorm = _normKey(key.parameter);
    for (final r in rows) {
      if (r.isGlobal || r.scope != scopeValue) continue;
      if (_normKey(r.parameter) != paramNorm) continue;
      if (r.referenceVersion == 1 ||
          r.materialId != null ||
          r.productId != null) {
        final target = key.scope == NirScope.rawMaterial
            ? r.materialId
            : r.productId;
        if (target != key.entityId) continue;
      } else {
        final name = _normKey(r.entityName);
        if (name.isEmpty || legacyTargets[(scopeValue, name)] != key.entityId) {
          continue;
        }
      }
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
    for (final t in _latestReferences(labTests)) {
      if (isFailedLabResult(t['result_text'])) continue;
      if (t['source_type'] != 'raw_material') continue;
      final code = _entryCode(t['entry_code']);
      if (code.isEmpty) continue;
      (testsByEntry[code] ??= []).add(t);
    }
    for (final ins in rawInspections) {
      final tests = testsByEntry[_entryCode(ins['entry_code'])];
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
        final unit = _unitOf(t, units);
        final labValue = parseNumeric(t['result_text'], unit: unit);
        if (labValue == null) continue;
        final nirValue = _nirFor(
          value,
          sampleNames,
          t['sample_name'],
          unit: unit,
        );
        if (nirValue == null) continue;
        final key = _GroupKey(
          scope: NirScope.rawMaterial,
          entityId: (ins['material_id'] as num?)?.toInt() ?? 0,
          entityRemoteId: '${ins['entity_remote_id'] ?? ''}',
          entityName: '${ins['material_name'] ?? ''}',
          parameter: param,
        );
        final selection = _selectionKey(
          ins,
          param,
          '${t['sample_name'] ?? ''}',
        );
        (groups[key] ??= []).add((
          point: NirValidationPoint(
            selectionKey: selection,
            referenceId: (t['id'] as num).toInt(),
            referenceRemoteId: '${t['remote_id'] ?? ''}',
            referenceVersion: (t['version'] as num?)?.toInt() ?? 1,
            included: !_excludedKeys(
              t['nir_exclusions_json'],
            ).contains(selection),
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
    for (final t in _latestReferences(labTests)) {
      if (isFailedLabResult(t['result_text'])) continue;
      if (t['source_type'] != 'product') continue;
      final code = _entryCode(t['entry_code']);
      if (code.isEmpty) continue;
      (testsByEntry[code] ??= []).add(t);
    }
    for (final b in batchRows) {
      final tests = testsByEntry[_entryCode(b['entry_code'])];
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
        final unit = _unitOf(t, units);
        final labValue = parseNumeric(t['result_text'], unit: unit);
        if (labValue == null) continue;
        final nirValue = parseNumeric(raw, unit: unit);
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
          entityRemoteId: '${b['entity_remote_id'] ?? ''}',
          // The linked product name wins; legacy product inspections without
          // a `product_id` still carry the product name in `material_name`.
          entityName: _firstNonEmpty(b['product_name'], b['material_name']),
          parameter: param,
        );
        final selection = _selectionKey(b, param, displayName, batch: true);
        (groups[key] ??= []).add((
          point: NirValidationPoint(
            selectionKey: selection,
            referenceId: (t['id'] as num).toInt(),
            referenceRemoteId: '${t['remote_id'] ?? ''}',
            referenceVersion: (t['version'] as num?)?.toInt() ?? 1,
            included: !_excludedKeys(
              t['nir_exclusions_json'],
            ).contains(selection),
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
    DatabaseExecutor db,
    String horizon,
  ) async {
    var where = "i.inspection_kind = 'raw' AND i.deleted_at IS NULL";
    final args = <Object?>[];
    if (horizon.isNotEmpty) {
      where += ' AND substr(i.inspection_date, 1, 10) >= ?';
      args.add(substr10(horizon));
    }
    return db.rawQuery('''
      SELECT i.secure_entry_id, i.id, i.remote_id, i.entry_code, i.inspection_date, i.material_id,
        COALESCE(m.material_name, i.material_name) AS material_name,
        m.remote_id AS entity_remote_id, i.physical_results_json,
        i.chemical_results_json, i.sample_names_json
      FROM inspections i LEFT JOIN reference_materials m ON m.id = i.material_id
      WHERE $where ORDER BY i.inspection_date ASC, i.id ASC
    ''', args);
  }

  Future<List<Map<String, Object?>>> _listBatchSamples(
    DatabaseExecutor db,
    String horizon,
  ) async {
    var where =
        "i.inspection_kind = 'product' AND i.deleted_at IS NULL AND b.deleted_at IS NULL";
    final args = <Object?>[];
    if (horizon.isNotEmpty) {
      where += ' AND substr(i.inspection_date, 1, 10) >= ?';
      args.add(substr10(horizon));
    }
    return db.rawQuery('''
      SELECT b.secure_entry_id, b.remote_id AS remote_id, b.id AS batch_sample_id, b.remote_id AS batch_remote_id,
             i.remote_id AS inspection_remote_id, b.sample_no, b.sample_name AS batch_sample_name,
             b.physical_results_json, b.chemical_results_json,
             i.id AS inspection_id, i.entry_code, i.inspection_date,
             i.product_id, i.material_name, p.name AS product_name, p.remote_id AS entity_remote_id
      FROM product_batch_samples b
      JOIN inspections i ON i.id = b.batch_id
      LEFT JOIN lab_products p ON p.id = i.product_id
      WHERE $where
      ORDER BY i.inspection_date ASC, b.id ASC
      ''', args);
  }

  /// Resolves each lab result's canonical parameter name and its unit: the
  /// linked `parameters` name/unit win, the analysis name/unit fall back.
  Future<List<Map<String, Object?>>> _listLabTests(DatabaseExecutor db) =>
      db.rawQuery('''
      SELECT t.secure_entry_id, t.secure_result, t.id, t.remote_id, t.version, t.nir_exclusions_json, t.tested_at, t.source_type, t.entry_code, t.sample_name, t.result_text,
             a.name AS analysis_name, a.unit AS analysis_unit,
             p.parameter_name AS param_name, p.unit AS param_unit
      FROM lab_sample_tests t
      LEFT JOIN lab_analyses a ON a.id = t.analysis_id
      LEFT JOIN parameters p ON p.id = a.parameter_id
      WHERE t.deleted_at IS NULL
      ORDER BY julianday(t.tested_at) DESC, t.remote_id DESC, t.id DESC
      ''');

  /// One reference per physical sample and canonical parameter. Failed or
  /// nonnumeric attempts cannot supersede a valid measurement. Queries arrive
  /// newest-first, with a global identity tie-breaker for different devices.
  Iterable<Map<String, Object?>> _latestReferences(
    List<Map<String, Object?>> rows,
  ) sync* {
    final seen = <(String, String, String, String)>{};
    for (final row in rows) {
      if (isFailedLabResult(row['result_text']) ||
          parseNumeric(row['result_text'], unit: _unitOf(row, const {})) ==
              null) {
        continue;
      }
      final key = (
        '${row['source_type']}',
        _entryCode(row['entry_code']),
        _normKey(row['sample_name']),
        _normKey(_paramName(row)),
      );
      if (seen.add(key)) yield row;
    }
  }

  /// Every parameter's unit from the `parameters` master table, keyed by the
  /// normalized parameter name.
  Future<Map<String, String>> _loadUnits(DatabaseExecutor db) async {
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

  // Receipt identity is case-sensitive in SQLite and Firestore reservations.
  // Parameter-name normalization must never collapse distinct receipt codes.
  static String _entryCode(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : '';

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
  double? _nirFor(
    Object? value,
    List<dynamic> sampleNames,
    Object? testName, {
    String unit = '',
  }) {
    if (value is List) {
      if (value.isEmpty) return null;
      if (value.length == 1) return parseNumeric(value.first, unit: unit);
      if ('$testName'.trim().isEmpty) return null;
      final target = _normKey(testName);
      for (var i = 0; i < sampleNames.length && i < value.length; i++) {
        if (_normKey(sampleNames[i]) == target) {
          return parseNumeric(value[i], unit: unit);
        }
      }
      return null;
    }
    return parseNumeric(value, unit: unit);
  }
}

/// Grouping key: one stats row per (scope × entity × parameter).
class _GroupKey {
  const _GroupKey({
    required this.scope,
    required this.entityId,
    this.entityRemoteId = '',
    required this.entityName,
    required this.parameter,
  });

  final NirScope scope;
  final int entityId;
  final String entityRemoteId;
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

/// Accepts a complete finite measurement with an optional known unit suffix.
/// Censored results (<, >, ≤, ≥), arbitrary text and malformed numbers do not
/// represent exact calibration points and must never be coerced into one.
double? parseNumeric(Object? value, {String unit = ''}) {
  if (value is num) return value.isFinite ? value.toDouble() : null;
  final raw = normalizeDecimalInput('${value ?? ''}');
  final suffix = unit.trim().isEmpty
      ? r'%|٪|ppm|ppb|mg/kg|g/kg|mg/L|g/L'
      : unit.trim() == '%' || unit.trim() == '٪'
      ? r'%|٪'
      : RegExp.escape(normalizeDecimalInput(unit));
  final m = RegExp(
    r'^([+-]?\s*(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?)\s*(?:' +
        suffix +
        r')?$',
    caseSensitive: false,
  ).firstMatch(raw);
  if (m == null) return null;
  final number = double.tryParse(m.group(1)!.replaceAll(RegExp(r'\s'), ''));
  return number != null && number.isFinite ? number : null;
}
