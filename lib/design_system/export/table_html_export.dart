import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/app_paths.dart';
import '../../core/constants/app_strings.dart';
import '../feedback/app_feedback.dart';
import '../feedback/app_feedback_export.dart';
import '../../di/service_locator.dart';
import '../../features/settings/domain/export_root_service.dart';

/// Generic table → HTML file export (the same idea as `TestHistoryPrinter`).
///
/// Every register table in the app exports through here: one HTML document
/// with a `<table>`, a `window.print()` button and `@media print` rules,
/// written next to the other exports and offered through
/// `AppFeedbackExport.actions` (open/share). Callers pass plain strings —
/// headers already localized with `AppText.t`, cells already formatted — so
/// this stays framework-free apart from the file/share step.
class TableHtmlExport {
  TableHtmlExport._();

  /// Pure builder (unit-testable): one HTML document for [headers] + [rows].
  static String buildHtml({
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
    String? subtitle,
  }) {
    final arabic = AppText.arabic;
    final esc = escape;
    final titleEsc = esc(title);
    final sub =
        subtitle ??
        esc(
          AppText.t(
            'عدد السجلات: ${rows.length} — بتاريخ ${DateTime.now().toString().substring(0, 16)}',
            'Records: ${rows.length} — ${DateTime.now().toString().substring(0, 16)}',
          ),
        );
    final printLabel = esc(AppText.t('طباعة', 'Print'));
    final thead = '<tr>${headers.map((h) => '<th>${esc(h)}</th>').join()}</tr>';
    final tbody = StringBuffer();
    for (var i = 0; i < rows.length; i++) {
      tbody.write('<tr><td>${i + 1}</td>');
      for (final cell in rows[i]) {
        tbody.write('<td>${esc(cell)}</td>');
      }
      tbody.write('</tr>');
    }
    return '''
<!DOCTYPE html>
<html lang="${arabic ? 'ar' : 'en'}" dir="${arabic ? 'rtl' : 'ltr'}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$titleEsc</title>
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
<h1>$titleEsc</h1>
<p class="meta">$sub</p>
<table><thead>$thead</thead><tbody>$tbody</tbody></table>
</body>
</html>
''';
  }

  /// Writes a pre-rendered [html] document and offers open/share.
  ///
  /// Desktop: next to the other exports (persistent, browsable in Explorer).
  /// Mobile: ephemeral OS-cache staging — never the permanent exports tree
  /// (unreachable sandbox = dead storage). The sheet deletes it after use.
  static Future<String?> writeHtmlFile(
    BuildContext context, {
    required String filePrefix,
    required String html,
    String? successMessage,
  }) async {
    try {
      final isMobile = Platform.isAndroid || Platform.isIOS;
      final Directory dir;
      if (isMobile) {
        final paths = getIt<AppPaths>();
        await paths.pruneShareCache();
        dir = await paths.shareCacheDir();
      } else {
        dir = await getIt<ExportRootService>().effectiveRoot();
      }
      final file = File(
        '${dir.path}/${filePrefix}_${stamp(DateTime.now())}.html',
      );
      await file.writeAsString(html);
      if (!context.mounted) return null;
      await AppFeedbackExport.actions(
        context,
        filePath: file.path,
        documentName: file.uri.pathSegments.last,
      );
      if (!context.mounted) return file.path;
      AppFeedback.success(
        context,
        successMessage ??
            AppText.t('تم إنشاء ملف التصدير.', 'Export file created.'),
      );
      return file.path;
    } on Object catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
      return null;
    }
  }

  /// Builds the document from [headers]/[rows] and exports it. Never throws
  /// into the UI: an empty selection and I/O failures surface as banners.
  static Future<String?> export(
    BuildContext context, {
    required String filePrefix,
    required String title,
    required List<String> headers,
    required List<List<String>> rows,
    String? subtitle,
    String? emptyMessage,
  }) async {
    if (rows.isEmpty) {
      AppFeedback.info(
        context,
        emptyMessage ??
            AppText.t('لا توجد سجلات للتصدير.', 'No records to export.'),
      );
      return null;
    }
    return writeHtmlFile(
      context,
      filePrefix: filePrefix,
      html: buildHtml(
        title: title,
        headers: headers,
        rows: rows,
        subtitle: subtitle,
      ),
    );
  }

  static String stamp(DateTime t) {
    String p(int v, [int w = 2]) => '$v'.padLeft(w, '0');
    return '${p(t.year, 4)}${p(t.month)}${p(t.day)}_${p(t.hour)}${p(t.minute)}${p(t.second)}';
  }

  static String escape(Object? value) => '${value ?? ''}'
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
