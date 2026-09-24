import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';

import '../../../core/constants/app_errors.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';
import '../../reference/data/reference_repo.dart';
import '../../reports/data/report_html_builder.dart';
import '../domain/inspection_rules.dart';

/// Inspection repository (port of InspectionService).
class InspectionRepo {
  final DatabaseHelper dbHelper;
  final ReferenceRepo referenceRepo;
  /// Optional full HTML renderer (Phase 2). When null (tests), writes fall
  /// back to the minimal preview snippet; when present, `report_html` is
  /// regenerated after create/decision/data changes (refresh_report_html).
  final ReportHtmlBuilder? htmlBuilder;

  InspectionRepo({
    required this.dbHelper,
    required this.referenceRepo,
    this.htmlBuilder,
  });

  Future<Database> get _db => dbHelper.database;

  // ── Normalization helpers ─────────────────────────────────────

  static List<String> normalizeSampleNames(dynamic raw) {
    var names = <String>[];
    if (raw is List) {
      names = [
        for (final n in raw)
          if ('$n'.trim().isNotEmpty) '$n'.trim().substring(0, '$n'.trim().length.clamp(0, 50)),
      ];
    }
    if (names.length > 3) {
      throw ValidationError(AppErrors.inspectionMaxSamples);
    }
    if (names.isEmpty) names = ['Result'];
    return names;
  }

  static void validateResultArrays(
    Map<String, dynamic> physical,
    Map<String, dynamic> chemical,
    int sampleCount,
  ) {
    void check(String label, Map<String, dynamic> results) {
      results.forEach((key, value) {
        if (value is List) {
          if (value.length != sampleCount) {
            throw ValidationError(
                '$label result ($key) must provide a value for each of the $sampleCount sample(s).');
          }
        } else if (sampleCount != 1) {
          throw ValidationError(
              '$label result ($key) must provide one value per sample ($sampleCount).');
        }
      });
    }

    check('Physical', physical);
    check('Chemical', chemical);
  }

  static String _truncate(dynamic v, int max) {
    final s = '$v';
    if (s.length > max) return s.substring(0, max);
    return s;
  }

  static Map<String, dynamic> normalizePhysicalResults(
      Map<String, dynamic>? raw, Map<String, dynamic> reference) {
    final out = <String, dynamic>{};
    (raw ?? {}).forEach((key, value) {
      if (!reference.containsKey(key)) return;
      if (value is List) {
        out[key] = [for (final item in value) _truncate(item ?? '', 50)];
      } else {
        out[key] = _truncate(value ?? '', 50);
      }
    });
    return out;
  }

  static Map<String, dynamic> normalizeChemicalResults(
      Map<String, dynamic>? raw, Map<String, dynamic> reference) {
    final out = <String, dynamic>{};
    Map<String, dynamic>.from(raw ?? {}).forEach((key, value) {
      if (!reference.containsKey(key)) return;
      if (value is List) {
        out[key] = [
          for (final item in value)
            normalizeNonNegativeNumericText('${item ?? ''}', 'Chemical result ($key)')
        ];
      } else {
        out[key] = normalizeNonNegativeNumericText(
            '${value ?? ''}', 'Chemical result ($key)');
      }
    });
    return out;
  }

  // ── Base payload ──────────────────────────────────────────────

