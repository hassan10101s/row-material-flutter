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
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../../design_system/widgets/app_selection.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../lab/domain/lab_result_repository.dart';
import '../../cubit/reference_cubit.dart';
import '../../cubit/reference_state.dart';
import '../../../domain/reference_repository.dart';
import 'material_editor.dart';

/// Desktop reference materials list — port of the MaterialsView list section
/// (42_materials_editor.js). The pre-split screen unchanged.
class DesktopMaterialsTab extends StatefulWidget {
  const DesktopMaterialsTab({
    super.key,
    required this.refRepo,
    required this.labConfig,
  });

  final ReferenceRepository refRepo;
  final LabConfigurationRepository labConfig;

  /// Export mapping shared by the desktop table and the mobile list: the
  /// exported HTML file is a table either way.
  static List<String> exportHeaders() => [
    AppText.t('المادة', 'Material'),
    AppText.t('الكود', 'Code'),
    AppText.t('الحالة', 'Status'),
  ];

  static List<List<String>> exportRows(List<Map<String, dynamic>> rows) => [
    for (final m in rows)
      [
        '${m['material_name'] ?? ''}',
        '${m['material_code'] ?? ''}',
        (m['active'] as num?)?.toInt() == 0
            ? AppText.t('محذوف', 'Deleted')
            : AppText.t('نشط', 'Active'),
      ],
  ];

  static String exportTitle() =>
      AppText.t('خامات مرجعية', 'Reference Materials');

  @override
  State<DesktopMaterialsTab> createState() => _DesktopMaterialsTabState();
}

class _DesktopMaterialsTabState extends State<DesktopMaterialsTab> {
  final _searchCtrl = TextEditingController();
  int? _confirmDeleteId;

