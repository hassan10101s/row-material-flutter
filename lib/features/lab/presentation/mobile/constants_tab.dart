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
import '../../domain/lab_local_repository.dart';
import '../constants_editor.dart';
import '../cubit/constants_cubit.dart';
import '../cubit/constants_state.dart';

/// Mobile global-constant management.
///
/// Two things genuinely differ from desktop, and only these two:
///
///  * the six-column table becomes one card per constant, because a
///    `DataTable` at 400dp would be a horizontal-scrolling smear of six
///    ellipsised columns;
///  * the editor becomes a **full-screen route** instead of a dialog. The
///    desktop dialog is 440 logical px wide with a Cancel/Save row; on a phone
///    that leaves no room for the fields, and a keyboard plus five text fields
///    do not fit in a dialog at all.
///
/// Everything else - the cubit, the repository, the payload written - is shared
/// with the desktop variant through `ConstantsEditor`.
class MobileConstantsTab extends StatelessWidget {
  const MobileConstantsTab({super.key, required this.repo});

  /// Injected by the host. A variant must not resolve its own dependencies:
  /// the host is above both variants, so it is the only place that can be sure
  /// the two experiences were given the same repository.
  final LabLocalRepository repo;

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? constant,
  ]) async {
    final cubit = context.read<ConstantsCubit>();
    final saved = await Navigator.of(context).push<bool>(
      appMaterialPageRoute<bool>(
        // The cubit is captured here, not read inside the route: a pushed route
        // is built under the *root* navigator, so a `context.read` there would
        // look for the provider above the navigator and find nothing.
        builder: (_) =>
            _ConstantsEditorRoute(cubit: cubit, repo: repo, constant: constant),
      ),
    );
    if (saved == true) await cubit.load();
  }

  Future<void> _delete(
    BuildContext context,
    Map<String, dynamic> constant,
  ) async {
    final cubit = context.read<ConstantsCubit>();
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف الثابت', 'Delete constant'),
      name: '${constant['name']}',
    );
    if (!confirmed) return;
    try {
      await cubit.delete((constant['id'] as num).toInt());
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
    final state = context.watch<ConstantsCubit>().state;
    return AppErrorFeedback<ConstantsCubit, ConstantsState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('الثوابت', 'Constants'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),
          // Full-width rather than trailing on the title row: at 400dp a
          // right-aligned compact button leaves a 48dp-tall target sharing a
          // row with a long Arabic title.
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openEditor(context),
              icon: Icon(Icons.add, size: 20.r),
              label: Text(AppText.t('إضافة ثابت', 'Add constant')),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
          Expanded(
            child: state.loading && state.rows.isEmpty
                ? const AppSkeletonList(rows: 6, lines: 3, height: 380)
                : state.rows.isEmpty
                ? AppEmptyState(
                    icon: Icons.functions,
                    title: AppText.t('لا توجد ثوابت', 'No constants'),
                  )
                : ListView.separated(
                    itemCount: state.rows.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, index) {
                      final r = state.rows[index];
                      return _ConstantCard(
                        name: '${r['name']}',
                        symbol: '${r['symbol']}',
                        value: '${r['value_text'] ?? ''}',
                        unit: '${r['unit'] ?? ''}',
                        isExpression:
                            (r['is_expression'] as num?)?.toInt() == 1,
                        onEdit: () => _openEditor(context, r),
                        onDelete: () => _delete(context, r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// One constant as a card: name and symbol on the title line, value and unit
/// beneath, and the two actions as icon buttons in the corner.
class _ConstantCard extends StatelessWidget {
  const _ConstantCard({
    required this.name,
    required this.symbol,
    required this.value,
    required this.unit,
    required this.isExpression,
    required this.onEdit,
    required this.onDelete,
  });

  final String name;
  final String symbol;
  final String value;
  final String unit;
  final bool isExpression;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                      if (symbol.isNotEmpty)
                        Text(
                          symbol,
                          style: TextStyle(
                            fontSize: 12.spMax,
                            color: AppColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                // 48dp is the accessibility floor for a tap target.
                IconButton(
                  tooltip: AppStrings.edit,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: onEdit,
                  icon: Icon(Icons.edit_outlined, size: 20.r),
                ),
                IconButton(
                  tooltip: AppStrings.delete,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: onDelete,
                  icon: Icon(Icons.delete_outline, size: 20.r),
                ),
              ],
            ),
            const Divider(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: Text(
                    isExpression
                        ? value
                        : (unit.isEmpty ? value : '$value $unit'),
                    style: TextStyle(
                      fontSize: 13.spMax,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textStrong,
                    ),
                  ),
                ),
                if (isExpression)
                  Chip(
                    label: Text(AppText.t('تعبير', 'Expression')),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The editor as a full-screen route.
///
/// [cubit] is passed in rather than read from a provider: see [_openEditor].
class _ConstantsEditorRoute extends StatelessWidget {
  const _ConstantsEditorRoute({
    required this.cubit,
    required this.repo,
    this.constant,
  });

  final ConstantsCubit cubit;
  final LabLocalRepository repo;
  final Map<String, dynamic>? constant;

  @override
  Widget build(BuildContext context) {
    return BlocProvider.value(
      value: cubit,
      child: Scaffold(
        appBar: AppBar(title: Text(constantsEditorTitle(constant == null))),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: ConstantsEditor(
              repo: repo,
              constant: constant,
              actions: (context, state) => Row(
                children: [
                  const ConstantsEditorCancel(),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(child: ConstantsEditorSave(state: state)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
