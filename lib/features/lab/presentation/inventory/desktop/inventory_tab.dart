import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../core/formula_engine.dart';
import '../../cubit/inventory_cubit.dart';
import '../../cubit/inventory_state.dart';
import '../inventory_forms.dart';

/// Desktop inventory: the pre-split table verbatim (1280x720 grid).
class DesktopInventoryTab extends StatelessWidget {
  const DesktopInventoryTab({super.key});

  Future<void> _openAdd(BuildContext context) async {
    final cubit = context.read<InventoryCubit>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => const InventoryItemDialog(),
    );
    if (saved == true) await cubit.load();
  }

  Future<void> _openEdit(BuildContext context, Map<String, dynamic> row) async {
    final cubit = context.read<InventoryCubit>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => InventoryItemDialog(item: row),
    );
    if (saved == true) await cubit.load();
  }

  Future<void> _openAdjust(
    BuildContext context,
    Map<String, dynamic> row,
  ) async {
    final cubit = context.read<InventoryCubit>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => InventoryAdjustDialog(item: row),
    );
    if (saved == true) await cubit.load();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<InventoryCubit>().state;
    return AppErrorFeedback<InventoryCubit, InventoryState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppText.t('المخزون', 'Inventory'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              AppButton(
                small: true,
                label: AppText.t('إضافة مادة', 'Add item'),
                icon: Icon(Icons.add, size: 16.r),
                onPressed: () => _openAdd(context),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.rows.isNotEmpty) const AppRefreshBar(),
          Expanded(
            child: state.loading && state.rows.isEmpty
                ? const AppSkeletonList(rows: 6, lines: 3, height: 380)
                : state.rows.isEmpty
                ? Text(AppText.t('لا توجد مواد', 'No inventory items'))
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
                                label: Text(AppText.t('النوع', 'Category')),
                              ),
                              DataColumn(
                                label: Text(AppText.t('الوحدة', 'Unit')),
                              ),
                              DataColumn(
                                label: Text(AppText.t('الكمية', 'Qty')),
                              ),
                              DataColumn(
                                label: Text(AppText.t('الحد الأدنى', 'Min')),
                              ),
                              DataColumn(
                                label: Text(AppText.t('الحالة', 'Status')),
                              ),
                              DataColumn(label: Text('')),
                            ],
                            rows: [
                              for (final r in state.rows)
                                DataRow(
                                  cells: [
                                    DataCell(Text('${r['name']}')),
                                    DataCell(
                                      Text(
                                        inventoryCategoryLabel(
                                          r['category'],
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    DataCell(Text('${r['unit'] ?? ''}')),
                                    DataCell(Text('${r['current_qty'] ?? 0}')),
                                    DataCell(Text('${r['min_qty'] ?? 0}')),
                                    DataCell(_statusCell(r)),
                                    DataCell(
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            tooltip: AppText.t(
                                              'تسوية الكمية',
                                              'Adjust',
                                            ),
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () =>
                                                _openAdjust(context, r),
                                            icon: Icon(
                                              Icons.swap_vert,
                                              size: 18.r,
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: AppStrings.edit,
                                            visualDensity:
                                                VisualDensity.compact,
                                            onPressed: () =>
                                                _openEdit(context, r),
                                            icon: Icon(
                                              Icons.edit_outlined,
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

  Widget _statusCell(Map<String, dynamic> r) {
    final qty = (r['current_qty'] as num?)?.toDouble() ?? 0;
    final min = (r['min_qty'] as num?)?.toDouble() ?? 0;
    if (qty <= 0) {
      return Text(
        AppText.t('نفد', 'Empty'),
        style: TextStyle(color: AppColors.danger, fontSize: 12.spMax),
      );
    }
    if (qty < min) {
      return Text(
        AppText.t('منخفض', 'Low'),
        style: TextStyle(color: AppColors.partial, fontSize: 12.spMax),
      );
    }
    return Text(
      AppText.t('متوفر', 'OK'),
      style: TextStyle(color: AppColors.success, fontSize: 12.spMax),
    );
  }
}
