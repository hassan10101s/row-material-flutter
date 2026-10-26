import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../../../core/constants/app_errors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/constants/report_form_keys.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/security/local_secret.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';
import '../../../design_system/export/table_html_export.dart';
import '../../inspections/data/inspection_repo.dart';
import '../../lab/data/lab_repo.dart';
import '../../reference/data/reference_repo.dart';
import '../../settings/data/settings_repo.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/report_repository.dart';
import 'html_pdf_exporter.dart';
import 'qr_render.dart';
import 'report_builder.dart';
import 'report_html_builder.dart';
import 'tiny_jinja.dart';

/// Port of the report data layer: queries in core/controller.py report
/// endpoints + report.py rendering flow, producing PDF bytes via the exact
/// reference approach — render one of the copied Vue HTML templates with
/// tiny_jinja, then convert HTML→PDF through a headless Edge/Chrome
/// ([HtmlPdfExporter]) or Android WebView using the same source document.
class ReportService implements ReportRepository {
  ReportService({
    required this.dbHelper,
    required this.settingsRepo,
    required this.inspectionRepo,
    required this.labRepo,
    required this.secret,
    this.htmlBuilder,
    HtmlPdfExporter? htmlPdf,
    this.guard,
  }) : _htmlPdf = htmlPdf ?? HtmlPdfExporter();

  final DatabaseHelper dbHelper;
  final SettingsRepo settingsRepo;
  final InspectionRepo inspectionRepo;
  final LabRepo labRepo;
  final LocalSecret secret;
  final WriteGuard? guard;

  void _checkExport() {
    if (guard != null && !guard!.allows('reports.export')) {
      throw AuthorizationError(AppErrors.notAuthorizedForOperation);
    }
  }

  /// Enriched-context builder for the inspection report (mirrors the stored
  /// `inspections.report_html` column).
  final ReportHtmlBuilder? htmlBuilder;

  late final HtmlPdfExporter _htmlPdf;

  /// Summary columns used by period reports (mirrors controller.py
  /// `report_columns`). Summary rows are NOT JSON-enriched.
  static const String reportColumns = '''
      id, entry_code, inspection_kind, product_id, formula_number, batch_number,
      material_name, material_code, inspection_date, expiry_date, supplier, quantity,
      sample_taken_by, specialist_name, decision_status, decision_reason, follow_up_note,
      rejected_quantity, created_by_name, created_at, updated_at,
      sample_names_json, physical_results_json, chemical_results_json
  ''';

  Future<Map<String, dynamic>> _settings() => settingsRepo.getSettings();

  Future<List<int>> _secretBytes() => secret.load();

  /// Full serialized inspection (parity with inspection.refresh_report_html):
  /// status history + injected lab tests. Product batches additionally
  /// carry their sample rows (`batch_samples`) with their own results,
  /// generated on-device from existing data — never synced, never stored
  /// on the header. Batch samples are independent of lab chemistry: no
  /// `lab_sample_tests` lookup happens here.
  Future<Map<String, dynamic>> _loadForReport(int inspectionId) async {
    final inspection = await inspectionRepo.getById(inspectionId);
    // Perf: batch samples only need the id, so they load concurrently with
    // the lab-test injection instead of a second serial DB round-trip.
    if ('${inspection['inspection_kind'] ?? 'raw'}' == 'product') {
      final samples = await Future.wait([
        labRepo.injectLabTests(inspection),
        labRepo.listBatchSamples(inspectionId),
      ]);
      inspection['batch_samples'] = [
        for (final s in samples[1] as List<Map<String, dynamic>>)
          Map<String, dynamic>.from(s),
      ];
    } else {
      await labRepo.injectLabTests(inspection);
    }
    return inspection;
  }

  Map<String, dynamic> _serializeSummaryRow(Map<String, dynamic> row) {
    for (final key in const ['quantity', 'rejected_quantity']) {
      final val = '${row[key]}'.trim();
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
    return [
      for (final r in rows) _serializeSummaryRow(Map<String, dynamic>.from(r)),
    ];
  }

  /// Fetch the 6-month trend window rows for the monthly report
  /// (parity with report.py render_monthly_report).
  Future<List<Map<String, dynamic>>> _fetchTrendWindow(
    int month,
    int year,
  ) async {
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
      "FROM inspections WHERE inspection_kind = 'raw' AND inspection_date >= ? AND inspection_date < ?",
      [_dateOnlyIso(windowStart), _dateOnlyIso(windowEnd)],
    );
    return [for (final r in rows) Map<String, dynamic>.from(r)];
  }

