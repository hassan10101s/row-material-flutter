import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_window.dart';
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
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AppWindow(
        title: analysis == null ? 'إضافة تحليل' : 'تعديل تحليل',
        icon: Icons.biotech_outlined,
        maxWidth: 720,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => key.currentState?.save(),
            child: Text(AppStrings.save),
          ),
        ],
        child: AnalysisEditor(key: key, analysis: analysis),
      ),
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
          AnalysesHeader(onAdd: () => _openEditor(context)),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
          Expanded(
            child: state.loading && state.rows.isEmpty
                ? const AppSkeletonList(rows: 6, lines: 3, height: 380)
                : state.rows.isEmpty
                ? Text(AppText.t('لا توجد تحليلات', 'No analyses'))
                : AnalysesTable(
                    rows: state.rows,
                    onEdit: (r) => _openEditor(context, r),
                    onDelete: (r) => _delete(context, r),
                  ),
          ),
        ],
      ),
    );
  }
}
