import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/constants/app_errors.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/security/local_secret.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';
import '../../inspections/data/inspection_repo.dart';
import '../../lab/data/lab_repo.dart';
import '../../reference/data/reference_repo.dart';
import '../../settings/data/settings_repo.dart';
import 'pdf_renderer.dart';
import 'report_builder.dart';

/// A rendered report document (PDF bytes + suggested filename).
class ReportDoc {
  const ReportDoc({
    required this.filename,
    required this.bytes,
    this.title,
  });

  /// Suggested file name (sanitized, already ends with `.pdf`).
  final String filename;

  /// Ready-to-write PDF bytes.
  final Uint8List bytes;

  /// Human-readable title for UI dialogs/headers.
  final String? title;
}

/// Port of the report data layer: queries in core/controller.py report
/// endpoints + report.py rendering flow, producing PDF bytes via
/// [PdfRenderer] and [report_builder] context builders.
class ReportService {
  ReportService({
    required this.dbHelper,
    required this.settingsRepo,
    required this.inspectionRepo,
    required this.labRepo,
    required this.secret,
  });

  final DatabaseHelper dbHelper;
  final SettingsRepo settingsRepo;
  final InspectionRepo inspectionRepo;
  final LabRepo labRepo;
  final LocalSecret secret;

  /// Summary columns used by period reports (mirrors controller.py
  /// `report_columns`). Summary rows are NOT JSON-enriched.
  static const String reportColumns = '''
      id, entry_code, material_name, material_code, inspection_date, expiry_date, supplier, quantity,
      sample_taken_by, specialist_name, decision_status, decision_reason, follow_up_note,
      rejected_quantity, created_by_name, created_at, updated_at
  ''';

  Future<Map<String, dynamic>> _settings() => settingsRepo.getSettings();

  Future<List<int>> _secretBytes() => secret.load();

  /// Full serialized inspection (parity with inspection.refresh_report_html):
  /// status history + injected lab tests.
  Future<Map<String, dynamic>> _loadForReport(int inspectionId) async {
    final inspection = await inspectionRepo.getById(inspectionId);
    await labRepo.injectLabTests(inspection);
    return inspection;
  }

  Map<String, dynamic> _serializeSummaryRow(Map<String, dynamic> row) {
    for (final key in const ['quantity', 'rejected_quantity']) {
      final val = '$row[key]'.trim();
      if (val.isNotEmpty && val != '-') {
        final n = double.tryParse(val);
        if (n != null) row[key] = n.toStringAsFixed(3);
      }
    }
    final meta = decisionMeta('${row['decision_status']}');
    row['decision_label_ar'] = meta['label_ar'];
    row['decision_label_en'] = meta['label_en'];
    return row;
  }

  Future<List<Map<String, dynamic>>> _querySummaries(
    String whereClause,
    List<Object?> params,
  ) async {
    final db = await dbHelper.readDatabase;
    final rows = await db.rawQuery(
      'SELECT $reportColumns FROM inspections $whereClause',
      params,
    );
    return [for (final r in rows) _serializeSummaryRow(Map<String, dynamic>.from(r))];
  }

