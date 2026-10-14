import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../../design_system/widgets/app_selection.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../../../core/formula_engine.dart';
import '../../cubit/inventory_cubit.dart';
import '../../cubit/inventory_state.dart';
import '../inventory_forms.dart';

/// Desktop inventory: the pre-split table verbatim (1280x720 grid).
class DesktopInventoryTab extends StatefulWidget {
  const DesktopInventoryTab({super.key});

  /// Export mapping shared by the desktop table and the mobile cards.
  static List<String> exportHeaders() => [
    AppText.t('الاسم', 'Name'),
    AppText.t('النوع', 'Category'),
    AppText.t('الوحدة', 'Unit'),
    AppText.t('الكمية', 'Qty'),
    AppText.t('الحد الأدنى', 'Min'),
    AppText.t('الحالة', 'Status'),
  ];

  static List<List<String>> exportRows(List<Map<String, dynamic>> rows) => [
    for (final r in rows)
      [
        '${r['name']}',
        inventoryCategoryLabel(r['category']),
        '${r['unit'] ?? ''}',
        '${r['current_qty'] ?? 0}',
        '${r['min_qty'] ?? 0}',
        _statusLabel(r),
      ],
  ];

  static String exportTitle() => AppText.t('المخزون', 'Inventory');

  static String _statusLabel(Map<String, dynamic> r) {
    final qty = (r['current_qty'] as num?)?.toDouble() ?? 0;
    final min = (r['min_qty'] as num?)?.toDouble() ?? 0;
    if (qty <= 0) return AppText.t('نفد', 'Empty');
    if (qty < min) return AppText.t('منخفض', 'Low');
    return AppText.t('متوفر', 'OK');
  }

  @override
  State<DesktopInventoryTab> createState() => _DesktopInventoryTabState();
}

class _DesktopInventoryTabState extends State<DesktopInventoryTab> {
  /// Table indices picked with the checkbox column (same idea every table).
  final Set<int> _selected = <int>{};

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

  Future<void> _exportAll(List<Map<String, dynamic>> rows) =>
      TableHtmlExport.export(
        context,
        filePrefix: 'inventory',
        title: DesktopInventoryTab.exportTitle(),
        headers: DesktopInventoryTab.exportHeaders(),
        rows: DesktopInventoryTab.exportRows(rows),
      );

  Future<void> _exportSelected(List<Map<String, dynamic>> rows) async {
    final picked = [
      for (var i = 0; i < rows.length; i++)
        if (_selected.contains(i)) rows[i],
    ];
    await TableHtmlExport.export(
      context,
      filePrefix: 'inventory',
      title: DesktopInventoryTab.exportTitle(),
      headers: DesktopInventoryTab.exportHeaders(),
      rows: DesktopInventoryTab.exportRows(picked),
    );
    if (mounted && picked.isNotEmpty) {
      setState(_selected.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<InventoryCubit>().state;
    return AppErrorFeedback<InventoryCubit, InventoryState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title lives in the shell topbar on desktop; only actions stay.
          Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: AppText.t('تصدير جدول', 'Export table'),
                visualDensity: VisualDensity.compact,
                onPressed: state.rows.isEmpty
                    ? null
                    : () => _exportAll(state.rows),
                icon: Icon(Icons.table_view_outlined, size: 18.r),
              ),
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
          if (_selected.isNotEmpty) ...[
            TableSelectionBar(
              selectedCount: _selected.length,
              onExportTable: () => _exportSelected(state.rows),
              onClear: () => setState(_selected.clear),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          Expanded(
            child: state.loading && state.rows.isEmpty
                ? const AppSkeletonList(rows: 6, lines: 3, height: 380)
                : state.rows.isEmpty
                ? Text(AppText.t('لا توجد مواد', 'No inventory items'))
                : AppPaginatedTable(
                    height: null,
                    minTableWidth: 760,
                    columnFlex: const [1.4, 0.9, 0.6, 0.7, 0.7, 0.7, 0.9],
                    headers: [...DesktopInventoryTab.exportHeaders(), ''],
                    rows: [
                      for (final r in state.rows)
                        [
                          Text('${r['name']}'),
                          Text(
                            inventoryCategoryLabel(r['category']),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text('${r['unit'] ?? ''}'),
                          Text('${r['current_qty'] ?? 0}'),
                          Text('${r['min_qty'] ?? 0}'),
                          _statusCell(r),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: AppText.t('تسوية الكمية', 'Adjust'),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openAdjust(context, r),
                                icon: Icon(Icons.swap_vert, size: 18.r),
                              ),
                              IconButton(
                                tooltip: AppStrings.edit,
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _openEdit(context, r),
                                icon: Icon(Icons.edit_outlined, size: 18.r),
                              ),
                            ],
                          ),
                        ],
                    ],
                    selectedIndices: _selected,
                    selectHidden: true,
                    onToggleIndex: (i) => setState(() {
                      if (!_selected.remove(i)) _selected.add(i);
                    }),
                    selectAllValue: _selected.isEmpty
                        ? false
                        : _selected.length >= state.rows.length
                        ? true
                        : null,
                    onToggleAll: (_) => setState(() {
                      if (_selected.length >= state.rows.length) {
                        _selected.clear();
                      } else {
                        _selected.addAll(
                          List.generate(state.rows.length, (i) => i),
                        );
                      }
                    }),
                  ),
          ),
          if (state.rows.isNotEmpty)
            AppDesktopLoadMore(
              loaded: state.rows.length,
              total: state.total,
              hasMore: state.hasMore,
              loadingMore: state.loadingMore,
              errorMore: state.errorMore,
              onLoadMore: () => context.read<InventoryCubit>().loadMore(),
              onRetry: () => context.read<InventoryCubit>().loadMore(),
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
