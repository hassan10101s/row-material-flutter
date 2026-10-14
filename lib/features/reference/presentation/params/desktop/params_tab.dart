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
import '../../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../../design_system/widgets/app_selection.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../design_system/export/table_html_export.dart';
import '../../cubit/params_cubit.dart';
import '../../cubit/params_state.dart';
import '../params_editor.dart';

/// Desktop parameter management — port of the Reference app Chemical/Physical
/// Aspects tabs (57_reference_app.js). This is the pre-split screen unchanged.
class DesktopParamsTab extends StatefulWidget {
  const DesktopParamsTab({super.key, required this.parameterType});

  final String parameterType;

  /// Export mapping shared by the desktop table and the mobile list.
  static List<String> exportHeaders() => [
    AppText.t('البارامتر', 'Parameter'),
    AppText.t('الوحدة', 'Unit'),
  ];

  static List<List<String>> exportRows(List<Map<String, dynamic>> rows) => [
    for (final p in rows)
      ['${p['parameter_name'] ?? ''}', '${p['unit'] ?? ''}'],
  ];

  @override
  State<DesktopParamsTab> createState() => _DesktopParamsTabState();
}

class _DesktopParamsTabState extends State<DesktopParamsTab> {
  /// Table indices picked with the checkbox column (same idea every table).
  final Set<int> _selected = <int>{};

  bool get _isChemical => widget.parameterType == 'chemical';

  Future<void> _openEditor(
    BuildContext context, [
    Map<String, dynamic>? param,
  ]) async {
    final cubit = context.read<ParamsCubit>();
    final saved = await showAppWindow<bool>(
      context,
      title: paramEditorTitle(widget.parameterType, param == null),
      icon: _isChemical
          ? Icons.biotech_outlined
          : Icons.remove_red_eye_outlined,
      size: AppWindowSize.sm,
      child: ParamEditor(
        parameterType: widget.parameterType,
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

  String _exportTitle() => _isChemical
      ? AppText.t('التحليل الكيميائي', 'Parameter Chemical Analysis')
      : AppText.t('الفحص الظاهري', 'Physical Aspects');

  Future<void> _exportAll(List<Map<String, dynamic>> rows) =>
      TableHtmlExport.export(
        context,
        filePrefix: 'params',
        title: _exportTitle(),
        headers: DesktopParamsTab.exportHeaders(),
        rows: DesktopParamsTab.exportRows(rows),
      );

  Future<void> _exportSelected(List<Map<String, dynamic>> rows) async {
    final picked = [
      for (var i = 0; i < rows.length; i++)
        if (_selected.contains(i)) rows[i],
    ];
    await TableHtmlExport.export(
      context,
      filePrefix: 'params',
      title: _exportTitle(),
      headers: DesktopParamsTab.exportHeaders(),
      rows: DesktopParamsTab.exportRows(picked),
    );
    if (mounted && picked.isNotEmpty) {
      setState(_selected.clear);
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
          // Desktop title lives in the shell topbar; only actions stay.
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_selected.isNotEmpty) ...[
                    TableSelectionBar(
                      selectedCount: _selected.length,
                      onExportTable: () => _exportSelected(state.rows),
                      onClear: () => setState(_selected.clear),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  Expanded(
                    child: AppPaginatedTable(
                      height: null,
                      minTableWidth: 520,
                      columnFlex: const [1.4, 0.8, 0.8],
                      headers: [...DesktopParamsTab.exportHeaders(), ''],
                      rows: [
                        for (final p in state.rows)
                          [
                            Text('${p['parameter_name'] ?? ''}'),
                            Text('${p['unit'] ?? ''}'),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: AppStrings.edit,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _openEditor(context, p),
                                  icon: Icon(Icons.edit_outlined, size: 18.r),
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
                  AppDesktopLoadMore(
                    loaded: state.rows.length,
                    total: state.total,
                    hasMore: state.hasMore,
                    loadingMore: state.loadingMore,
                    errorMore: state.errorMore,
                    onLoadMore: () => context.read<ParamsCubit>().loadMore(),
                    onRetry: () => context.read<ParamsCubit>().loadMore(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
