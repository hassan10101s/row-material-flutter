import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../cubit/units_cubit.dart';
import '../cubit/units_state.dart';
import '../units_editor.dart';

/// Desktop units settings — port of the Reference app Units Settings tab
/// (57_reference_app.js). Symbol / name / dimension CRUD on `lab_units`, kept
/// as the pre-split DataTable + AlertDialog screen.
///
/// The editor's save is passed in as a callback rather than read from the
/// cubit inside the dialog; see [UnitsEditor.onSubmit].
class DesktopUnitsTab extends StatelessWidget {
  const DesktopUnitsTab({super.key});

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? unit,
  ]) async {
    final cubit = context.read<UnitsCubit>();
    final saved = await showAppWindow<bool>(
      context,
      title: unitsEditorTitle(unit == null),
      icon: Icons.straighten_outlined,
      size: AppWindowSize.sm,
      child: UnitsEditor(
        onSubmit: cubit.upsert,
        unit: unit,
        actions: (_, state) => UnitsEditorActions(state: state),
      ),
    );
    if (saved != true || !context.mounted) return;
    await cubit.load();
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> unit) async {
    final cubit = context.read<UnitsCubit>();
    final symbol = '${unit['symbol'] ?? ''}';
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف الوحدة', 'Delete unit'),
      name: symbol,
    );
    if (!confirmed || !context.mounted) return;
    try {
      await cubit.delete(symbol);
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
    final state = context.watch<UnitsCubit>().state;
    return AppErrorFeedback<UnitsCubit, UnitsState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppText.t('إعدادات الوحدات', 'Units Settings'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              AppButton(
                small: true,
                icon: Icon(Icons.add, size: 16.r),
                label: AppText.t('وحدة جديدة', 'New Unit'),
                onPressed: () => _openEditor(context),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isEmpty)
            const AppSkeletonList(rows: 6, lines: 3, height: 380)
          else if (state.rows.isEmpty)
            AppEmptyState(
              icon: Icons.straighten_outlined,
              title: AppText.t('لا توجد وحدات.', 'No units found.'),
              subtitle: AppText.t(
                'أضف وحدات مثل % و mg/kg و ppm.',
                'Add units like %, mg/kg, ppm.',
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
                          DataColumn(label: Text(AppText.t('الرمز', 'Symbol'))),
                          DataColumn(label: Text(AppText.t('الاسم', 'Name'))),
                          DataColumn(
                            label: Text(AppText.t('البعد', 'Dimension')),
                          ),
                          DataColumn(label: Text('')),
                        ],
                        rows: [
                          for (final u in state.rows)
                            DataRow(
                              cells: [
                                DataCell(
                                  Text(
                                    '${u['symbol'] ?? ''}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                DataCell(Text('${u['name'] ?? '-'}')),
                                DataCell(Text('${u['dimension'] ?? '-'}')),
                                DataCell(
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: AppStrings.edit,
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () =>
                                            _openEditor(context, u),
                                        icon: Icon(
                                          Icons.edit_outlined,
                                          size: 18.r,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: AppStrings.delete,
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () => _delete(context, u),
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
