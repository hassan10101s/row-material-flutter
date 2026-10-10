import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../analysis_editor.dart';
import '../../cubit/analyses_cubit.dart';
import '../../cubit/analyses_state.dart';
import '../widgets/analyses_list.dart';

/// Mobile analyses: cards + full-screen editor (no DataTable, no dialog).
///
/// A 720px formula editor cannot live in a phone dialog, so the editor
/// becomes a route with a 52h bottom bar — same [AnalysisEditor] and same
/// save path as desktop. Delete confirmation adapts itself
/// ([showAppConfirm] renders a bottom sheet below 720px).
class MobileAnalysesTab extends StatelessWidget {
  const MobileAnalysesTab({super.key});

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? analysis,
  ]) async {
    final cubit = context.read<AnalysesCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        // Captured here, not read inside the route: a pushed route builds
        // under the root navigator, above this provider.
        builder: (_) => BlocProvider.value(
          value: cubit,
          child: _AnalysisEditorRoute(analysis: analysis),
        ),
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
          AnalysesHeader(
            compact: true,
            onAdd: () => _openEditor(context),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
          Expanded(
            child: state.loading && state.rows.isEmpty
                ? const AppSkeletonList(rows: 6, lines: 3, height: 380)
                : state.rows.isEmpty
                ? AppEmptyState(
                    icon: Icons.biotech_outlined,
                    title: AppText.t('لا توجد تحليلات', 'No analyses'),
                  )
                : AnalysesCards(
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

/// Full-screen editor route: same form, phone chrome.
class _AnalysisEditorRoute extends StatefulWidget {
  const _AnalysisEditorRoute({this.analysis});
  final Map<String, dynamic>? analysis;

  @override
  State<_AnalysisEditorRoute> createState() => _AnalysisEditorRouteState();
}

class _AnalysisEditorRouteState extends State<_AnalysisEditorRoute> {
  final _key = GlobalKey<AnalysisEditorState>();

  @override
  Widget build(BuildContext context) {
    final state = _key.currentState;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.analysis == null ? 'إضافة تحليل' : 'تعديل تحليل',
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.pageMobile),
                child: AnalysisEditor(key: _key, analysis: widget.analysis),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.pageMobile),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: AppSpacing.mobileCtaHeight.h,
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: Text(AppText.t('إلغاء', 'Cancel')),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: AppSpacing.mobileCtaHeight.h,
                      child: FilledButton(
                        onPressed: state?.saving == true
                            ? null
                            : () => _key.currentState?.save(),
                        child: Text(AppText.t('حفظ', 'Save')),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
