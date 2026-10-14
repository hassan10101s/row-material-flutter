import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../app/auth_gate.dart';
import '../../../../../core/auth/permissions.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_date_field.dart';
import '../../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_search_field.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_summary_card.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../widgets/register_exports.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_goal.dart';
import '../cubit/qc_goals_cubit.dart';
import 'qc_goal_form_screen.dart';
import 'qc_goal_detail_screen.dart';
import '../widgets/goal_pill.dart';

/// The goal register: every quality objective, filterable by who owns it and
/// whether it is late.
///
/// Read-only by design on this screen. Completing a goal needs `qc.approve`, so
/// the write paths live on the detail screen where the finisher is named, not
/// here where a row tap is one gesture away from closing a quarter's work.
class QcGoalsScreen extends StatelessWidget {
  const QcGoalsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcGoalsCubit>();
    return Scaffold(
      appBar: AppTopAppBar(
        title: AppText.t('أهداف الجودة', 'Quality goals'),
        actions: [
          IconButton(
            tooltip: AppText.t('تصدير جدول', 'Export table'),
            onPressed: () => RegisterExports.goals(context, cubit.state.goals),
            icon: const Icon(Icons.table_view_outlined),
          ),
          IconButton(
            tooltip: AppText.t('تحديث', 'Refresh'),
            onPressed: () => cubit.refresh(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: AppText.t('فلاتر', 'Filters'),
            onPressed: () => _openFilters(context),
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: AppText.t('هدف جديد', 'New goal'),
            onPressed: () => QcGoalFormScreen.open(context),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: BlocConsumer<QcGoalsCubit, QcGoalsState>(
        listenWhen: (a, b) => a.error != b.error && b.error != null,
        listener: (context, state) =>
            AppFeedback.error(context, state.error!),
        builder: (context, state) {
          if (state.loading && state.goals.isEmpty) {
            return const AppSkeletonList(rows: 5);
          }
          if (state.goals.isEmpty) {
            return AppEmptyState(
              icon: Icons.flag_outlined,
              title: AppText.t('لا توجد أهداف', 'No goals yet'),
              subtitle: state.filters.isEmpty
                  ? AppText.t(
                      'أنشئ أول هدف للجودة',
                      'Create the first quality objective',
                    )
                  : AppText.t(
                      'لا توجد أهداف تطابق هذه الفلاتر',
                      'No goals match these filters',
                    ),
              action: state.filters.isEmpty
                  ? null
                  : AppButton(
                      label: AppText.t('مسح الفلاتر', 'Clear filters'),
                      style: AppButtonStyle.secondary,
                      onPressed: () => cubit.clearFilters(),
                    ),
            );
          }
          return Column(
            children: [
              if (state.loading && state.goals.isNotEmpty)
                const AppRefreshBar(),
              _SummaryStrip(summary: state.summary),
              _ActiveFilterBar(
                state: state,
                onEdit: () => _openFilters(context),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  0,
                ),
                child: AppFilterBar(
                  searchHint: AppText.t('بحث في الأهداف', 'Search goals'),
                  initialSearch: state.filters.dept.isNotEmpty
                      ? state.filters.dept
                      : null,
                  onSearch: (v) => cubit.applyFilters(
                    state.filters.copyWith(dept: v.trim()),
                  ),
                  trailing: AppButton(
                    label: AppText.t('فلاتر', 'Filters'),
                    icon: const Icon(Icons.tune, size: 18),
                    style: AppButtonStyle.ghost,
                    small: true,
                    onPressed: () => _openFilters(context),
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => cubit.refresh(),
                  child: AppInfiniteList(
                    itemCount: state.goals.length,
                    hasMore: state.hasMore,
                    loadingMore: state.loadingMore,
                    onLoadMore: () => cubit.loadMore(),
                    itemBuilder: (context, i) =>
                        _GoalTile(goal: state.goals[i]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openFilters(BuildContext context) {
    final cubit = context.read<QcGoalsCubit>();
    showAppOverlay<void>(
      context,
      title: AppText.t('فلاتر الأهداف', 'Goal filters'),
      icon: Icons.filter_alt_outlined,
      size: AppWindowSize.sm,
      builder: (_, _) => BlocProvider.value(
        value: cubit,
        child: const _GoalFilterSheet(),
      ),
    );
  }
}

/// Total / active / late / closed for the rows in scope.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final QcGoalSummary summary;

  @override
  Widget build(BuildContext context) {
    final cards = [
      AppSummaryCard(
        label: AppText.t('الإجمالي', 'Total'),
        value: '${summary.total}',
        icon: Icons.flag_outlined,
        color: AppColors.primary,
      ),
      AppSummaryCard(
        label: AppText.t('نشط', 'Active'),
        value: '${summary.active}',
        icon: Icons.play_circle_outline,
        color: AppColors.info,
      ),
      AppSummaryCard(
        label: AppText.t('متأخر', 'Late'),
        value: '${summary.overdue}',
        icon: Icons.schedule,
        color: AppColors.danger,
      ),
      AppSummaryCard(
        label: AppText.t('مكتمل', 'Closed'),
        value: '${summary.completed}',
        icon: Icons.check_circle_outline,
        color: AppColors.success,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final twoCol = constraints.maxWidth < 600;
          if (!twoCol) {
            return Row(
              children: [
                for (final c in cards) Expanded(child: c),
              ],
            );
          }
          return Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final c in cards)
                SizedBox(
                  width: (constraints.maxWidth - AppSpacing.sm) / 2,
                  child: c,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// The filters currently narrowing the list, removable one at a time.
class _ActiveFilterBar extends StatelessWidget {
  const _ActiveFilterBar({required this.state, required this.onEdit});

  final QcGoalsState state;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final f = state.filters;
    Widget removable(String label, VoidCallback onRemove) => AppButton(
      small: true,
      style: AppButtonStyle.secondary,
      icon: const Icon(Icons.close, size: 14),
      label: label,
      onPressed: onRemove,
    );
    final chips = <Widget>[
      for (final status in f.statuses.toList()..sort())
        removable(
          GoalPill.statusLabel(status),
          () => context.read<QcGoalsCubit>().toggleStatus(status),
        ),
      if (f.dept.isNotEmpty)
        removable(
          '${AppText.t('القسم', 'Dept')}: ${f.dept}',
          () => context.read<QcGoalsCubit>().applyFilters(f.copyWith(dept: '')),
        ),
      if (f.overdueOnly)
        removable(
          AppText.t('متأخر فقط', 'Late only'),
          () => context.read<QcGoalsCubit>().applyFilters(
            f.copyWith(overdueOnly: false),
          ),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: chips.isEmpty
                ? Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      AppText.t('كل الأهداف', 'All goals'),
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                  )
                : Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: chips,
                  ),
          ),
          AppButton(
            label: AppText.t('فلاتر', 'Filters'),
            icon: const Icon(Icons.tune, size: 18),
            style: AppButtonStyle.ghost,
            small: true,
            onPressed: onEdit,
          ),
        ],
      ),
    );
  }
}

/// One goal as a card: code and status on top, the measures below.
class _GoalTile extends StatelessWidget {
  const _GoalTile({required this.goal});

  final QcGoal goal;

  static bool get canDelete {
    try {
      return getIt<AuthGate>().canWrite(Permission.qcWrite);
    } catch (_) {
      return true;
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف الهدف', 'Delete goal'),
      name: goal.title.isNotEmpty ? goal.title : goal.code,
    );
    if (!confirmed || !context.mounted) return;
    final cubit = context.read<QcGoalsCubit>();
    await cubit.deleteGoal(goal.goalId ?? 0);
    if (!context.mounted) return;
    final error = cubit.state.error;
    if (error != null && error.isNotEmpty) {
      AppFeedback.error(context, error);
      cubit.clearError();
    } else {
      AppFeedback.success(context, AppText.t('تم حذف الهدف', 'Goal deleted'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final owner = goal.ownerName.isNotEmpty ? goal.ownerName : goal.ownerId;
    return AppCard(
      onTap: () => QcGoalDetailScreen.open(context, goal.goalId ?? 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  goal.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.spMax,
                  ),
                ),
              ),
              GoalPill.status(goal.status),
              const SizedBox(width: AppSpacing.xs),
              GoalPill.priority(goal.priority),
              if (canDelete) ...[
                const SizedBox(width: AppSpacing.xs),
                PopupMenuButton<String>(
                  tooltip: AppText.t('خيارات', 'Options'),
                  iconSize: 20,
                  onSelected: (v) {
                    if (v == 'delete') _confirmDelete(context);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: AppColors.danger,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(AppText.t('حذف', 'Delete')),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            goal.code.isEmpty ? '-' : goal.code,
            style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            children: [
              _Meta(
                icon: Icons.person_outline,
                text: owner.isEmpty ? AppText.t('بلا مالك', 'No owner') : owner,
              ),
              _Meta(
                icon: Icons.event_outlined,
                text: goal.dueDate.isEmpty
                    ? AppText.t('بلا موعد', 'No due date')
                    : goal.dueDate.substring(0, 10),
                danger: goal.isOverdue,
              ),
              if (goal.dept.isNotEmpty)
                _Meta(icon: Icons.apartment_outlined, text: goal.dept),
              if (goal.targetValue != null)
                _Meta(
                  icon: Icons.track_changes,
                  text:
                      '${goal.currentValue ?? '-'} / ${goal.targetValue} ${goal.targetUnit}',
                ),
            ],
          ),
          if (goal.isOverdue) ...[
            const SizedBox(height: AppSpacing.sm),
            GoalPill.overdue(),
          ],
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text, this.danger = false});

  final IconData icon;
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.danger : AppColors.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14.r, color: color),
        const SizedBox(width: AppSpacing.xs),
        Text(
          text,
          style: TextStyle(fontSize: 12.spMax, color: color),
        ),
      ],
    );
  }
}

/// The filter drawer.
///
/// A `BlocBuilder` rather than a snapshot of the state handed in once: the
/// chips below have to show what a toggle actually did, and a captured state
/// object cannot follow its own emissions.
class _GoalFilterSheet extends StatefulWidget {
  const _GoalFilterSheet();

  @override
  State<_GoalFilterSheet> createState() => _GoalFilterSheetState();
}

class _GoalFilterSheetState extends State<_GoalFilterSheet> {
  final _dept = TextEditingController();
  final _owner = TextEditingController();
  final _dueFrom = TextEditingController();
  final _dueTo = TextEditingController();

  @override
  void initState() {
    super.initState();
    final f = context.read<QcGoalsCubit>().state.filters;
    _dept.text = f.dept;
    _owner.text = f.ownerId;
    _dueFrom.text = f.dueFrom;
    _dueTo.text = f.dueTo;
  }

  @override
  void dispose() {
    _dept.dispose();
    _owner.dispose();
    _dueFrom.dispose();
    _dueTo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcGoalsCubit>();
    return BlocBuilder<QcGoalsCubit, QcGoalsState>(
      bloc: cubit,
      builder: (context, state) {
        final f = state.filters;
        // Chrome (title, padding, scroll) comes from the overlay host.
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppText.t('الحالة', 'Status')),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    for (final status in QcGoalStatus.all)
                      AppButton(
                        small: true,
                        style: f.statuses.contains(status)
                            ? AppButtonStyle.primary
                            : AppButtonStyle.secondary,
                        label: GoalPill.statusLabel(status),
                        onPressed: () => cubit.toggleStatus(status),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                AppField(
                  label: AppText.t('القسم', 'Department'),
                  controller: _dept,
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(dept: v.trim())),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppField(
                  label: AppText.t('المالك (معرّف)', 'Owner id'),
                  controller: _owner,
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(ownerId: v.trim())),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: AppDateField(
                        label: AppText.t('من تاريخ', 'Due from'),
                        controller: _dueFrom,
                        onChanged: (d) => cubit.applyFilters(
                          cubit.state.filters.copyWith(dueFrom: d.trim()),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: AppDateField(
                        label: AppText.t('إلى تاريخ', 'Due to'),
                        controller: _dueTo,
                        onChanged: (d) => cubit.applyFilters(
                          cubit.state.filters.copyWith(dueTo: d.trim()),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  small: true,
                  style: f.overdueOnly
                      ? AppButtonStyle.primary
                      : AppButtonStyle.secondary,
                  icon: Icon(
                    f.overdueOnly
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    size: 16,
                  ),
                  label: AppText.t('المتأخرة فقط', 'Late only'),
                  onPressed: () => cubit.applyFilters(
                    f.copyWith(overdueOnly: !f.overdueOnly),
                  ),
                ),
                AppWindow.footer(
                  actions: [
                    AppButton(
                      label: AppText.t('مسح', 'Clear'),
                      style: AppButtonStyle.secondary,
                      onPressed: () => cubit.clearFilters(),
                    ),
                    AppButton(
                      label: AppText.t('تطبيق', 'Apply'),
                      onPressed: () {
                        cubit.applyFilters(
                          f.copyWith(
                            dueFrom: _dueFrom.text.trim(),
                            dueTo: _dueTo.text.trim(),
                          ),
                        );
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ),
              ],
            );
      },
    );
  }
}
