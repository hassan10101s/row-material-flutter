import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../../../core/app_paths.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_dates.dart';
import '../../reports/data/html_pdf_exporter.dart';
import '../../reports/data/report_builder.dart';
import '../../reports/data/tiny_jinja.dart';
import '../domain/ncr_filters.dart';
import '../domain/ncr_kpis.dart';
import '../domain/ncr_report_row.dart';

/// Everything one export needs, captured as a value.
///
/// The exporter is handed a snapshot rather than the repository: an export that
/// re-queried mid-write could describe 40 rows in its header and print 47, and
/// a report whose numbers shift between the PDF and the Excel is worse than no
/// export at all.
class NcrExportBundle {
  NcrExportBundle({
    required this.filters,
    required this.kpis,
    required this.rows,
    this.aging = const [],
    this.topDefects = const [],
    this.generatedBy = '',
    this.formNo = '',
    DateTime? generatedAt,
  }) : generatedAt = generatedAt ?? DateTime.now();

  final NcrFilters filters;
  final NcrKpis kpis;

  /// The rows to print - the *whole* filtered population, not one page.
  final List<NcrReportRow> rows;

  final List<NcrAgingBucket> aging;
  final List<NcrTopDefect> topDefects;
  final String generatedBy;
  final DateTime generatedAt;

  /// Global QA form number printed on the report (`نموذج رقم / Form No:`).
  final String formNo;
}

class NcrExportResult {
  const NcrExportResult({
    required this.path,
    required this.rowCount,
    required this.scope,
  });

  final String path;
  final int rowCount;

  /// Human description of the filters the file was built from, so a file found
  /// on disk months later still says what it is a report *of*.
  final String scope;
}

/// Writes the NCR report to PDF and Excel (plan V6_ENHANCED 22.7).
class NcrExportService {
  NcrExportService({AppPaths? paths, HtmlPdfExporter? htmlPdf})
    : _paths = paths ?? AppPaths(),
      _htmlPdf = htmlPdf ?? HtmlPdfExporter();

  final AppPaths _paths;
  final HtmlPdfExporter _htmlPdf;

  static List<String> _excelHeaders() => [
    AppText.t('المرجع', 'Ref'),
    AppText.t('الوصف', 'Description'),
    AppText.t('الخطورة', 'Severity'),
    AppText.t('الحالة', 'Status'),
    AppText.t('التفتيش', 'Inspection'),
    AppText.t('المخزون', 'Lot / Batch'),
    AppText.t('أمر الشراء', 'PO'),
    AppText.t('القسم', 'Department'),
    AppText.t('المسند', 'Assignee'),
    AppText.t('الفتح', 'Raised'),
    AppText.t('الاستحقاق', 'Due'),
    AppText.t('الإغلاق', 'Closed'),
    AppText.t('متأخرة', 'Overdue'),
    AppText.t('الإجراء التصحيحي', 'CAPA'),
    AppText.t('حالة الإجراء', 'CAPA status'),
    AppText.t('مفتوحة', 'Open'),
  ];

  static List<Object?> _excelRow(NcrReportRow r) => [
    r.reference,
    r.description,
    r.severity,
    r.status,
    r.inspectionRefId,
    r.lotNo.isNotEmpty ? r.lotNo : r.batchNo,
    r.poNo,
    r.dept,
    r.assignedToName,
    r.createdAt,
    r.dueDate,
    r.closedAt,
    r.isOverdue ? 'YES' : 'NO',
    r.capaNo,
    r.capaStatus,
    r.isOpen ? 'YES' : 'NO',
  ];

  /// Render the shared NCR HTML template on desktop and Android.
  Future<NcrExportResult> exportPdf(
    NcrExportBundle bundle, {
    Directory? directory,
  }) async {
    final ctx = buildNcrReportContext(bundle, formNo: bundle.formNo);
    ctx['is_en'] = !AppText.arabic;
    final template = await _readTemplate();
    final html = tinyJinjaRender(template, ctx);
    final bytes = await _htmlPdf.exportPdf(html);

    final file = await _write(directory, (dir) async {
      final path = _uniquePath(dir, _stamp(bundle.generatedAt), 'pdf');
      await File(path).writeAsBytes(bytes);
      return path;
    });

    return NcrExportResult(
      path: file,
      rowCount: bundle.rows.length,
      scope: bundle.filters.describe,
    );
  }