  /// Fetch the 6-month trend window rows for the monthly report
  /// (parity with report.py render_monthly_report).
  Future<List<Map<String, dynamic>>> _fetchTrendWindow(int month, int year) async {
    var startMonth = month - 5;
    var startYear = year;
    while (startMonth <= 0) {
      startMonth += 12;
      startYear -= 1;
    }
    final windowStart = DateTime(startYear, startMonth, 1);
    final windowEnd = month == 12
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    final db = await dbHelper.readDatabase;
    final rows = await db.rawQuery(
      'SELECT inspection_date, decision_status, quantity, rejected_quantity '
      'FROM inspections WHERE inspection_date >= ? AND inspection_date < ?',
      [_dateOnlyIso(windowStart), _dateOnlyIso(windowEnd)],
    );
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  // ── Inspection report (single record) ─────────────────────────

  /// Port of export_pdf: single inspection report. Filename matches Python:
  /// `{material_name}_{entry_code}.pdf`.
  Future<ReportDoc> inspectionReport(int inspectionId) async {
    final inspection = await _loadForReport(inspectionId);
    final settings = await _settings();
    final ctx = buildInspectionContext(
      inspection,
      settings: settings,
      encryptionSecret: await _secretBytes(),
    );
    final bytes = await PdfRenderer.renderInspection(ctx);
    final mat = sanitizeFilename('${inspection['material_name'] ?? ''}');
    final code = sanitizeFilename('${inspection['entry_code'] ?? ''}');
    return ReportDoc(
      filename: '${mat}_$code.pdf',
      bytes: bytes,
      title: '${inspection['material_name']} (${inspection['entry_code']})',
    );
  }

  // ── Sample label ──────────────────────────────────────────────

  /// Port of export_label_pdf: 10×5cm sample label.
  Future<ReportDoc> sampleLabelPdf(int inspectionId) async {
    final inspection = await _loadForReport(inspectionId);
    final settings = await _settings();
    final ctx = buildLabelContext(
      inspection,
      settings: settings,
      encryptionSecret: await _secretBytes(),
    );
    final bytes = await PdfRenderer.renderLabel(ctx);
    final entryCode = '${inspection['entry_code'] ?? ''}';
    return ReportDoc(
      filename: 'Label_${entryCode}_${fileTimestamp()}.pdf',
      bytes: bytes,
      title: 'Label_$entryCode',
    );
  }

  /// Port of export_batch_labels: up to 100 labels on A4 pages.
  Future<ReportDoc> batchLabelsPdf(List<int> inspectionIds) async {
    final ids = inspectionIds.toSet().toList();
    if (ids.isEmpty) throw ValidationError(AppErrors.batchLabelsSelectAtLeastOne);
    if (ids.length > 100) {
      throw ValidationError(AppErrors.batchLabelsMax100);
    }
    final inspections = <Map<String, dynamic>>[];
    for (final id in ids) {
      inspections.add(await _loadForReport(id));
    }
    final settings = await _settings();
    final ctx = buildBatchLabelsContext(
      inspections,
      settings: settings,
      encryptionSecret: await _secretBytes(),
    );
    final bytes = await PdfRenderer.renderBatchLabels(ctx);
    return ReportDoc(
      filename: 'BatchLabels_${inspections.length}_${fileTimestamp()}.pdf',
      bytes: bytes,
      title: 'BatchLabels_${inspections.length}',
    );
  }

  // ── Period reports ────────────────────────────────────────────

  /// Daily report for a calendar day (00:00 →' 23:59).
  Future<ReportDoc> dailyReport(String dateStr) async {
    if (dateStr.trim().isEmpty) throw AppError(AppErrors.dailyDateRequired);
    final parsed = DateTime.tryParse(dateStr.trim());
    if (parsed == null) {
      throw ValidationError(AppErrors.dateFormatInvalid);
    }
    final day = dateStr.trim().substring(0, 10);
    final nextDayIso = _dateOnlyIso(DateTime(parsed.year, parsed.month, parsed.day + 1));
    final inspections = await _querySummaries(
      'WHERE inspection_date >= ? AND inspection_date < ? '
      'ORDER BY inspection_date DESC, id DESC',
      [day, nextDayIso],
    );
    final settings = await _settings();
    final ctx = buildDailyContext(
      inspections,
      settings: settings,
      dateStr: day,
      shiftLabel: '$day \u2192 $nextDayIso',
    );
    final bytes = await PdfRenderer.renderDaily(ctx);
    return ReportDoc(
      filename: 'تقرير_اليومي_$day.pdf',
      bytes: bytes,
      title: 'التقرير اليومي - $day',
    );
  }

  /// Monthly report with 6-month trend section.
  Future<ReportDoc> monthlyReport({required int month, required int year}) async {
    final monthStart = DateTime(year, month, 1);
    final nextMonthStart = month == 12
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    final inspections = await _querySummaries(
      'WHERE inspection_date >= ? AND inspection_date < ? '
      'ORDER BY inspection_date DESC, created_at DESC, id DESC',
      [_dateOnlyIso(monthStart), _dateOnlyIso(nextMonthStart)],
    );
    final trendRows = await _fetchTrendWindow(month, year);
    final settings = await _settings();
    final ctx = buildMonthlyContext(
      inspections,
      settings: settings,
      month: month,
      year: year,
      trendRows: trendRows,
    );
    final bytes = await PdfRenderer.renderMonthly(ctx);
    final period = '${year.toString().padLeft(4, '0')}${month.toString().padLeft(2, '0')}';
    return ReportDoc(
      filename: 'تقرير_الشهري_$period.pdf',
      bytes: bytes,
      title: 'التقرير الشهري - $month/$year',
    );
  }

  /// Yearly report.
  Future<ReportDoc> yearlyReport({required int year}) async {
    final yearStart = DateTime(year, 1, 1);
    final nextYearStart = DateTime(year + 1, 1, 1);
    final inspections = await _querySummaries(
      'WHERE inspection_date >= ? AND inspection_date < ? '
      'ORDER BY inspection_date DESC, created_at DESC, id DESC',
      [_dateOnlyIso(yearStart), _dateOnlyIso(nextYearStart)],
    );
    final settings = await _settings();
    final ctx = buildYearlyContext(inspections, settings: settings, year: year);
    final bytes = await PdfRenderer.renderYearly(ctx);
    return ReportDoc(
      filename: 'تقرير_السنوي_$year.pdf',
      bytes: bytes,
      title: 'التقرير السنوي - $year',
    );
  }

  /// Follow-up report for a user-filtered set of inspection ids.
  Future<ReportDoc> followUpReport(
    List<int> inspectionIds, {
    String? dateStr,
    String shiftLabel = '',
  }) async {
    final ids = inspectionIds.toSet().toList();
    if (ids.isEmpty) throw AppError(AppErrors.inspectionsListRequired);
    final placeholders = List.filled(ids.length, '?').join(', ');
    final inspections = await _querySummaries(
      'WHERE id IN ($placeholders) ORDER BY inspection_date DESC, id DESC',
      [for (final id in ids) id],
    );
    final day =
        (dateStr == null || dateStr.trim().isEmpty) ? todayIso() : dateStr.trim();
    final settings = await _settings();
    final ctx = buildFollowUpContext(
      inspections,
      settings: settings,
      dateStr: day,
      shiftLabel: shiftLabel,
    );
    final bytes = await PdfRenderer.renderFollowUp(ctx);
    return ReportDoc(
      filename: 'تقرير_المتابعة_${day}_${fileTimestamp()}.pdf',
      bytes: bytes,
      title: 'التقرير اليومي - $day',
    );
  }

  // ── Lab tests report ──────────────────────────────────────────

  /// Daily/monthly/yearly lab-tests report (delegates data fetching to
  /// LabRepo.buildLabTestReportData, port of lab.py).
  Future<ReportDoc> labReport({
    required String type,
    String? dateStr,
    int? month,
    int? year,
    int? analysisId,
    String? sourceType,
    int? sourceRefId,
  }) async {
    if (!const ['daily', 'monthly', 'yearly'].contains(type)) {
      throw ValidationError(AppErrors.reportTypeInvalid);
    }
    final data = await labRepo.buildLabTestReportData(
      reportType: type,
      dateStr: dateStr,
      month: month,
      year: year,
      analysisId: analysisId,
      sourceType: sourceType,
      sourceRefId: sourceRefId,
    );
    final tests = <Map<String, dynamic>>[
      for (final t in (data['tests'] as List)) Map<String, dynamic>.from(t as Map),
    ];
    final settings = await _settings();
    final ctx = buildLabReportContext(
      tests,
      settings: settings,
      title: '${data['title']}',
      periodLabel: '${data['period_label']}',
    );
    final bytes = await PdfRenderer.renderLab(ctx);
    var period = dateStr == null ? '' : dateStr.trim();
    if (period.isEmpty) {
      if (type == 'monthly' && month != null && year != null) {
        period = '${year.toString().padLeft(4, '0')}${month.toString().padLeft(2, '0')}';
      } else if (year != null) {
        period = '$year';
      }
    }
    return ReportDoc(
      filename: 'تقرير_المختبر_${type}_$period.pdf',
      bytes: bytes,
      title: '${data['title']}',
    );
  }

  // ── Disk output (parity with controller._get_export_dir) ────────

  /// Resolve the export folder: settings `export_root_path` or app exports
  /// root, optionally under `{year}/{month}/{day}` and a `labels` subfolder.
  Future<Directory> resolveExportDir({
    DateTime? date,
    bool asLabel = false,
  }) async {
    final settings = await _settings();
    final rootPath = '${settings['export_root_path'] ?? ''}'.trim();
    var root = rootPath.isNotEmpty
        ? Directory(rootPath)
        : await dbHelper.paths.exportsRoot();
    await root.create(recursive: true);
    if (date != null) {
      root = Directory(p.join(
        root.path,
        '${date.year}',
        date.month.toString().padLeft(2, '0'),
        date.day.toString().padLeft(2, '0'),
      ));
      await root.create(recursive: true);
    }
    if (asLabel) {
      root = Directory(p.join(root.path, 'labels'));
      await root.create(recursive: true);
    }
    return root;
  }

  /// Write [doc] to the export directory tree and return the written file.
  Future<File> saveReport(
    ReportDoc doc, {
    DateTime? date,
    bool asLabel = false,
  }) async {
    final dir = await resolveExportDir(date: date, asLabel: asLabel);
    final file = File(p.join(dir.path, doc.filename));
    await file.writeAsBytes(doc.bytes, flush: true);
    return file;
  }
}

String _dateOnlyIso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';