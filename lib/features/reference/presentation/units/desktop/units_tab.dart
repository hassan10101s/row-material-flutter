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
import '../../cubit/units_cubit.dart';
import '../../cubit/units_state.dart';
import '../units_editor.dart';

/// Desktop units settings — port of the Reference app Units Settings tab
/// (57_reference_app.js). Symbol / name / dimension CRUD on `lab_units`, kept
/// as the pre-split DataTable + AlertDialog screen.
///
/// The editor's save is passed in as a callback rather than read from the
/// cubit inside the dialog; see [UnitsEditor.onSubmit].
class DesktopUnitsTab extends StatefulWidget {
  const DesktopUnitsTab({super.key});

  /// Export mapping shared by the desktop table and the mobile list.
  static List<String> exportHeaders() => [
    AppText.t('الرمز', 'Symbol'),
    AppText.t('الاسم', 'Name'),
    AppText.t('البعد', 'Dimension'),
    AppText.t('الاستخدام', 'Used in'),
  ];

  static List<List<String>> exportRows(
    List<Map<String, dynamic>> rows,
    Map<String, int> usage,
  ) => [
    for (final u in rows)
      [
        '${u['symbol'] ?? ''}',
        '${u['name'] ?? '-'}',
        '${u['dimension'] ?? '-'}',
        '${usage['${u['symbol'] ?? ''}'] ?? 0}',
      ],
  ];

  static String exportTitle() => AppText.t('إعدادات الوحدات', 'Units Settings');

  @override
  State<DesktopUnitsTab> createState() => _DesktopUnitsTabState();
}

class _DesktopUnitsTabState extends State<DesktopUnitsTab> {
  /// Table indices picked with the checkbox column (same idea every table).
  final Set<int> _selected = <int>{};

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

  Future<void> _exportAll(
    List<Map<String, dynamic>> rows,
    Map<String, int> usage,
  ) => TableHtmlExport.export(
    context,
    filePrefix: 'units',
    title: DesktopUnitsTab.exportTitle(),
    headers: DesktopUnitsTab.exportHeaders(),
    rows: DesktopUnitsTab.exportRows(rows, usage),
  );

  Future<void> _exportSelected(
    List<Map<String, dynamic>> rows,
    Map<String, int> usage,
  ) async {
    final picked = [
      for (var i = 0; i < rows.length; i++)
        if (_selected.contains(i)) rows[i],
    ];
    await TableHtmlExport.export(
      context,
      filePrefix: 'units',
      title: DesktopUnitsTab.exportTitle(),
      headers: DesktopUnitsTab.exportHeaders(),
      rows: DesktopUnitsTab.exportRows(picked, usage),
    );
    if (mounted && picked.isNotEmpty) {
      setState(_selected.clear);
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
          // Desktop title lives in the shell topbar; only actions stay.
          Row(
            children: [
              const Spacer(),
              IconButton(
                tooltip: AppText.t('تصدير جدول', 'Export table'),
                visualDensity: VisualDensity.compact,
                onPressed: state.rows.isEmpty
                    ? null
                    : () => _exportAll(state.rows, state.usage),
                icon: Icon(Icons.table_view_outlined, size: 18.r),
              ),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_selected.isNotEmpty) ...[
                    TableSelectionBar(
                      selectedCount: _selected.length,
                      onExportTable: () =>
                          _exportSelected(state.rows, state.usage),
                      onClear: () => setState(_selected.clear),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                  Expanded(
                    child: AppPaginatedTable(
                      height: null,
                      minTableWidth: 640,
                      columnFlex: const [0.8, 1.2, 0.9, 0.7, 0.8],
                      headers: [...DesktopUnitsTab.exportHeaders(), ''],
                      rows: [
                        for (final u in state.rows)
                          [
                            Text(
                              '${u['symbol'] ?? ''}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text('${u['name'] ?? '-'}'),
                            Text('${u['dimension'] ?? '-'}'),
                            Text(
                              '${state.usage['${u['symbol'] ?? ''}'] ?? 0}',
                              style: TextStyle(
                                color:
                                    (state.usage['${u['symbol'] ?? ''}'] ?? 0) >
                                        0
                                    ? AppColors.success
                                    : AppColors.textMuted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: AppStrings.edit,
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () => _openEditor(context, u),
                                  icon: Icon(Icons.edit_outlined, size: 18.r),
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
                    onLoadMore: () => context.read<UnitsCubit>().loadMore(),
                    onRetry: () => context.read<UnitsCubit>().loadMore(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