  /// Prefer rootBundle (production build); fall back to a direct file read for
  /// test environments where the flutter-test asset bundle can be stale.
  static Future<String> _readTemplate() async {
    const path = 'assets/templates/ncr_report_template.html';
    try {
      return await rootBundle.loadString(path);
    } catch (_) {
      return File(path).readAsString();
    }
  }

  /// Export the same immutable report snapshot to Excel.
  Future<NcrExportResult> exportExcel(
    NcrExportBundle bundle, {
    Directory? directory,
  }) async {
    // Build plain sendable payload on the UI isolate (cheap string reads),
    // then encode the workbook off-thread: Excel.createExcel + save() on a
    // large filtered population drops frames / risks ANR on low-end Android.
    final payload = <String, dynamic>{
      'headers': _excelHeaders(),
      'rows': [for (final row in bundle.rows) _excelRow(row)],
      'kpis': _kpiPairs(bundle),
      'defects': [
        for (final d in bundle.topDefects) [d.code, d.category, d.count],
      ],
      'aging': [
        for (final b in bundle.aging)
          [b.label, b.count, _share(b, bundle.aging)],
      ],
      'agingHeaders': [
        AppText.t('الفئة', 'Band'),
        AppText.t('العدد', 'Count'),
        AppText.t('النسبة', 'Share'),
      ],
    };
    final bytes = await Isolate.run(() => encodeNcrWorkbook(payload));

    final file = await _write(directory, (dir) async {
      final path = _uniquePath(dir, _stamp(bundle.generatedAt), 'xlsx');
      await File(path).writeAsBytes(bytes);
      return path;
    });

    return NcrExportResult(
      path: file,
      rowCount: bundle.rows.length,
      scope: bundle.filters.describe,
    );
  }

  List<List<Object?>> _kpiPairs(NcrExportBundle bundle) {
    final k = bundle.kpis;
    return [
      [AppText.t('الإجمالي', 'Total'), k.total],
      [AppText.t('المفتوحة', 'Open'), k.open],
      [AppText.t('مسندة', 'Assigned'), k.assigned],
      [AppText.t('قيد المعالجة', 'In progress'), k.inProgress],
      [AppText.t('تم التحقق', 'Verified'), k.verified],
      [AppText.t('مغلقة', 'Closed'), k.closed],
      [AppText.t('مرفوضة', 'Rejected'), k.rejected],
      [AppText.t('حرجة', 'Critical'), k.critical],
      [AppText.t('كبرى', 'Major'), k.major],
      [AppText.t('بسيطة', 'Minor'), k.minor],
      [AppText.t('متأخرة', 'Overdue'), k.overdue],
      [AppText.t('إغلاق في الموعد', 'Closed on time'), k.closedOnTime],
      [
        AppText.t('نسبة الإغلاق في الموعد', 'On-time closure %'),
        k.onTimeClosurePct,
      ],
      [AppText.t('متوسط أيام الإغلاق', 'MTTC (days)'), k.mttcDays],
      [AppText.t('متوسط أيام التحقق', 'MTTV (days)'), k.mttvDays],
      [AppText.t('مرتبطة بإجراء', 'CAPA linked'), k.capaLinked],
      [AppText.t('إجراء متأخر', 'CAPA overdue'), k.capaOverdue],
      [AppText.t('النطاق', 'Scope'), bundle.filters.describe],
      [AppText.t('أُنشئ في', 'Generated at'), nowIsoAt(bundle.generatedAt)],
      [AppText.t('المستخدم', 'Generated by'), bundle.generatedBy],
    ];
  }

  Future<String> _write(
    Directory? directory,
    Future<String> Function(Directory dir) build,
  ) async {
    // Explicit directory (caller-provided) always wins. Otherwise desktop
    // keeps the persistent exports tree while mobile stages in the ephemeral
    // OS cache — same rule as ReportService.saveReport (no dead files in the
    // unreachable sandbox).
    if (directory != null) {
      if (!directory.existsSync()) await directory.create(recursive: true);
      return build(directory);
    }
    final Directory dir;
    if (Platform.isAndroid || Platform.isIOS) {
      await _paths.pruneShareCache();
      dir = await _paths.shareCacheDir();
    } else {
      dir = await _paths.exportsRoot();
      if (!dir.existsSync()) await dir.create(recursive: true);
    }
    return build(dir);
  }