  Future<Map<String, dynamic>> buildBasePayload(
    Map<String, dynamic> payload,
    UserContext user, {
    bool validateDecision = true,
  }) async {
    final materialId = int.tryParse('${payload['material_id'] ?? 0}') ?? 0;
    if (materialId == 0) throw ValidationError(AppErrors.materialSelectionRequired);
    final material = await referenceRepo.getMaterial(materialId,
        inspectionDate: '${payload['inspection_date'] ?? todayIso()}');
    if ((material['active'] as num?) != 1) {
      throw const ValidationError(
          'Selected material is inactive (archived) and cannot be used in a new inspection.');
    }
    final inspectionDate = '${payload['inspection_date'] ?? todayIso()}';
    final entryCode =
        '${payload['entry_code'] ?? ''}'.trim().isNotEmpty
            ? '${payload['entry_code']}'.trim()
            : '${material['next_entry_code']}';

    final physicalRef = Map<String, dynamic>.from(material['physical_reference'] ?? {});
    final chemicalRef = Map<String, dynamic>.from(material['chemical_reference'] ?? {});

    final physicalResults = normalizePhysicalResults(
        _asStringMap(payload['physical_results']), physicalRef);
    final chemicalResults = normalizeChemicalResults(
        _asStringMap(payload['chemical_results']), chemicalRef);
    final sampleNames = normalizeSampleNames(payload['sample_names']);
    validateResultArrays(physicalResults, chemicalResults, sampleNames.length);

    final sampleTakenBy =
        '${payload['sample_taken_by'] ?? payload['specialist_name'] ?? ''}'.trim();
    if (sampleTakenBy.length < 3) {
      throw ValidationError(AppErrors.sampleTakerMin3);
    }
    final supplier = '${payload['supplier'] ?? ''}'.trim();
    if (supplier.length < 3) {
      throw ValidationError(AppErrors.supplierMin3);
    }
    final quantity = normalizeNonNegativeNumericText('${payload['quantity'] ?? ''}',
        'Quantity', allowEmpty: true);
    final rejectedQty = normalizeNonNegativeNumericText(
        '${payload['rejected_quantity'] ?? ''}',
        'Rejected quantity',
        allowEmpty: true);
    final truckNumber = truncateText('${payload['truck_number'] ?? ''}', 10);
    final decisionReason = truncateText('${payload['decision_reason'] ?? ''}', 250);
    final followUpNote = truncateText('${payload['follow_up_note'] ?? ''}', 250);

    final base = <String, dynamic>{
      'material_id': material['id'],
      'material_name': material['material_name'],
      'material_code': material['material_code'],
      'inspection_date': inspectionDate,
      'expiry_date': '${payload['expiry_date'] ?? ''}'.trim(),
      'entry_code': entryCode,
      'supplier': supplier,
      'truck_number': truckNumber,
      'quantity': quantity,
      'sample_taken_by': sampleTakenBy,
      'specialist_name': user.fullName,
      'physical_reference': physicalRef,
      'chemical_reference': chemicalRef,
      'physical_results': physicalResults,
      'chemical_results': chemicalResults,
      'decision_status': '${payload['decision_status'] ?? 'APPROVED'}',
      'decision_reason': decisionReason,
      'follow_up_note': followUpNote,
      'rejected_quantity': rejectedQty,
      'sample_names': sampleNames,
      'created_by': user.id,
      'created_by_name': user.fullName,
    };
    final normalized = normalizeDecisionFields(base);
    base.addAll(normalized);
    if (validateDecision) validateDecisionFields(base);
    return base;
  }

  static Map<String, dynamic> _asStringMap(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return {};
  }

  // ── Create ────────────────────────────────────────────────────

  Future<Map<String, dynamic>> create(Map<String, dynamic> payload, UserContext user) async {
    final db = await _db;
    final base = await buildBasePayload(payload, user);
    final existing = await db
        .query('inspections', where: 'entry_code = ?', whereArgs: [base['entry_code']]);
    if (existing.isNotEmpty) {
      throw ValidationError(AppErrors.entryCodeAlreadyExists);
    }
    final timestamp = nowIso();
    base['decision_version'] = 1;
    base['created_at'] = timestamp;
    base['updated_at'] = timestamp;
    base['snapshot_json'] = _buildSnapshot(base);
    base['report_html'] = _simplePreviewHtml(base);

    final id = await db.insert('inspections', {
      'entry_code': base['entry_code'],
      'material_id': base['material_id'],
      'material_name': base['material_name'],
      'material_code': base['material_code'],
      'inspection_date': base['inspection_date'],
      'expiry_date': base['expiry_date'],
      'supplier': base['supplier'],
      'truck_number': base['truck_number'],
      'quantity': base['quantity'],
      'sample_taken_by': base['sample_taken_by'],
      'specialist_name': base['specialist_name'],
      'physical_results_json': jsonDumps(base['physical_results']),
      'chemical_results_json': jsonDumps(base['chemical_results']),
      'physical_reference_json': jsonDumps(base['physical_reference']),
      'chemical_reference_json': jsonDumps(base['chemical_reference']),
      'decision_status': base['decision_status'],
      'decision_reason': base['decision_reason'],
      'follow_up_note': base['follow_up_note'],
      'rejected_quantity': base['rejected_quantity'],
      'report_html': base['report_html'],
      'snapshot_json': base['snapshot_json'],
      'sample_names_json': jsonDumps(base['sample_names']),
      'decision_version': base['decision_version'],
      'created_by': base['created_by'],
      'created_by_name': base['created_by_name'],
      'last_pdf_path': '',
      'created_at': timestamp,
      'updated_at': timestamp,
    });
    await _refreshReportHtml(id);
    return getById(id);
  }

