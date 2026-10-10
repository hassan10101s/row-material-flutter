import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/feedback/app_feedback_export.dart';
import '../../../../../di/service_locator.dart';
import '../../../../reports/domain/report_repository.dart';
import '../../cubit/inspections_cubit.dart';

/// Bulk export for the inspections ledger's multi-row selection (the Vue
/// register's `exportSelected` / `exportBatchLabels`).
///
/// * Reports: one PDF per selected inspection (same generator as the
///   per-row button). A single file opens the delivery sheet; several
///   files only raise the success banner — one share sheet per file
///   would be N sheets in a row.
/// * Labels: one batch document for all ids (same backend call as Vue's
///   `reports_export_batch_labels`), then the delivery sheet.
/// * Selection clears on success only; on failure it is kept so nothing
///   the user picked is silently lost.
///
/// Rows off the current page are resolved by id; a row deleted meanwhile
/// surfaces as an error and keeps the remaining selection.
Future<void> exportSelectedReports(BuildContext context) async {
  final cubit = context.read<InspectionsCubit>();
  final ids = cubit.state.selectedIds.toList()..sort();
  if (ids.isEmpty) return;
  try {
    final reports = getIt<ReportRepository>();
    final byId = <int, Map<String, dynamic>>{
      for (final r in cubit.state.visible) (r['id'] as num).toInt(): r,
    };
    final paths = <String>[];
    String? lastName;
    for (final id in ids) {
      final row = byId[id] ?? await cubit.repo.getById(id);
      final doc = await reports.inspectionReport(id);
      final file = await reports.saveReport(
        doc,
        date: parseIsoDate('${row['inspection_date'] ?? ''}'),
      );
      paths.add(file.path);
      lastName = file.uri.pathSegments.isEmpty
          ? null
          : file.uri.pathSegments.last;
    }
    if (!context.mounted) return;
    if (paths.length == 1) {
      await AppFeedbackExport.actions(
        context,
        filePath: paths.single,
        documentName: lastName,
      );
    } else {
      AppFeedback.success(
        context,
        AppText.t(
          'تم تصدير ${paths.length} تقرير بنجاح.',
          'Exported ${paths.length} reports successfully.',
        ),
      );
    }
    cubit.clearSelection();
  } on AppError catch (e) {
    if (context.mounted) AppFeedback.error(context, e.message);
  } catch (e) {
    if (context.mounted) AppFeedback.errorFrom(context, e);
  }
}

/// Batch labels for the current selection (one document for all ids).
Future<void> exportSelectedLabels(BuildContext context) async {
  final cubit = context.read<InspectionsCubit>();
  final ids = cubit.state.selectedIds.toList()..sort();
  if (ids.isEmpty) return;
  try {
    final reports = getIt<ReportRepository>();
    final doc = await reports.batchLabelsPdf(ids);
    final file = await reports.saveReport(doc);
    if (!context.mounted) return;
    await AppFeedbackExport.actions(
      context,
      filePath: file.path,
      documentName: file.uri.pathSegments.isEmpty
          ? null
          : file.uri.pathSegments.last,
    );
    cubit.clearSelection();
  } on AppError catch (e) {
    if (context.mounted) AppFeedback.error(context, e.message);
  } catch (e) {
    if (context.mounted) AppFeedback.errorFrom(context, e);
  }
}
