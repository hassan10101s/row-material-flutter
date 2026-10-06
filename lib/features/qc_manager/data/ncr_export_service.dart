import 'dart:io';

import 'package:excel/excel.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../../core/app_paths.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_dates.dart';
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
  NcrExportService({AppPaths? paths}) : _paths = paths ?? AppPaths();

  final AppPaths _paths;

  static const List<String> _pdfColumns = [
    'Ref',
    'Description',
    'Severity',
    'Status',
    'Inspection',
    'Lot/Batch',
    'Assignee',
    'Due',
    'Overdue',
    'CAPA',
  ];

  /// Arabic labels are kept out of the exported values on purpose: an NCR code,
  /// a severity and a status are the same tokens the database stores and the
  /// audit log records. Translating them here would make an exported file
  /// impossible to grep back against the database.
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

  Future<NcrExportResult> exportPdf(
    NcrExportBundle bundle, {
    Directory? directory,
  }) async {
    final doc = pw.Document(
      title: 'NCR report',
      author: bundle.generatedBy.isEmpty ? 'MaterialLab' : bundle.generatedBy,
    );

    final dark = PdfColors.grey900;
    final muted = PdfColors.grey700;

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(24),
        header: (context) => pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 6),
          decoration: const pw.BoxDecoration(
            border: pw.Border(bottom: pw.BorderSide(color: PdfColors.grey400)),
          ),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                AppText.t('تقرير عدم المطابقة', 'Non-conformance report'),
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.Text(
                '${AppText.t('صفحة', 'Page')} ${context.pageNumber}',
                style: pw.TextStyle(fontSize: 9, color: muted),
              ),
            ],
          ),
        ),
        footer: (context) => pw.Container(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Text(
            _provenance(bundle),
            style: pw.TextStyle(fontSize: 8, color: muted),
          ),
        ),
        build: (context) => [
          _pdfScope(bundle),
          pw.SizedBox(height: 8),
          _pdfKpis(bundle.kpis, dark),
          pw.SizedBox(height: 12),
          if (bundle.topDefects.isNotEmpty) ...[
            _pdfSectionTitle(
              AppText.t('أكثر عيوب تكراراً', 'Top recurring defects'),
            ),
            _pdfTopDefects(bundle.topDefects),
            pw.SizedBox(height: 12),
          ],
          if (bundle.aging.isNotEmpty) ...[
            _pdfSectionTitle(AppText.t('التوزيع العمري', 'Aging distribution')),
            _pdfAging(bundle.aging),
            pw.SizedBox(height: 12),
          ],
          _pdfSectionTitle(
            '${AppText.t('الحالات المطابقة', 'Matching findings')} '
            '(${bundle.rows.length})',
          ),
          _pdfTable(bundle.rows),
        ],
      ),
    );

    final file = await _write(directory, (dir) async {
      final path = _uniquePath(dir, _stamp(bundle.generatedAt), 'pdf');
      await File(path).writeAsBytes(await doc.save());
      return path;
    });

    return NcrExportResult(
      path: file,
      rowCount: bundle.rows.length,
      scope: bundle.filters.describe,
    );
  }

  Future<NcrExportResult> exportExcel(
    NcrExportBundle bundle, {
    Directory? directory,
  }) async {
    final excel = Excel.createExcel();

    // --- NCR_List ---
    final list = excel['NCR_List'];
    _headerRow(list, _excelHeaders());
    for (final row in bundle.rows) {
      list.appendRow(_excelRow(row).map(_cell).toList());
    }

    // --- KPIs ---
    final kpiSheet = excel['KPIs'];
    _headerRow(kpiSheet, [
      AppText.t('المؤشر', 'Metric'),
      AppText.t('القيمة', 'Value'),
    ]);
    final k = bundle.kpis;
    void pair(String label, Object? value) =>
        kpiSheet.appendRow([_cell(label), _cell(value)]);

    pair(AppText.t('الإجمالي', 'Total'), k.total);
    pair(AppText.t('المفتوحة', 'Open'), k.open);
    pair(AppText.t('مسندة', 'Assigned'), k.assigned);
    pair(AppText.t('قيد المعالجة', 'In progress'), k.inProgress);
    pair(AppText.t('تم التحقق', 'Verified'), k.verified);
    pair(AppText.t('مغلقة', 'Closed'), k.closed);
    pair(AppText.t('مرفوضة', 'Rejected'), k.rejected);
    pair(AppText.t('حرجة', 'Critical'), k.critical);
    pair(AppText.t('كبرى', 'Major'), k.major);
    pair(AppText.t('بسيطة', 'Minor'), k.minor);
    pair(AppText.t('متأخرة', 'Overdue'), k.overdue);
    pair(AppText.t('إغلاق في الموعد', 'Closed on time'), k.closedOnTime);
    pair(
      AppText.t('نسبة الإغلاق في الموعد', 'On-time closure %'),
      k.onTimeClosurePct,
    );
    pair(AppText.t('متوسط أيام الإغلاق', 'MTTC (days)'), k.mttcDays);
    pair(AppText.t('متوسط أيام التحقق', 'MTTV (days)'), k.mttvDays);
    pair(AppText.t('مرتبطة بإجراء تصحيحي', 'CAPA linked'), k.capaLinked);
    pair(AppText.t('إجراء تصحيحي متأخر', 'CAPA overdue'), k.capaOverdue);
    pair(AppText.t('النطاق', 'Scope'), bundle.filters.describe);
    pair(AppText.t('أُنشئ في', 'Generated at'), nowIsoAt(bundle.generatedAt));
    pair(AppText.t('المستخدم', 'Generated by'), bundle.generatedBy);

    // --- Top_Defects ---
    final defects = excel['Top_Defects'];
    _headerRow(defects, [
      AppText.t('الرمز', 'Code'),
      AppText.t('التصنيف', 'Category'),
      AppText.t('العدد', 'Count'),
    ]);
    for (final d in bundle.topDefects) {
      defects.appendRow([_cell(d.code), _cell(d.category), _cell(d.count)]);
    }

    // --- Aging ---
    final aging = excel['Aging'];
    _headerRow(aging, [
      AppText.t('الفئة', 'Band'),
      AppText.t('العدد', 'Count'),
      AppText.t('النسبة', 'Share'),
    ]);
    for (final b in bundle.aging) {
      aging.appendRow([
        _cell(b.label),
        _cell(b.count),
        _cell(_share(b, bundle.aging)),
      ]);
    }

    final file = await _write(directory, (dir) async {
      final path = _uniquePath(dir, _stamp(bundle.generatedAt), 'xlsx');
      final bytes = excel.save();
      if (bytes == null) {
        throw StateError('excel workbook produced no bytes');
      }
      await File(path).writeAsBytes(bytes);
      return path;
    });

    return NcrExportResult(
      path: file,
      rowCount: bundle.rows.length,
      scope: bundle.filters.describe,
    );
  }

  pw.Widget _pdfScope(NcrExportBundle bundle) => pw.Container(
    padding: const pw.EdgeInsets.all(8),
    decoration: pw.BoxDecoration(
      color: PdfColors.grey100,
      borderRadius: pw.BorderRadius.circular(3),
    ),
    child: pw.Text(
      '${AppText.t('النطاق', 'Scope')}: ${bundle.filters.describe}',
      style: const pw.TextStyle(fontSize: 9),
    ),
  );

  pw.Widget _pdfKpis(NcrKpis k, PdfColor dark) {
    // Two rows of tiles, because a single row of eight would be unreadable at
    // A4 width. A count that is not zero is drawn in its alarm colour; the
    // same tile for "0 critical" stays neutral.
    final red = PdfColors.red700;
    final tiles = <({String label, String value, PdfColor color})>[
      (label: AppText.t('الإجمالي', 'Total'), value: '${k.total}', color: dark),
      (label: AppText.t('المفتوحة', 'Open'), value: '${k.open}', color: dark),
      (
        label: AppText.t('متأخرة', 'Overdue'),
        value: '${k.overdue}',
        color: k.overdue > 0 ? red : dark,
      ),
      (
        label: AppText.t('حرجة', 'Critical'),
        value: '${k.critical}',
        color: k.critical > 0 ? red : dark,
      ),
      (
        label: AppText.t('حرجة مفتوحة %', 'Critical open %'),
        value: _pct(k.criticalOpenPct),
        color: dark,
      ),
      (
        label: AppText.t('في الموعد %', 'On-time %'),
        value: _pct(k.onTimeClosurePct),
        color: dark,
      ),
      (
        label: AppText.t('متوسط الإغلاق', 'MTTC'),
        value: _days(k.mttcDays),
        color: dark,
      ),
      (
        label: AppText.t('متوسط التحقق', 'MTTV'),
        value: _days(k.mttvDays),
        color: dark,
      ),
    ];

    return pw.Table(
      border: null,
      children: [
        for (var row = 0; row < 2; row++)
          pw.TableRow(
            children: [
              for (var col = 0; col < 4; col++)
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 5,
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        tiles[row * 4 + col].label,
                        style: const pw.TextStyle(
                          fontSize: 8,
                          color: PdfColors.grey700,
                        ),
                      ),
                      pw.Text(
                        tiles[row * 4 + col].value,
                        style: pw.TextStyle(
                          fontSize: 13,
                          fontWeight: pw.FontWeight.bold,
                          color: tiles[row * 4 + col].color,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }

  pw.Widget _pdfSectionTitle(String title) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 4),
    child: pw.Text(
      title,
      style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
    ),
  );

  pw.Widget _pdfTable(List<NcrReportRow> rows) {
    pw.Widget cell(String value, {bool danger = false}) => pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.5),
        ),
      ),
      child: pw.Text(
        value,
        style: pw.TextStyle(
          fontSize: 7,
          color: danger ? PdfColors.red700 : PdfColors.black,
        ),
      ),
    );

    return pw.Table(
      columnWidths: const {
        0: pw.FixedColumnWidth(56),
        1: pw.FlexColumnWidth(4),
        2: pw.FixedColumnWidth(44),
        3: pw.FixedColumnWidth(56),
        4: pw.FixedColumnWidth(56),
        5: pw.FixedColumnWidth(70),
        6: pw.FixedColumnWidth(70),
        7: pw.FixedColumnWidth(56),
        8: pw.FixedColumnWidth(38),
        9: pw.FixedColumnWidth(48),
      },
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: PdfColors.grey200),
          children: [
            for (final h in _pdfColumns)
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 3,
                ),
                child: pw.Text(
                  h,
                  style: pw.TextStyle(
                    fontSize: 7,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
        for (final r in rows)
          pw.TableRow(
            children: [
              cell(r.reference),
              cell(r.description),
              cell(r.severity, danger: r.severity == 'Critical'),
              cell(r.status),
              cell(r.inspectionRefId),
              cell(r.lotNo.isNotEmpty ? r.lotNo : r.batchNo),
              cell(r.assignedToName),
              cell(r.dueDate, danger: r.isOverdue),
              cell(
                r.isOverdue ? AppText.t('نعم', 'YES') : 'NO',
                danger: r.isOverdue,
              ),
              cell(r.capaStatus),
            ],
          ),
      ],
    );
  }

  pw.Widget _pdfTopDefects(List<NcrTopDefect> defects) => pw.Table(
    border: null,
    children: [
      pw.TableRow(
        children: [
          _pdfHead(AppText.t('الرمز', 'Code')),
          _pdfHead(AppText.t('التصنيف', 'Category')),
          _pdfHead(AppText.t('العدد', 'Count')),
        ],
      ),
      for (final d in defects)
        pw.TableRow(
          children: [
            _pdfCell(d.code),
            _pdfCell(d.category),
            _pdfCell('${d.count}'),
          ],
        ),
    ],
  );

  pw.Widget _pdfAging(List<NcrAgingBucket> buckets) => pw.Table(
    border: null,
    children: [
      pw.TableRow(
        children: [
          _pdfHead(AppText.t('الفئة', 'Band')),
          _pdfHead(AppText.t('العدد', 'Count')),
          _pdfHead(AppText.t('النسبة', 'Share')),
        ],
      ),
      for (final b in buckets)
        pw.TableRow(
          children: [
            _pdfCell(b.label),
            _pdfCell('${b.count}'),
            _pdfCell(_pct(_share(b, buckets))),
          ],
        ),
    ],
  );

  pw.Widget _pdfHead(String text) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
    decoration: const pw.BoxDecoration(color: PdfColors.grey200),
    child: pw.Text(
      text,
      style: pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold),
    ),
  );

  pw.Widget _pdfCell(String text) => pw.Container(
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
    child: pw.Text(text, style: const pw.TextStyle(fontSize: 7)),
  );

  void _headerRow(Sheet sheet, List<String> headers) {
    final rowIndex = sheet.maxRows;
    sheet.appendRow(headers.map(_cell).toList());
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

  Future<String> _write(
    Directory? directory,
    Future<String> Function(Directory dir) build,
  ) async {
    final dir = directory ?? await _paths.exportsRoot();
    if (!dir.existsSync()) await dir.create(recursive: true);
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

  String _provenance(NcrExportBundle bundle) =>
      '${AppText.t('أُنشئ في', 'Generated')}: ${nowIsoAt(bundle.generatedAt)}'
      ' · ${AppText.t('المستخدم', 'User')}: ${bundle.generatedBy.isEmpty ? '-' : bundle.generatedBy}'
      ' · ${AppText.t('النطاق', 'Scope')}: ${bundle.filters.describe}';

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

  /// Formats an already-computed percentage (0-100).
  String _pct(double? value) =>
      value == null ? '-' : '${value.toStringAsFixed(1)}%';

  /// Maps a plain value onto the excel package's cell types.
  ///
  /// `appendRow` wants `CellValue`, not `Object`, so every cell has to be
  /// wrapped deliberately. An unrecognised type degrades to text rather than
  /// throwing: losing one cell is better than losing the whole export.
  static CellValue? _cell(Object? value) => switch (value) {
    null => null,
    String s => TextCellValue(s),
    int n => IntCellValue(n),
    double n => DoubleCellValue(n),
    bool b => TextCellValue(b ? 'YES' : 'NO'),
    _ => TextCellValue('$value'),
  };

  String _days(double? value) =>
      value == null ? '-' : '${value.toStringAsFixed(1)} d';
}