  /// A filename in [dir] that does not exist yet.
  ///
  /// Two exports inside the same minute produce the same timestamp, so the
  /// second would silently overwrite the first - and someone comparing this
  /// month's reports would be comparing a file to itself.
  static String _uniquePath(Directory dir, String stamp, String extension) {
    final base = '${dir.path}/ncr_report_$stamp';
    var candidate = '$base.$extension';
    var n = 2;
    while (File(candidate).existsSync()) {
      candidate = '$base-$n.$extension';
      n++;
    }
    return candidate;
  }

  String _stamp(DateTime at) =>
      '${at.year.toString().padLeft(4, '0')}'
      '${at.month.toString().padLeft(2, '0')}'
      '${at.day.toString().padLeft(2, '0')}_'
      '${at.hour.toString().padLeft(2, '0')}'
      '${at.minute.toString().padLeft(2, '0')}';

  /// One band's share of all bands, as a percentage (0-100) to match
  /// `NcrKpis.criticalOpenPct` and friends.
  ///
  /// `NcrAgingBucket` carries only its own count, so the denominator has to be
  /// taken from the set - and the denominator is the sum of the bands *present
  /// in the export*, not the KPI total. If the caller exports a subset the
  /// shares must still add to 100%, otherwise the column contradicts the sheet
  /// it sits next to.
  static double _share(NcrAgingBucket bucket, List<NcrAgingBucket> all) {
    final total = all.fold<int>(0, (sum, b) => sum + b.count);
    return total == 0 ? 0 : (bucket.count / total) * 100;
  }
}

/// Top-level so it can run in [Isolate.run] off the UI thread.
///
/// Takes only plain sendable collections (strings/numbers/bools) built on the
/// UI isolate, creates the workbook + encodes bytes in the background.
Uint8List encodeNcrWorkbook(Map<String, dynamic> payload) {
  final excel = Excel.createExcel();
  void headerRow(Sheet sheet, List<String> headers) {
    final rowIndex = sheet.maxRows;
    sheet.appendRow(headers.map(ncrExcelCell).toList());
    final style = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('FFEFEFEF'),
    );
    for (var col = 0; col < headers.length; col++) {
      sheet
              .cell(
                CellIndex.indexByColumnRow(
                  columnIndex: col,
                  rowIndex: rowIndex,
                ),
              )
              .cellStyle =
          style;
    }
  }

  final headers = List<String>.from(payload['headers'] as List);
  final rows = List<List>.from(payload['rows'] as List);
  final list = excel['NCR_List'];
  headerRow(list, headers);
  for (final row in rows) {
    list.appendRow([for (final v in row) ncrExcelCell(v)]);
  }

  final kpis = excel['KPIs'];
  headerRow(kpis, const ['Metric', 'Value']);
  for (final pair in List<List>.from(payload['kpis'] as List)) {
    kpis.appendRow([ncrExcelCell(pair[0]), ncrExcelCell(pair[1])]);
  }

  final defects = excel['Top_Defects'];
  headerRow(defects, const ['Code', 'Category', 'Count']);
  for (final d in List<List>.from(payload['defects'] as List)) {
    defects.appendRow([
      ncrExcelCell(d[0]),
      ncrExcelCell(d[1]),
      ncrExcelCell(d[2]),
    ]);
  }

  final aging = excel['Aging'];
  final agingHeaders = List<String>.from(payload['agingHeaders'] as List);
  headerRow(aging, agingHeaders);
  for (final b in List<List>.from(payload['aging'] as List)) {
    aging.appendRow([
      ncrExcelCell(b[0]),
      ncrExcelCell(b[1]),
      ncrExcelCell(b[2]),
    ]);
  }

  final bytes = excel.save();
  if (bytes == null) throw StateError('excel workbook produced no bytes');
  return Uint8List.fromList(bytes);
}

CellValue? ncrExcelCell(Object? value) => switch (value) {
  null => null,
  String s => TextCellValue(s),
  int n => IntCellValue(n),
  double n => DoubleCellValue(n),
  bool b => TextCellValue(b ? 'YES' : 'NO'),
  _ => TextCellValue('$value'),
};
