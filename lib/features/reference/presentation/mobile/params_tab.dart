import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../cubit/params_cubit.dart';
import '../cubit/params_state.dart';
import '../params_editor.dart';

/// Mobile parameter management.
///
/// The table becomes a card per parameter, and the 420dp editor dialog becomes
/// a full-screen route to fit the form on a 400dp grid.
class MobileParamsTab extends StatelessWidget {
  const MobileParamsTab({super.key, required this.parameterType});

  final String parameterType;

  bool get _isChemical => parameterType == 'chemical';

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? param,
  ]) async {
    final cubit = context.read<ParamsCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        builder: (_) => _ParamEditorRoute(
          parameterType: parameterType,
          param: param,
          onSubmit: cubit.upsert,
          unitOptions: cubit.state.units,
        ),
      ),
    );
    if (saved != true || !context.mounted) return;
    await cubit.load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> param) async {
    final cubit = context.read<ParamsCubit>();
    final name = '${param['parameter_name'] ?? ''}';
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف البارامتر', 'Delete parameter'),
      name: name,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await cubit.delete(name);
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      }
      await cubit.load();
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ParamsCubit>().state;
    return AppErrorFeedback<ParamsCubit, ParamsState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _isChemical
                ? AppText.t('التحليل الكيميائي', 'Chemical Analysis')
                : AppText.t('الفحص الظاهري', 'Physical Aspects'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: () => _openEditor(context),
            icon: Icon(Icons.add, size: 20.r),
            label: Text(AppText.t('بارامتر جديد', 'New Parameter')),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isEmpty)
            const AppSkeletonList(rows: 6, lines: 3, height: 380)
          else if (state.rows.isEmpty)
            Expanded(
              child: AppEmptyState(
                icon: Icons.tag_outlined,
                title: _isChemical
                    ? AppText.t(
                        'لا توجد بارامترات كيميائية.',
                        'No chemical parameters.',
                      )
                    : AppText.t(
                        'لا توجد بارامترات ظاهرية.',
                        'No physical parameters.',
                      ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: state.rows.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final p = state.rows[index];
                  return _ParamCard(
                    name: '${p['parameter_name'] ?? ''}',
                    unit: '${p['unit'] ?? ''}',
                    onEdit: () => _openEditor(context, p),
                    onDelete: () => _delete(context, p),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// One parameter and its canonical unit as a card.
class _ParamCard extends StatelessWidget {
  const _ParamCard({
    required this.name,
    required this.unit,
    required this.onEdit,
    required this.onDelete,
  });

  final String name;
  final String? unit;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: 14.spMax,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textStrong,
                    ),
                  ),
                  if (unit != null)
                    Text(
                      unit!,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: AppStrings.edit,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onEdit,
              icon: Icon(Icons.edit_outlined, size: 20.r),
            ),
            IconButton(
              tooltip: AppStrings.delete,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: onDelete,
              icon: Icon(
                Icons.delete_outline,
                size: 20.r,
                color: AppColors.danger,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The editor as a full-screen route.
class _ParamEditorRoute extends StatelessWidget {
  const _ParamEditorRoute({
    required this.parameterType,
    required this.onSubmit,
    this.unitOptions,
    this.param,
  });

  final String parameterType;
  final Future<void> Function(String name, String unit) onSubmit;

  /// Known unit symbols, offered as a shortcut for chemical rows.
  final List<Map<String, dynamic>>? unitOptions;
  final Map<String, dynamic>? param;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(paramEditorTitle(parameterType, param == null)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: ParamEditor(
            parameterType: parameterType,
            onSubmit: onSubmit,
            param: param,
            unitOptions: parameterType == 'chemical' ? unitOptions : null,
            actions: (_, state) => ParamEditorActions(state: state),
          ),
        ),
      ),
    );
  }
}