  // ── HTML template → PDF (reference approach) ─────────────────────

  /// Render a shipped template with tiny_jinja (autoescape ON, same as
  /// `jinja2.Environment(autoescape=True)`).
  Future<String> _renderHtmlTemplate(
    String templateName,
    Map<String, dynamic> context,
  ) async {
    context['is_en'] = !AppText.arabic;
    final template = await _readAssetText('assets/templates/$templateName');
    return tinyJinjaRender(template, context);
  }

  /// Prefer rootBundle (production build); fall back to a direct file read for
  /// test environments where the flutter-test asset bundle can be stale.
  static Future<String> _readAssetText(String path) async {
    try {
      return await rootBundle.loadString(path);
    } catch (_) {
      return File(path).readAsString();
    }
  }

  /// Render the shipped HTML template on desktop or Android.
  Future<Uint8List> _exportHtmlPdf(
    String templateName,
    Map<String, dynamic> context, {
    bool noPageOverride = false,
  }) async {
    final html = await _renderHtmlTemplate(templateName, context);
    return _pdfFromHtml(html, noPageOverride: noPageOverride);
  }

  /// Keep one layout source: conversion failures are surfaced to the caller.
  Future<Uint8List> _pdfFromHtml(
    String html, {
    bool noPageOverride = false,
  }) async {
    _checkExport();
    return _htmlPdf.exportPdf(html, noPageOverride: noPageOverride);
  }

  /// Attach the QR PNG data-URI (label templates render it via
  /// `{{ qr_image_data_uri }}`).
  ///
  /// QR encode → per-module paint → PNG encode → base64 runs 1..100 times per
  /// label export; this runs in a worker isolate so a batch export cannot
  /// freeze the UI while the context is being prepared. The mutation happens
  /// on the isolate's copy, so the returned map replaces the caller's.
  Future<Map<String, dynamic>> _withQrImageUris(Map<String, dynamic> context) {
    return Isolate.run(() {
      final uri = generateQrDataUri(
        '${context['qr_payload_text'] ?? ''}',
      ).dataUri;
      context['qr_image_data_uri'] = uri;
      final labels = context['labels'] as List<Map<String, dynamic>>?;
      if (labels != null) {
        for (final label in labels) {
          label['qr_image_data_uri'] = generateQrDataUri(
            '${label['qr_payload_text'] ?? ''}',
          ).dataUri;
        }
      }
      return context;
    });
  }

  // ── Inspection report (single record) ─────────────────────────

