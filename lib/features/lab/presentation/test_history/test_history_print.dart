import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/export/table_html_export.dart';
import '../../core/lab_result_format.dart';
import '../../core/test_history_logic.dart';

/// Prints selected test-history records through an HTML file.
///
/// The file opens in the browser / share sheet, where the user prints it with
/// the system print dialog — hence the `window.print()` button and the
/// `@media print` rules baked into the document.
class TestHistoryPrinter {
  TestHistoryPrinter._();

  /// Pure builder (unit-testable): one HTML document for [rows].
  static String buildHtml(List<Map<String, dynamic>> rows) {
    final arabic = AppText.arabic;
    final esc = _esc;
    final ths = <String>[];
    void th(String ar, String en) =>
        ths.add('<th>${esc(AppText.t(ar, en))}</th>');
    th('#', '#');
    th('التوقيت', 'Time');
    th('التحليل', 'Analysis');
    th('العينة', 'Sample');
    th('المصدر', 'Source');
    th('كود الدخول', 'Entry code');
    th('النتيجة', 'Result');
    th('النطاق', 'Range');
    th('الحالة', 'Status');
    th('بواسطة', 'By');

    final trs = StringBuffer();
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final sourceType = '${r['source_type'] ?? ''}';
      final source = StringBuffer(esc('${r['source_name'] ?? '-'}'));
      if (sourceType.isNotEmpty) {
        source.write(' (${esc(thSourceLabel(sourceType))})');
      }
      final range = r['min'] == null && r['max'] == null
          ? '-'
          : '${r['min'] ?? ''} – ${r['max'] ?? ''} '
              '${r['range_unit'] ?? r['analysis_unit'] ?? '%'}';
      trs.write(
        '<tr><td>${i + 1}</td>'
        '<td>${esc(thFmtDateTime(r['tested_at']))}</td>'
        '<td>${esc('${r['analysis_name'] ?? '-'}')}</td>'
        '<td>${esc('${r['sample_name'] ?? '-'}')}</td>'
        '<td>$source</td>'
        '<td dir="ltr">${esc('${r['entry_code'] ?? '-'}')}</td>'
        '<td><b>${esc('${formatLabResult(r['result_text'])} ${r['range_unit'] ?? r['analysis_unit'] ?? '%'}')}</b></td>'
        '<td>${esc(range)}</td>'
        '<td>${esc(thRangeLabel('${r['range_state'] ?? 'none'}'))}</td>'
        '<td>${esc('${r['tested_by_name'] ?? '-'}')}</td></tr>',
      );
    }

    final title = esc(
      AppText.t('سجل تحاليل المعمل', 'Lab test history'),
    );
    final meta = esc(
      AppText.t(
        'عدد السجلات: ${rows.length} — بتاريخ ${DateTime.now().toString().substring(0, 16)}',
        'Records: ${rows.length} — ${DateTime.now().toString().substring(0, 16)}',
      ),
    );
    final printLabel = esc(AppText.t('طباعة', 'Print'));
    return '''
<!DOCTYPE html>
<html lang="${arabic ? 'ar' : 'en'}" dir="${arabic ? 'rtl' : 'ltr'}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$title</title>
<style>
  body { font-family: Cairo, Tahoma, Arial, sans-serif; margin: 24px; color: #111; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  p.meta { color: #555; font-size: 13px; margin: 0 0 16px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { border: 1px solid #999; padding: 6px 8px; text-align: start; }
  th { background: #eee; }
  @media print { .no-print { display: none; } }
</style>
</head>
<body>
<button class="no-print" onclick="window.print()">$printLabel</button>
<h1>$title</h1>
<p class="meta">$meta</p>
<table><thead><tr>${ths.join()}</tr></thead><tbody>$trs</tbody></table>
</body>
</html>
''';
  }

  /// Writes [rows] next to the other exports and offers open/share, so the
  /// user can print from the browser. Never throws into the UI: failures
  /// surface as feedback banners. File flow is shared with every register
  /// table through [TableHtmlExport].
  static Future<void> printRows(
    BuildContext context,
    List<Map<String, dynamic>> rows,
  ) async {
    if (rows.isEmpty) {
      AppFeedback.info(
        context,
        AppText.t('لا توجد سجلات محددة للطباعة.', 'No selected records to print.'),
      );
      return;
    }
    await TableHtmlExport.writeHtmlFile(
      context,
      filePrefix: 'lab_tests',
      html: buildHtml(rows),
      successMessage: AppText.t('تم إنشاء ملف الطباعة.', 'Print file created.'),
    );
  }

  static String _esc(Object? value) => TableHtmlExport.escape(value);
}