  /// Port of `InspectionService.refresh_report_html` — reload the full row
  /// (with status history + injected lab tests), re-render the stored HTML and
  /// persist it. Fails soft so report generation never blocks the mutation.
  Future<void> _refreshReportHtml(int inspectionId) async {
    final builder = htmlBuilder;
    if (builder == null) return;
    try {
      final row = await getById(inspectionId);
      final html = await builder.renderInspectionHtml(row);
      final db = await _db;
      await db.update(
        'inspections',
        {'report_html': html},
        where: 'id = ?',
        whereArgs: [inspectionId],
      );
    } catch (e, st) {
      debugPrint('[inspections] report_html refresh failed for #$inspectionId: $e\n$st');
    }
  }

  String _buildSnapshot(Map<String, dynamic> b) => jsonDumps({
        'material_id': b['material_id'],
        'material_name': b['material_name'],
        'material_code': b['material_code'],
        'physical_reference': b['physical_reference'],
        'chemical_reference': b['chemical_reference'],
        'physical_results': b['physical_results'],
        'chemical_results': b['chemical_results'],
        'sample_names': b['sample_names'],
      });

  static String _simplePreviewHtml(Map<String, dynamic> b) {
    final name = '<b>${b['material_name']}</b> (${b['entry_code']})';
    return '<html><body><h3>Material Lab</h3><p>$name</p></body></html>';
  }

