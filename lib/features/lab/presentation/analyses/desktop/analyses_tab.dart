import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../analysis_editor.dart';
import '../../cubit/analyses_cubit.dart';
import '../../cubit/analyses_state.dart';
import '../widgets/analyses_list.dart';

/// Desktop analyses: the pre-split pixels (header + table + 720px dialog).
class DesktopAnalysesTab extends StatelessWidget {
  const DesktopAnalysesTab({super.key});

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? analysis,
  ]) async {
    final cubit = context.read<AnalysesCubit>();
    final key = GlobalKey<AnalysisEditorState>();
    final saved = await showAppWindow<bool>(
      context,
      title: analysis == null
          ? AppText.t('إضافة تحليل', 'Add analysis')
          : AppText.t('تعديل تحليل', 'Edit analysis'),
      icon: Icons.biotech_outlined,
      size: AppWindowSize.md,
      maxWidth: 720,
      actions: [
        AppButton(
          label: AppStrings.cancel,
          style: AppButtonStyle.secondary,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        AppButton(
          label: AppStrings.save,
          onPressed: () => key.currentState?.save(),
        ),
      ],
      child: AnalysisEditor(key: key, analysis: analysis),
    );
    if (saved == true) await cubit.load();
  }

  Future<void> _delete(
    BuildContext context,
    Map<String, dynamic> analysis,
  ) async {
    final cubit = context.read<AnalysesCubit>();
    final confirmed = await showAppConfirm(
      context,
      title: AppText.t('حذف التحليل', 'Delete analysis'),
      message: '${AppText.t('حذف', 'Delete')} "${analysis['name']}"؟',
      danger: true,
      confirmLabel: AppStrings.delete,
      cancelLabel: AppStrings.cancel,
    );
    if (confirmed != true) return;
    try {
      await cubit.delete((analysis['id'] as num).toInt());
      if (!context.mounted) return;
      AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      await cubit.load();
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AnalysesCubit>().state;
    return AppErrorFeedback<AnalysesCubit, AnalysesState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnalysesHeader(
            onAdd: () => _openEditor(context),
            canExport: state.rows.isNotEmpty,
            onExportTable: () => TableHtmlExport.export(
              context,
              filePrefix: 'analyses',
              title: AnalysesTable.exportTitle(),
              headers: AnalysesTable.exportHeaders(),
              rows: AnalysesTable.exportRows(state.rows),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
          Expanded(
            child: state.loading && state.rows.isEmpty
                ? const AppSkeletonList(rows: 6, lines: 3, height: 380)
                : state.rows.isEmpty
                ? Text(AppText.t('لا توجد تحليلات', 'No analyses'))
                : Column(
                    children: [
                      Expanded(
                        child: AnalysesTable(
                          rows: state.rows,
                          onEdit: (r) => _openEditor(context, r),
                          onDelete: (r) => _delete(context, r),
                        ),
                      ),
                      AppDesktopLoadMore(
                        loaded: state.rows.length,
                        total: state.total,
                        hasMore: state.hasMore,
                        loadingMore: state.loadingMore,
                        errorMore: state.errorMore,
                        onLoadMore: () =>
                            context.read<AnalysesCubit>().loadMore(),
                        onRetry: () =>
                            context.read<AnalysesCubit>().loadMore(),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
