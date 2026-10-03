import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../domain/lab_local_repository.dart';
import '../constants_editor.dart';
import '../cubit/constants_cubit.dart';
import '../cubit/constants_state.dart';

/// Desktop global-constant management: a six-column `DataTable` beside a
/// compact "Add constant" button.
///
/// This is the pre-split screen unchanged. The 1280x720 authoring grid is
/// what every `.w`/`.r` above was tuned against, so nothing here may move -
/// that is why the table is inline rather than routed through
/// `AppAdaptiveDataView`: at desktop widths the two are identical, and keeping
/// the table literal keeps the visual-parity claim verifiable.
class DesktopConstantsTab extends StatelessWidget {
  const DesktopConstantsTab({super.key, required this.repo});

  /// Injected by the host - see the note on `MobileConstantsTab.repo`.
  final LabLocalRepository repo;

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? constant,
  ]) async {
    final cubit = context.read<ConstantsCubit>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(constantsEditorTitle(constant == null)),
        content: SizedBox(
          width: 440.w,
          child: SingleChildScrollView(
            child: ConstantsEditor(
              repo: repo,
              constant: constant,
              actions: (context, state) => Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const ConstantsEditorCancel(),
                  const SizedBox(width: AppSpacing.sm),
                  ConstantsEditorSave(state: state),
                ],
              ),
            ),
          ),
        ),
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
          Row(
            children: [
              Text(
                AppText.t('الثوابت', 'Constants'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              AppButton(
                small: true,
                label: AppText.t('إضافة ثابت', 'Add constant'),
                icon: Icon(Icons.add, size: 16.r),
                onPressed: () => _openEditor(context),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
          Expanded(
            child: state.loading && state.rows.isEmpty
                ? const AppSkeletonList(rows: 6, lines: 3, height: 380)
                : state.rows.isEmpty
                ? Text(AppText.t('لا توجد ثوابت', 'No constants'))
                : AppCard(
                    padding: EdgeInsets.zero,
                    child: SingleChildScrollView(
                      child: SizedBox(
                        width: double.infinity,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: [
                              DataColumn(
                                label: Text(AppText.t('الاسم', 'Name')),
                              ),
                              DataColumn(
                                label: Text(AppText.t('الرمز', 'Symbol')),
                              ),
                              DataColumn(
                                label: Text(AppText.t('القيمة', 'Value')),
                              ),
                              DataColumn(
                                label: Text(AppText.t('الوحدة', 'Unit')),
                              ),
                              DataColumn(label: Text(AppText.t('نوع', 'Type'))),
                              DataColumn(label: Text('')),
                            ],
                            rows: [
                              for (final r in state.rows)
                                DataRow(
                                  cells: [
                                    DataCell(Text('${r['name']}')),
                                    DataCell(Text('${r['symbol']}')),
                                    DataCell(Text('${r['value_text'] ?? ''}')),
                                    DataCell(Text('${r['unit'] ?? ''}')),
                                    DataCell(
                                      Text(
                                        (r['is_expression'] as num?)?.toInt() ==
                                                1
                                            ? AppText.t('تعبير', 'Expression')
                                            : AppText.t('قيمة', 'Value'),
                                      ),
                                    ),
                                    DataCell(
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            tooltip: AppStrings.edit,
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () =>
                                                _openEditor(context, r),
                                            icon: Icon(
                                              Icons.edit_outlined,
                                              size: 18.r,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: AppStrings.delete,
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () =>
                                                _delete(context, r),
                                            icon: Icon(
                                              Icons.delete_outline,
                                              size: 18.r,
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