  // ── List / Get ────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> list({
    String query = '',
    int limit = 5000,
    int offset = 0,
    String orderBy = 'id DESC',
  }) async {
    final db = await _db;
    if (query.trim().isEmpty) {
      final rows = await db.query('inspections',
          orderBy: orderBy, limit: limit, offset: offset);
      return [for (final r in rows) serializeInspectionRow(Map<String, dynamic>.from(r))];
    }
    final like = '%${query.trim()}%';
    final rows = await db.query(
      'inspections',
      where:
          '(entry_code LIKE ? OR material_name LIKE ? OR supplier LIKE ? OR truck_number LIKE ?)',
      whereArgs: [like, like, like, like],
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
    return [for (final r in rows) serializeInspectionRow(Map<String, dynamic>.from(r))];
  }

  Future<int> count({String query = ''}) async {
    final db = await _db;
    if (query.trim().isEmpty) {
      return Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) AS c FROM inspections')) ?? 0;
    }
    final like = '%${query.trim()}%';
    return Sqflite.firstIntValue(await db.rawQuery(
            'SELECT COUNT(*) AS c FROM inspections WHERE entry_code LIKE ? OR material_name LIKE ? OR supplier LIKE ?',
            [like, like, like])) ??
        0;
  }

  Future<Map<String, dynamic>> getById(int id) async {
    final db = await _db;
    final rows = await db.query('inspections', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) throw NotFoundError(AppErrors.inspectionNotFound);
    final serialized = serializeInspectionRow(Map<String, dynamic>.from(rows.first));
    serialized['status_history'] = await getStatusHistory(id);
    return serialized;
  }

  Future<List<Map<String, dynamic>>> getStatusHistory(int inspectionId) async {
    final db = await _db;
    final rows = await db.query(
      'inspection_status_history',
      where: 'inspection_id = ?',
      whereArgs: [inspectionId],
      orderBy: 'version DESC, id DESC',
    );
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  Future<void> _insertStatusHistory(Map<String, dynamic> h) async {
    final db = await _db;
    await db.insert('inspection_status_history', {
      'inspection_id': h['inspection_id'],
      'version': h['version'],
      'old_status': h['old_status'],
      'new_status': h['new_status'],
      'change_reason': h['change_reason'],
      'follow_up_note': h['follow_up_note'],
      'rejected_quantity': h['rejected_quantity'],
      'changed_by': h['changed_by'],
      'changed_by_name': h['changed_by_name'],
      'changed_at': h['changed_at'],
    });
  }

  // ── Status update ─────────────────────────────────────────────

  Future<Map<String, dynamic>> updateStatus(
      int inspectionId, Map<String, dynamic> payload, UserContext user) async {
    final db = await _db;
    final existingRaw = await db.query('inspections', where: 'id = ?', whereArgs: [inspectionId]);
    if (existingRaw.isEmpty) throw NotFoundError(AppErrors.inspectionNotFound);
    final existing = serializeInspectionRow(Map<String, dynamic>.from(existingRaw.first));

    ensureWithinMaxVersions(existing['decision_version'] as int? ?? 1);

    final updated = <String, dynamic>{
      ...existing,
      'decision_status': '${payload['decision_status'] ?? existing['decision_status']}',
      'decision_reason': '${payload['decision_reason'] ?? ''}'.trim(),
      'follow_up_note': '${payload['follow_up_note'] ?? ''}'.trim(),
      'rejected_quantity': '${payload['rejected_quantity'] ?? ''}'.trim(),
      'specialist_name': user.fullName,
    };
    final normalized = normalizeDecisionFields(updated);
    updated.addAll(normalized);
    validateDecisionFields(updated);

    final unchanged = normalized['decision_status'] == '${existing['decision_status']}' &&
        normalized['decision_reason'] == '${existing['decision_reason'] ?? ''}' &&
        normalized['follow_up_note'] == '${existing['follow_up_note'] ?? ''}' &&
        normalized['rejected_quantity'] == '${existing['rejected_quantity'] ?? ''}';
    if (unchanged) throw ValidationError(AppErrors.noDecisionChange);

    final statusChanged = normalized['decision_status'] != '${existing['decision_status']}';
    final changedAt = nowIso();
    final version = statusChanged
        ? (existing['decision_version'] as int? ?? 1) + 1
        : (existing['decision_version'] as int? ?? 1);

    await db.update(
      'inspections',
      {
        'decision_status': normalized['decision_status'],
        'decision_reason': normalized['decision_reason'],
        'follow_up_note': normalized['follow_up_note'],
        'rejected_quantity': normalized['rejected_quantity'],
        'decision_version': version,
        'updated_at': changedAt,
        'last_pdf_path': '',
        'specialist_name': user.fullName,
      },
      where: 'id = ?',
      whereArgs: [inspectionId],
    );

    if (statusChanged) {
      await _insertStatusHistory({
        'inspection_id': inspectionId,
        'version': version,
        'old_status': existing['decision_status'],
        'new_status': normalized['decision_status'],
        'change_reason': normalized['decision_reason'],
        'follow_up_note': normalized['follow_up_note'],
        'rejected_quantity': normalized['rejected_quantity'],
        'changed_by': user.id,
        'changed_by_name': user.fullName,
        'changed_at': changedAt,
      });
    }
    await _refreshReportHtml(inspectionId);
    return getById(inspectionId);
  }

  // ── Data update ───────────────────────────────────────────────

  Future<Map<String, dynamic>> update(
      int inspectionId, Map<String, dynamic> payload, UserContext user) async {
    final db = await _db;
    final existingRaw = await db.query('inspections', where: 'id = ?', whereArgs: [inspectionId]);
    if (existingRaw.isEmpty) throw NotFoundError(AppErrors.inspectionNotFound);
    final existing = serializeInspectionRow(Map<String, dynamic>.from(existingRaw.first));

    final physicalRef = Map<String, dynamic>.from(existing['physical_reference'] ?? {});
    final chemicalRef = Map<String, dynamic>.from(existing['chemical_reference'] ?? {});

    final newPhysical = normalizePhysicalResults(
        _asStringMap(payload['physical_results']), physicalRef);
    final newChemical = normalizeChemicalResults(
        _asStringMap(payload['chemical_results']), chemicalRef);

    final physical = Map<String, dynamic>.from(existing['physical_results'] ?? {})
      ..addAll(newPhysical);
    final chemical = Map<String, dynamic>.from(existing['chemical_results'] ?? {})
      ..addAll(newChemical);

    final sampleNames = normalizeSampleNames(
        payload['sample_names'] ?? existing['sample_names']);
    validateResultArrays(physical, chemical, sampleNames.length);

    final supplier =
        '${payload['supplier'] ?? existing['supplier'] ?? ''}'.trim();
    if (supplier.length < 3) {
      throw ValidationError(AppErrors.supplierMin3);
    }
    final sampleTakenBy =
        '${payload['sample_taken_by'] ?? existing['sample_taken_by'] ?? ''}'.trim();
    if (sampleTakenBy.length < 3) {
      throw ValidationError(AppErrors.sampleTakerMin3);
    }

    final quantity = normalizeNonNegativeNumericText(
        '${payload['quantity'] ?? existing['quantity'] ?? ''}', 'Quantity',
        allowEmpty: true);
    final truckNumber = truncateText(
        '${payload['truck_number'] ?? existing['truck_number'] ?? ''}', 10);
    final timestamp = nowIso();
    // Rebuild the snapshot with the refreshed results/samples so the stored
    // copy never drifts from the live columns (parity inspection.py:843-852).
    final snapshot = _buildSnapshot({
      'material_id': existing['material_id'],
      'material_name': existing['material_name'],
      'material_code': existing['material_code'],
      'physical_reference': physicalRef,
      'chemical_reference': chemicalRef,
      'physical_results': physical,
      'chemical_results': chemical,
      'sample_names': sampleNames,
    });

    await db.update(
      'inspections',
      {
        'supplier': supplier,
        'truck_number': truckNumber,
        'quantity': quantity,
        'sample_taken_by': sampleTakenBy,
        'physical_results_json': jsonDumps(physical),
        'chemical_results_json': jsonDumps(chemical),
        'sample_names_json': jsonDumps(sampleNames),
        'snapshot_json': snapshot,
        'updated_at': timestamp,
        'last_pdf_path': '',
      },
      where: 'id = ?',
      whereArgs: [inspectionId],
    );
    await _refreshReportHtml(inspectionId);
    return getById(inspectionId);
  }

  Future<void> markPdfExported(int inspectionId, String pdfPath) async {
    final db = await _db;
    await db.update('inspections', {'last_pdf_path': pdfPath, 'updated_at': nowIso()},
        where: 'id = ?', whereArgs: [inspectionId]);
  }

  Future<void> delete(int inspectionId) async {
    final db = await _db;
    await db.delete('inspections', where: 'id = ?', whereArgs: [inspectionId]);
  }
}

/// Minimal user context for repository calls.
class UserContext {
  final int? id;
  final String fullName;
  final String role;
  const UserContext({this.id, required this.fullName, required this.role});
}

String normalizeNonNegativeNumericText(
  String value,
  String label, {
  bool allowEmpty = false,
  int? maxLength,
}) {
  final s = value.trim();
  if (s.isEmpty) {
    if (allowEmpty) return '';
    throw ValidationError(AppErrors.fieldValueRequired(label));
  }
  if (maxLength != null && s.length > maxLength) {
    throw ValidationError(AppErrors.fieldExceedsMaxLength(label));
  }
  final cleaned = s.replaceAll(',', '.');
  final n = double.tryParse(cleaned);
  if (n == null || n < 0) {
    throw ValidationError(AppErrors.fieldNonNegative(label));
  }
  return s;
}

String truncateText(String value, int max) =>
    value.length > max ? value.substring(0, max) : value;