  /// Port of export_pdf: single inspection report. Filename matches Python:
  /// `{material_name}_{entry_code}.pdf`. Saved-HTML parity: the PDF is produced
  /// from the same rich context as `inspections.report_html`.
  @override
  Future<ReportDoc> inspectionReport(
    int inspectionId, {
    bool includeAnalysisDetails = false,
  }) async {
    _checkExport();
    final inspection = await _loadForReport(inspectionId);
    final ctx = htmlBuilder == null
        ? await _withQrImageUris(
            buildInspectionContext(
              inspection,
              settings: await _settings(),
              encryptionSecret: await _secretBytes(),
            ),
          )
        : await htmlBuilder!.buildContext(inspection);
    ctx['quality_specialist_name'] ??= inspection['specialist_name'] ?? '-';
    ctx['updated_at'] ??= inspection['updated_at'] ?? nowIso();
    ctx['include_analysis_details'] = includeAnalysisDetails;
    if (includeAnalysisDetails) {
      ctx['analysis_details'] = [
        for (final test in (inspection['lab_tests'] as List? ?? const []))
          {
            'name': test['analysis_name'] ?? '',
            'reference': test['analysis_reference'] ?? '',
            'sample': test['sample_name'] ?? '',
            'result': test['result_text'] ?? '',
            'unit': test['analysis_unit'] ?? '',
            'tested_at': test['tested_at'] ?? '',
            'inputs': jsonLoads('${test['dynamic_values_json'] ?? '{}'}')
                .entries
                .map((entry) => '${entry.key}: ${entry.value}')
                .join(' • '),
          },
      ];
    }
    final bytes = await _exportHtmlPdf('report_template.html', ctx);
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
  @override
  Future<ReportDoc> sampleLabelPdf(int inspectionId) async {
    _checkExport();
    final inspection = await _loadForReport(inspectionId);
    final settings = await _settings();
    final ctx = await _withQrImageUris(
      buildLabelContext(
        inspection,
        settings: settings,
        encryptionSecret: await _secretBytes(),
      ),
    );
    final bytes = await _exportHtmlPdf(
      'label_template.html',
      ctx,
      noPageOverride: true,
    );
    final entryCode = '${inspection['entry_code'] ?? ''}';
    return ReportDoc(
      filename: 'Label_${entryCode}_${fileTimestamp()}.pdf',
      bytes: bytes,
      title: 'Label_$entryCode',
    );
  }

  // ── Equipment label ─────────────────────────────────────────────

  /// Port of the sample-label flow for lab equipment: 10×5cm device sticker.
  /// Uses the same HTML template pipeline as the sample label, rendered by
  /// Edge/Chrome on desktop and WebView's print adapter on Android.
  @override
  Future<ReportDoc> equipmentLabelPdf(int equipmentId) async {
    _checkExport();
    final equipment = await labRepo.getEquipment(equipmentId);
    final settings = await _settings();
    final ctx = await _withQrImageUris(
      buildEquipmentLabelContext(
        equipment,
        settings: settings,
        encryptionSecret: await _secretBytes(),
      ),
    );
    final bytes = await _exportHtmlPdf(
      'equipment_label_template.html',
      ctx,
      noPageOverride: true,
    );
    final code = sanitizeFilename('${equipment['code'] ?? equipmentId}');
    return ReportDoc(
      filename: 'EquipmentLabel_${code}_${fileTimestamp()}.pdf',
      bytes: bytes,
      title: 'EquipmentLabel_$code',
    );
  }

  /// Selected lab equipment as N stickers per A4 page — the same reference
  /// approach and page packing as [batchLabelsPdf] (10×5cm cells, 2×5 grid).
  @override
  Future<ReportDoc> equipmentLabelsPdf(List<int> equipmentIds) async {
    _checkExport();
    final ids = equipmentIds.toSet().toList();
    if (ids.isEmpty) {
      throw ValidationError(AppErrors.batchLabelsSelectAtLeastOne);
    }
    if (ids.length > 100) {
      throw ValidationError(AppErrors.batchLabelsMax100);
    }
    final equipments = [for (final id in ids) await labRepo.getEquipment(id)];
    final settings = await _settings();
    final ctx = await _withQrImageUris(
      buildEquipmentLabelsContext(
        equipments,
        settings: settings,
        encryptionSecret: await _secretBytes(),
      ),
    );
    final bytes = await _exportHtmlPdf(
      'equipment_batch_label_template.html',
      ctx,
      noPageOverride: true,
    );
    return ReportDoc(
      filename: 'EquipmentLabels_${equipments.length}_${fileTimestamp()}.pdf',
      bytes: bytes,
      title: 'EquipmentLabels_${equipments.length}',
    );
  }
  // ── Batch labels ──────────────────────────────────────────────────

  /// Port of export_batch_labels: up to 100 labels on A4 pages.
  @override
  Future<ReportDoc> batchLabelsPdf(List<int> inspectionIds) async {
    _checkExport();
    final ids = inspectionIds.toSet().toList();
    if (ids.isEmpty) {
      throw ValidationError(AppErrors.batchLabelsSelectAtLeastOne);
    }
    if (ids.length > 100) {
      throw ValidationError(AppErrors.batchLabelsMax100);
    }
    final inspections = <Map<String, dynamic>>[];
    for (final id in ids) {
      inspections.add(await _loadForReport(id));
    }
    final settings = await _settings();
    final ctx = await _withQrImageUris(
      buildBatchLabelsContext(
        inspections,
        settings: settings,
        encryptionSecret: await _secretBytes(),
      ),
    );
    final bytes = await _exportHtmlPdf(
      'batch_label_template.html',
      ctx,
      noPageOverride: true,
    );
    return ReportDoc(
      filename: 'BatchLabels_${inspections.length}_${fileTimestamp()}.pdf',
      bytes: bytes,
      title: 'BatchLabels_${inspections.length}',
    );
  }

  // ── Period reports ────────────────────────────────────────────

  /// Daily report for a calendar day (00:00 →' 23:59).
  @override
  Future<ReportDoc> dailyReport(String dateStr) async {
    _checkExport();
    if (dateStr.trim().isEmpty) throw AppError(AppErrors.dailyDateRequired);
    final parsed = DateTime.tryParse(dateStr.trim());
    if (parsed == null) {
      throw ValidationError(AppErrors.dateFormatInvalid);
    }
    final day = dateStr.trim().substring(0, 10);
    final nextDayIso = _dateOnlyIso(
      DateTime(parsed.year, parsed.month, parsed.day + 1),
    );
    final inspections = await _querySummaries(
      "WHERE inspection_kind = 'raw' AND inspection_date >= ? AND inspection_date < ? "
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
    final bytes = await _exportHtmlPdf('daily_report_template.html', ctx);
    return ReportDoc(
      filename: AppText.t('تقرير_اليومي_$day.pdf', 'Daily_Report_$day.pdf'),
      bytes: bytes,
      title: AppText.t('التقرير اليومي - $day', 'Daily report - $day'),
    );
  }

  /// Monthly report with 6-month trend section.
  @override
  Future<ReportDoc> monthlyReport({
    required int month,
    required int year,
  }) async {
    _checkExport();
    final monthStart = DateTime(year, month, 1);
    final nextMonthStart = month == 12
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    final inspections = await _querySummaries(
      "WHERE inspection_kind = 'raw' AND inspection_date >= ? AND inspection_date < ? "
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
    final bytes = await _exportHtmlPdf('monthly_report_template.html', ctx);
    final period =
        '${year.toString().padLeft(4, '0')}${month.toString().padLeft(2, '0')}';
    return ReportDoc(
      filename: AppText.t(
        'تقرير_الشهري_$period.pdf',
        'Monthly_Report_$period.pdf',
      ),
      bytes: bytes,
      title: AppText.t(
        'التقرير الشهري - $month/$year',
        'Monthly report - $month/$year',
      ),
    );
  }

  /// Yearly report.
  @override
  Future<ReportDoc> yearlyReport({required int year}) async {
    _checkExport();
    final yearStart = DateTime(year, 1, 1);
    final nextYearStart = DateTime(year + 1, 1, 1);
    final inspections = await _querySummaries(
      "WHERE inspection_kind = 'raw' AND inspection_date >= ? AND inspection_date < ? "
      'ORDER BY inspection_date DESC, created_at DESC, id DESC',
      [_dateOnlyIso(yearStart), _dateOnlyIso(nextYearStart)],
    );
    final settings = await _settings();
    final ctx = buildYearlyContext(inspections, settings: settings, year: year);
    final bytes = await _exportHtmlPdf('yearly_report_template.html', ctx);
    return ReportDoc(
      filename: AppText.t('تقرير_السنوي_$year.pdf', 'Yearly_Report_$year.pdf'),
      bytes: bytes,
      title: AppText.t('التقرير السنوي - $year', 'Yearly report - $year'),
    );
  }

  /// Follow-up report for a user-filtered set of inspection ids.
  @override
  Future<ReportDoc> followUpReport(
    List<int> inspectionIds, {
    String? dateStr,
    String shiftLabel = '',
  }) async {
    _checkExport();
    final ids = inspectionIds.toSet().toList();
    if (ids.isEmpty) throw AppError(AppErrors.inspectionsListRequired);
    final placeholders = List.filled(ids.length, '?').join(', ');
    final inspections = await _querySummaries(
      'WHERE id IN ($placeholders) ORDER BY inspection_date DESC, id DESC',
      [for (final id in ids) id],
    );
    final day = (dateStr == null || dateStr.trim().isEmpty)
        ? todayIso()
        : dateStr.trim();
    final settings = await _settings();
    final ctx = buildFollowUpContext(
      inspections,
      settings: settings,
      dateStr: day,
      shiftLabel: shiftLabel,
    );
    final bytes = await _exportHtmlPdf('followup_report_template.html', ctx);
    return ReportDoc(
      filename: AppText.t(
        'تقرير_المتابعة_${day}_${fileTimestamp()}.pdf',
        'Follow_Up_Report_${day}_${fileTimestamp()}.pdf',
      ),
      bytes: bytes,
      title: AppText.t('التقرير اليومي - $day', 'Daily report - $day'),
    );
  }

  // ── Lab tests report ──────────────────────────────────────────

  /// Daily/monthly/yearly lab-tests report (delegates data fetching to
  /// LabRepo.buildLabTestReportData, port of lab.py).
  @override
  Future<ReportDoc> labReport({
    required String type,
    String? dateStr,
    int? month,
    int? year,
    int? analysisId,
    String? sourceType,
    int? sourceRefId,
  }) async {
    _checkExport();
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
      for (final t in (data['tests'] as List))
        Map<String, dynamic>.from(t as Map),
    ];
    final settings = await _settings();
    final ctx = buildLabReportContext(
      tests,
      settings: settings,
      title: '${data['title']}',
      periodLabel: '${data['period_label']}',
      formNoKey: switch (type) {
        'monthly' => ReportFormKeys.labMonthlyReport,
        'yearly' => ReportFormKeys.labYearlyReport,
        _ => ReportFormKeys.labDailyReport,
      },
    );
    final bytes = await _exportHtmlPdf('lab_report_template.html', ctx);
    var period = dateStr == null ? '' : dateStr.trim();
    if (period.isEmpty) {
      if (type == 'monthly' && month != null && year != null) {
        period =
            '${year.toString().padLeft(4, '0')}${month.toString().padLeft(2, '0')}';
      } else if (year != null) {
        period = '$year';
      }
    }
    return ReportDoc(
      filename: AppText.t(
        'تقرير_المعمل_${type}_$period.pdf',
        'Lab_Report_${type}_$period.pdf',
      ),
      bytes: bytes,
      title: '${data['title']}',
    );
  }

  /// Generic register table (e.g. the test log) as a PDF. The same HTML
  /// document the register's "print" action would write, converted through the
  /// shared HTML→PDF pipeline on both desktop and Android.
  @override
  Future<ReportDoc> tableReport({
    required String filename,
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
  }) async {
    _checkExport();
    if (rows.isEmpty) {
      throw ValidationError(
        AppText.t('لا توجد سجلات للتصدير.', 'No records to export.'),
      );
    }
    final bytes = await _pdfFromHtml(
      TableHtmlExport.buildHtml(title: title, headers: headers, rows: rows),
    );
    return ReportDoc(filename: filename, bytes: bytes, title: title);
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
      root = Directory(
        p.join(
          root.path,
          '${date.year}',
          date.month.toString().padLeft(2, '0'),
          date.day.toString().padLeft(2, '0'),
        ),
      );
      await root.create(recursive: true);
    }
    if (asLabel) {
      root = Directory(p.join(root.path, 'labels'));
      await root.create(recursive: true);
    }
    return root;
  }

  /// Write [doc] to disk and return the written file.
  ///
  /// Platform split (storage best-practice):
  /// - Desktop (Windows MSIX/EXE, Linux, macOS): persistent export tree
  ///   (`exports/[/yyyy/MM/dd][/labels]`) — the user can browse it in Explorer.
  /// - Mobile (Android/iOS): ephemeral OS-cache staging (`shareCacheDir`) —
  ///   the sandbox is unreachable by file managers, so a permanent copy would
  ///   only eat storage. The share/open sheet deletes it after use; stale
  ///   files are pruned here (24 h) along with legacy stranded exports (7 d).
  @override
  Future<File> saveReport(
    ReportDoc doc, {
    DateTime? date,
    bool asLabel = false,
  }) async {
    _checkExport();
    if (Platform.isAndroid || Platform.isIOS) {
      // Hygiene first (best effort, never blocks the export).
      await dbHelper.paths.pruneShareCache();
      await dbHelper.paths.pruneLegacyMobileExports();
      final dir = await dbHelper.paths.shareCacheDir();
      final file = File(p.join(dir.path, doc.filename));
      await file.writeAsBytes(doc.bytes, flush: true);
      return file;
    }
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
