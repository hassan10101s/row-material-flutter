import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_adaptive_list.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_dialogs.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_search_field.dart';
import '../../domain/routine_repository.dart';
import 'routine_history_screen.dart';
import 'routine_list_editor.dart';
import 'routine_lists_cubit.dart';
import 'routine_sheet_screen.dart';

/// Routine lists hub: every daily/monthly checklist with its progress in the
/// current period. Tapping a row opens this period's sheet (auto-created);
/// past sheets live under History. The search field takes the header's own
/// place: on a fixed desktop window the title burned space no data needed.
class RoutineListsScreen extends StatefulWidget {
  const RoutineListsScreen({super.key});

  @override
  State<RoutineListsScreen> createState() => _RoutineListsScreenState();
}

class _RoutineListsScreenState extends State<RoutineListsScreen> {
  String _query = '';

  List<RoutineList> _filtered(List<RoutineList> lists) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return lists;
    return [
      for (final l in lists)
        if (l.template.name.toLowerCase().contains(q) ||
            l.template.dept.toLowerCase().contains(q))
          l,
    ];
  }

  Future<void> _openSheet(BuildContext context, int templateId) async {
    final cubit = context.read<RoutineListsCubit>();
    final sheetId = await cubit.openTodaySheet(templateId);
    if (!context.mounted || sheetId == null) return;
    await RoutineSheetScreen.open(context, inspectionId: sheetId);
    if (context.mounted) cubit.refresh();
  }

  Future<void> _editList(BuildContext context, RoutineList list) async {
    final saved = await showRoutineListEditor(context, list.template);
    if (saved && context.mounted) context.read<RoutineListsCubit>().refresh();
  }

  Future<void> _addList(BuildContext context) async {
    final saved = await showRoutineListEditor(context);
    if (saved && context.mounted) context.read<RoutineListsCubit>().refresh();
  }

  Future<void> _deleteList(BuildContext context, RoutineList list) async {
    final confirmed = await showAppConfirm(
      context,
      danger: true,
      icon: Icons.delete_outline,
      title: AppText.t('حذف القائمة؟', 'Delete list?'),
      message: AppText.t(
        'سيتم حذف القائمة. السجلات السابقة تبقى في السجل.',
        'The list will be deleted. Past sheets stay in history.',
      ),
      confirmLabel: AppText.t('حذف', 'Delete'),
      cancelLabel: AppText.t('إلغاء', 'Cancel'),
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await context.read<RoutineListsCubit>().deleteList(
      list.template.templateId!,
    );
    if (ok && context.mounted) {
      AppFeedback.success(context, AppText.t('تم الحذف', 'Deleted.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<RoutineListsCubit, RoutineListsState>(
      listenWhen: (prev, curr) =>
          curr.error != null && curr.error != prev.error,
      listener: (context, state) {
        AppFeedback.error(context, state.error!);
        context.read<RoutineListsCubit>().clearError();
      },
      builder: (context, state) {
        final lists = _filtered(state.lists);
        const headers = ['القائمة', 'القسم', 'التكرار', 'الإنجاز', 'إجراءات'];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: DebouncedSearchField(
                    hint: AppText.t(
                      'بحث بالاسم أو القسم',
                      'Search name or dept...',
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                AppButton(
                  small: true,
                  style: AppButtonStyle.secondary,
                  label: AppText.t('السجل', 'History'),
                  icon: Icon(Icons.history, size: 18.r),
                  onPressed: () => RoutineHistoryScreen.open(context),
                ),
                const SizedBox(width: AppSpacing.sm),
                AppButton(
                  small: true,
                  label: AppText.t('قائمة جديدة', 'New list'),
                  icon: Icon(Icons.add, size: 18.r),
                  onPressed: () => _addList(context),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: AppAdaptiveDataView(
                headers: headers,
                columnFlex: const [5, 3, 2, 2, 1],
                loading: state.loading && state.lists.isEmpty,
                rows: [
                  for (final l in lists)
                    AppDataRow(
                      cells: [
                        Text(
                          l.template.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14.spMax,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textStrong,
                          ),
                        ),
                        Text(
                          l.template.dept.trim().isEmpty
                              ? '—'
                              : l.template.dept,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.spMax,
                            color: AppColors.textMuted,
                          ),
                        ),
                        Text(
                          l.isMonthly
                              ? AppText.t('شهرية', 'Monthly')
                              : AppText.t('يومية', 'Daily'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.spMax,
                            color: AppColors.textMuted,
                          ),
                        ),
                        Text(
                          '${l.doneCount}/${l.totalItems}',
                          style: TextStyle(
                            fontSize: 13.spMax,
                            fontWeight: FontWeight.w700,
                            color: l.isComplete
                                ? AppColors.success
                                : AppColors.textStrong,
                          ),
                        ),
                        _rowMenu(context, l),
                      ],
                    ),
                ],
                onRowTap: lists.isEmpty
                    ? null
                    : (i) => _openSheet(context, lists[i].template.templateId!),
                empty: AppEmptyState(
                  icon: Icons.checklist_outlined,
                  title: state.lists.isEmpty
                      ? AppText.t(
                          'لا توجد قوائم بعد — أنشئ أول قائمة يومية',
                          'No lists yet — create the first daily list',
                        )
                      : AppText.t(
                          'لا توجد قوائم مطابقة للبحث',
                          'No lists match the search',
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The single trailing control per row: edit / delete folded in one menu
  /// instead of a button row (the icon-only cell keeps the table compact).
  Widget _rowMenu(BuildContext context, RoutineList list) {
    return SizedBox(
      width: 34.r,
      child: PopupMenuButton<String>(
        tooltip: AppText.t('الإجراءات', 'Actions'),
        padding: EdgeInsets.zero,
        iconSize: 20.r,
        onSelected: (v) {
          if (v == 'edit') _editList(context, list);
          if (v == 'delete') _deleteList(context, list);
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'edit', child: Text(AppText.t('تعديل', 'Edit'))),
          PopupMenuItem(
            value: 'delete',
            child: Text(
              AppText.t('حذف', 'Delete'),
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
