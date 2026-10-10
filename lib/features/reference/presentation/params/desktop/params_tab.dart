import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../cubit/params_cubit.dart';
import '../../cubit/params_state.dart';
import '../params_editor.dart';

/// Desktop parameter management — port of the Reference app Chemical/Physical
/// Aspects tabs (57_reference_app.js). This is the pre-split screen unchanged.
class DesktopParamsTab extends StatelessWidget {
  const DesktopParamsTab({super.key, required this.parameterType});

  final String parameterType;

  bool get _isChemical => parameterType == 'chemical';

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? param,
  ]) async {
    final cubit = context.read<ParamsCubit>();
    final saved = await showAppWindow<bool>(
      context,
      title: paramEditorTitle(parameterType, param == null),
      icon: _isChemical ? Icons.biotech_outlined : Icons.remove_red_eye_outlined,
      size: AppWindowSize.sm,
      child: ParamEditor(
        parameterType: parameterType,
        onSubmit: cubit.upsert,
        param: param,
        unitOptions: cubit.state.units,
        actions: (_, state) => ParamEditorActions(state: state),
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
          Row(
            children: [
              Text(
                _isChemical
                    ? AppText.t(
                        'التحليل الكيميائي',
                        'Parameter Chemical Analysis',
                      )
                    : AppText.t('الفحص الظاهري', 'Physical Aspects'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              AppButton(
                small: true,
                icon: Icon(Icons.add, size: 16.r),
                label: AppText.t('بارامتر جديد', 'New Parameter'),
                onPressed: () => _openEditor(context),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isEmpty)
            const AppSkeletonList(rows: 6, lines: 3, height: 380)
          else if (state.rows.isEmpty)
            AppEmptyState(
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
            )
          else
            Flexible(
              child: AppCard(
                padding: EdgeInsets.zero,
                child: SizedBox(
                  width: double.infinity,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.vertical,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: [
                          DataColumn(
                            label: Text(AppText.t('البارامتر', 'Parameter')),
                          ),
                          DataColumn(
                            label: Text(AppText.t('الوحدة', 'Unit')),
                          ),
                          DataColumn(label: Text('')),
                        ],
                        rows: [
                          for (final p in state.rows)
                            DataRow(
                              cells: [
                                DataCell(Text('${p['parameter_name'] ?? ''}')),
                                DataCell(Text('${p['unit'] ?? ''}')),
                                DataCell(
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: AppStrings.edit,
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () =>
                                            _openEditor(context, p),
                                        icon: Icon(
                                          Icons.edit_outlined,
                                          size: 18.r,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: AppStrings.delete,
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => _delete(context, p),
                                        icon: Icon(
                                          Icons.delete_outline,
                                          size: 18.r,
                                          color: AppColors.danger,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
