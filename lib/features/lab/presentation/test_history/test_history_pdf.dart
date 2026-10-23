import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/feedback/app_feedback_export.dart';
import '../../../../di/service_locator.dart';
import '../../../reports/domain/report_repository.dart';
import '../../core/lab_result_format.dart';
import '../../core/test_history_logic.dart';

/// PDF export for the test log.
///
/// Formats the register rows into plain strings and hands them to the shared
/// report pipeline ([ReportRepository.tableReport]) — the same HTML document
/// the "print HTML" action writes, converted to a PDF (headless browser on
/// desktop, native dart-pdf table on phones) and saved with the usual
/// open/share sheet.
class TestHistoryPdf {
  TestHistoryPdf._();

  static List<String> headers() => [
    AppText.t('التوقيت', 'Time'),
    AppText.t('التحليل', 'Analysis'),
    AppText.t('المرجع', 'Reference'),
    AppText.t('العينة', 'Sample'),
    AppText.t('المصدر', 'Source'),
    AppText.t('كود الدخول', 'Entry code'),
    AppText.t('النتيجة', 'Result'),
    AppText.t('النطاق', 'Range'),
    AppText.t('الحالة', 'Status'),
    AppText.t('بواسطة', 'By'),
  ];

  static List<List<String>> rows(List<Map<String, dynamic>> source) => [
    for (final r in source) _cells(r),
  ];

  static List<String> _cells(Map<String, dynamic> r) {
    final sourceType = '${r['source_type'] ?? ''}';
    final source = sourceType.isEmpty
        ? '${r['source_name'] ?? '-'}'
        : '${r['source_name'] ?? '-'} (${thSourceLabel(sourceType)})';
    final unit = '${r['range_unit'] ?? r['analysis_unit'] ?? '%'}';
    final range = r['min'] == null && r['max'] == null
        ? '-'
        : '${r['min'] ?? ''} – ${r['max'] ?? ''} $unit';
    return [
      thFmtDateTime(r['tested_at']),
      '${r['analysis_name'] ?? '-'}',
      '${r['analysis_reference'] ?? '-'}',
      '${r['sample_name'] ?? '-'}',
      source,
      '${r['entry_code'] ?? '-'}',
      '${formatLabResult(r['result_text'])} $unit',
      range,
      thRangeLabel('${r['range_state'] ?? 'none'}'),
      '${r['tested_by_name'] ?? '-'}',
    ];
  }

  /// Builds and saves the PDF for [source], then offers open/share. Never
  /// throws into the UI: an empty selection and failures surface as banners.
  static Future<void> export(
    BuildContext context,
    List<Map<String, dynamic>> source,
  ) async {
    if (source.isEmpty) {
      AppFeedback.info(
        context,
        AppText.t('لا توجد سجلات للتصدير.', 'No records to export.'),
      );
      return;
    }
    try {
      final repo = getIt<ReportRepository>();
      final doc = await repo.tableReport(
        filename: AppText.t('سجل_التحاليل.pdf', 'Test_History.pdf'),
        title: AppText.t('سجل تحاليل المعمل', 'Lab test history'),
        headers: headers(),
        rows: rows(source),
      );
      final file = await repo.saveReport(doc);
      if (!context.mounted) return;
      await AppFeedbackExport.actions(
        context,
        filePath: file.path,
        documentName: doc.title,
      );
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }
}