  /// Table indices (into the filtered [_filtered] list) picked with the
  /// checkbox column — the same select-all + gold-bar idea as every table.
  final Set<int> _selected = <int>{};

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _openEditor([int? materialId]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => DesktopMaterialEditor(
        refRepo: widget.refRepo,
        labConfig: widget.labConfig,
        materialId: materialId,
      ),
    );
    if (saved != true || !mounted) return;
    await context.read<ReferenceCubit>().load();
    if (mounted) {
      AppFeedback.success(context, AppText.t('تم الحفظ', 'Saved'));
    }
  }

  Future<void> _delete(
    BuildContext context,
    Map<String, dynamic> material,
  ) async {
    final id = (material['id'] as num).toInt();
    setState(() => _confirmDeleteId = null);
    try {
      await context.read<ReferenceCubit>().delete(id);
      if (context.mounted) {
        AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
      }
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  List<Map<String, dynamic>> _filtered(List<Map<String, dynamic>> all) {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return [
      for (final m in all)
        if ('${m['material_name'] ?? ''}'.toLowerCase().contains(q) ||
            '${m['material_code'] ?? ''}'.toLowerCase().contains(q))
          m,
    ];
  }

  /// Export mapping shared by the desktop table and the mobile list: the
  /// exported HTML file is a table either way.
  Future<void> _exportAll(List<Map<String, dynamic>> rows) =>
      TableHtmlExport.export(
        context,
        filePrefix: 'materials',
        title: DesktopMaterialsTab.exportTitle(),
        headers: DesktopMaterialsTab.exportHeaders(),
        rows: DesktopMaterialsTab.exportRows(rows),
      );

  Future<void> _exportSelected(List<Map<String, dynamic>> rows) async {
    final picked = [
      for (var i = 0; i < rows.length; i++)
        if (_selected.contains(i)) rows[i],
    ];
    await TableHtmlExport.export(
      context,
      filePrefix: 'materials',
      title: DesktopMaterialsTab.exportTitle(),
      headers: DesktopMaterialsTab.exportHeaders(),
      rows: DesktopMaterialsTab.exportRows(picked),
    );
    if (mounted && picked.isNotEmpty) {
      setState(_selected.clear);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReferenceCubit>().state;
    final rows = _filtered(state.materials);
    return AppErrorFeedback<ReferenceCubit, ReferenceState>(
      selector: (s) => s.error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Desktop title lives in the shell topbar; search and every
          // action share one row so no vertical space is wasted.
          Row(
            children: [
              Expanded(
                child: AppField(
                  label: AppText.t(
                    'بحث بالاسم أو الكود',
                    'Search by name or code...',
                  ),
                  controller: _searchCtrl,
                  onChanged: (_) => setState(() {
                    _selected.clear();
                  }),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton(
                tooltip: AppText.t('تصدير جدول', 'Export table'),
                visualDensity: VisualDensity.compact,
                onPressed: rows.isEmpty ? null : () => _exportAll(rows),
                icon: Icon(Icons.table_view_outlined, size: 18.r),
              ),
              AppButton(
                small: true,
                icon: Icon(Icons.add, size: 16.r),
                label: AppText.t('إضافة مادة', 'Add New Material'),
                onPressed: () => _openEditor(),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (state.loading && state.materials.isEmpty)
            const AppSkeletonList(rows: 6, lines: 3, height: 380)
          else if (rows.isEmpty)
            AppEmptyState(
              icon: Icons.book_outlined,
              title: state.materials.isEmpty
                  ? AppText.t('لا توجد مواد', 'No materials found.')
                  : AppText.t('لا توجد نتائج مطابقة', 'No matching materials.'),
              subtitle: state.materials.isEmpty
                  ? AppText.t(
                      'أضف مادة جديدة أو استوردها من Reference.xlsx.',
                      'Add a new material or import from Reference.xlsx.',
                    )
                  : AppText.t('جرّب مسح البحث.', 'Try clearing the search.'),
            )
          else
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_selected.isNotEmpty) ...[
                    TableSelectionBar(
                      selectedCount: _selected.length,
                      onExportTable: () => _exportSelected(rows),
                      onClear: () => setState(_selected.clear),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  Expanded(
                    child: AppPaginatedTable(
                      height: null,
                      minTableWidth: 640,
                      columnFlex: const [1.6, 1.0, 0.8, 1.0],
                      headers: [
                        ...DesktopMaterialsTab.exportHeaders(),
                        AppText.t('الإجراءات', 'Actions'),
                      ],
                      rows: [
                        for (var i = 0; i < rows.length; i++)
                          _tableRow(context, rows[i]),
                      ],
                      selectedIndices: _selected,
                      selectHidden: true,
                      onToggleIndex: (i) => setState(() {
                        if (!_selected.remove(i)) _selected.add(i);
                      }),
                      selectAllValue: _selected.isEmpty
                          ? false
                          : _selected.length >= rows.length
                          ? true
                          : null,
                      onToggleAll: (_) => setState(() {
                        if (_selected.length >= rows.length) {
                          _selected.clear();
                        } else {
                          _selected.addAll(
                            List.generate(rows.length, (i) => i),
                          );
                        }
                      }),
                    ),
                  ),
                  AppDesktopLoadMore(
                    loaded: rows.length,
                    total: state.total,
                    hasMore: state.hasMore,
                    loadingMore: state.loadingMore,
                    errorMore: state.errorMore,
                    onLoadMore: () => context.read<ReferenceCubit>().loadMore(),
                    onRetry: () => context.read<ReferenceCubit>().loadMore(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _tableRow(BuildContext context, Map<String, dynamic> m) {
    final name = '${m['material_name'] ?? ''}';
    final inactive = (m['active'] as num?)?.toInt() == 0;
    final isConfirming = _confirmDeleteId == (m['id'] as num).toInt();
    return [
      Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: inactive ? AppColors.textMuted : null),
      ),
      Text(
        '${m['material_code'] ?? ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      inactive
          ? Text(
              AppText.t('محذوف', 'Deleted'),
              style: TextStyle(color: AppColors.danger, fontSize: 12.spMax),
            )
          : Text(
              AppText.t('نشط', 'Active'),
              style: TextStyle(color: AppColors.success, fontSize: 12.spMax),
            ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inactive)
            const SizedBox.shrink()
          else ...[
            IconButton(
              tooltip: AppStrings.edit,
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.edit_outlined, size: 18.r),
              onPressed: () => _openEditor((m['id'] as num).toInt()),
            ),
            const SizedBox(width: AppSpacing.xs),
            if (isConfirming)
              AppButton(
                small: true,
                style: AppButtonStyle.danger,
                label: AppText.t('تأكيد؟', 'Confirm?'),
                onPressed: () => _delete(context, m),
              )
            else
              IconButton(
                tooltip: AppStrings.delete,
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  Icons.delete_outline,
                  size: 18.r,
                  color: AppColors.danger,
                ),
                onPressed: () =>
                    setState(() => _confirmDeleteId = (m['id'] as num).toInt()),
              ),
            if (isConfirming)
              AppButton(
                small: true,
                style: AppButtonStyle.ghost,
                label: AppText.t('إلغاء', 'Cancel'),
                onPressed: () => setState(() => _confirmDeleteId = null),
              ),
          ],
        ],
      ),
    ];
  }
}
