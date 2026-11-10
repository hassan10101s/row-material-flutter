import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';
import '../../di/service_locator.dart';
import '../../features/reports/domain/report_repository.dart';
import '../feedback/app_feedback.dart';
import '../feedback/app_feedback_export.dart';

/// Exports register tables to PDF through the shared report template.
class TablePdfExport {
  TablePdfExport._();

  /// Builds a templated PDF from [headers]/[rows] and offers open/share.
  /// Empty selections and failures surface through app feedback.
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
    try {
      final reports = getIt<ReportRepository>();
      final doc = await reports.tableReport(
        filename: '${filePrefix}_${_stamp(DateTime.now())}.pdf',
        title: title,
        headers: headers,
        rows: rows,
        subtitle: subtitle,
      );
      final file = await reports.saveReport(doc);
      if (!context.mounted) return file.path;
      await AppFeedbackExport.actions(
        context,
        filePath: file.path,
        documentName: file.uri.pathSegments.last,
      );
      if (context.mounted) {
        AppFeedback.success(
          context,
          AppText.t('تم إنشاء ملف PDF.', 'PDF file created.'),
        );
      }
      return file.path;
    } on Object catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
      return null;
    }
  }

  static String _stamp(DateTime t) {
    String p(int v, [int w = 2]) => '$v'.padLeft(w, '0');
    return '${p(t.year, 4)}${p(t.month)}${p(t.day)}_'
        '${p(t.hour)}${p(t.minute)}${p(t.second)}';
  }
}
