import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_goal.dart';
import 'cubit/qc_goals_cubit.dart';
import 'qc_goal_form_screen.dart';
import 'qc_goal_detail_screen.dart';
import 'widgets/goal_pill.dart';

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
        listener: (context, state) => ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state.error!))),
        builder: (context, state) {
          if (state.loading && state.goals.isEmpty) {
            return const Center(child: CircularProgressIndicator());
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
                  : FilledButton.tonal(
                      onPressed: () => cubit.clearFilters(),
                      child: Text(AppText.t('مسح الفلاتر', 'Clear filters')),
                    ),
            );
          }
          return Column(
            children: [
              _SummaryStrip(summary: state.summary),
              _ActiveFilterBar(
                state: state,
                onEdit: () => _openFilters(context),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => cubit.refresh(),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: state.goals.length + 1,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, i) {
                      if (i == state.goals.length) {
                        return _LoadMoreRow(
                          hasMore: state.hasMore,
                          busy: state.loadingMore,
                          onLoadMore: () => cubit.loadMore(),
                        );
                      }
                      return _GoalTile(goal: state.goals[i]);
                    },
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
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) =>
          BlocProvider.value(value: cubit, child: const _GoalFilterSheet()),
    );
  }
}

/// Total / active / late / closed for the rows in scope.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final QcGoalSummary summary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('الإجمالي', 'Total'),
              value: '${summary.total}',
              icon: Icons.flag_outlined,
              color: AppColors.primary,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('نشط', 'Active'),
              value: '${summary.active}',
              icon: Icons.play_circle_outline,
              color: AppColors.info,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('متأخر', 'Late'),
              value: '${summary.overdue}',
              icon: Icons.schedule,
              color: AppColors.danger,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('مكتمل', 'Closed'),
              value: '${summary.completed}',
              icon: Icons.check_circle_outline,
              color: AppColors.success,
            ),
          ),
        ],
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
    final chips = <Widget>[
      for (final status in f.statuses.toList()..sort())
        InputChip(
          label: Text(GoalPill.statusLabel(status)),
          onDeleted: () => context.read<QcGoalsCubit>().toggleStatus(status),
        ),
      if (f.dept.isNotEmpty)
        InputChip(
          label: Text('${AppText.t('القسم', 'Dept')}: ${f.dept}'),
          onDeleted: () =>
              context.read<QcGoalsCubit>().applyFilters(f.copyWith(dept: '')),
        ),
      if (f.overdueOnly)
        InputChip(
          label: Text(AppText.t('متأخر فقط', 'Late only')),
          onDeleted: () => context.read<QcGoalsCubit>().applyFilters(
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
          TextButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.tune, size: 18),
            label: Text(AppText.t('فلاتر', 'Filters')),
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

/// The paging footer. Rather than a spinner forever, it says whether there is
/// more to load, so a short list does not pretend to be still working.
class _LoadMoreRow extends StatelessWidget {
  const _LoadMoreRow({
    required this.hasMore,
    required this.busy,
    required this.onLoadMore,
  });

  final bool hasMore;
  final bool busy;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (!hasMore) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          AppText.t('نهاية القائمة', 'End of list'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Center(
        child: OutlinedButton(
          onPressed: onLoadMore,
          child: Text(AppText.t('تحميل المزيد', 'Load more')),
        ),
      ),
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
  String _dueFrom = '';
  String _dueTo = '';

  @override
  void initState() {
    super.initState();
    final f = context.read<QcGoalsCubit>().state.filters;
    _dept.text = f.dept;
    _owner.text = f.ownerId;
    _dueFrom = f.dueFrom;
    _dueTo = f.dueTo;
  }

  @override
  void dispose() {
    _dept.dispose();
    _owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcGoalsCubit>();
    return BlocBuilder<QcGoalsCubit, QcGoalsState>(
      bloc: cubit,
      builder: (context, state) {
        final f = state.filters;
        return Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            top: AppSpacing.lg,
            bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppText.t('فلاتر الأهداف', 'Goal filters'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16.spMax,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(AppText.t('الحالة', 'Status')),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.xs,
                  children: [
                    for (final status in QcGoalStatus.all)
                      FilterChip(
                        label: Text(GoalPill.statusLabel(status)),
                        selected: f.statuses.contains(status),
                        onSelected: (_) => cubit.toggleStatus(status),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                TextField(
                  controller: _dept,
                  decoration: InputDecoration(
                    labelText: AppText.t('القسم', 'Department'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(dept: v.trim())),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _owner,
                  decoration: InputDecoration(
                    labelText: AppText.t('المالك (معرّف)', 'Owner id'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(ownerId: v.trim())),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: _DateField(
                        label: AppText.t('من تاريخ', 'Due from'),
                        value: _dueFrom,
                        onPicked: (d) => setState(() => _dueFrom = d),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: _DateField(
                        label: AppText.t('إلى تاريخ', 'Due to'),
                        value: _dueTo,
                        onPicked: (d) => setState(() => _dueTo = d),
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: f.overdueOnly,
                  title: Text(AppText.t('المتأخرة فقط', 'Late only')),
                  onChanged: (v) =>
                      cubit.applyFilters(f.copyWith(overdueOnly: v)),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => cubit.clearFilters(),
                      child: Text(AppText.t('مسح', 'Clear')),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    FilledButton(
                      onPressed: () {
                        cubit.applyFilters(
                          f.copyWith(dueFrom: _dueFrom, dueTo: _dueTo),
                        );
                        Navigator.of(context).pop();
                      },
                      child: Text(AppText.t('تطبيق', 'Apply')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onPicked,
  });

  final String label;
  final String value;
  final ValueChanged<String> onPicked;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: now,
          firstDate: DateTime(now.year - 5),
          lastDate: DateTime(now.year + 5),
        );
        if (picked != null) onPicked(picked.toIso8601String().substring(0, 10));
      },
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        child: Text(value.isEmpty ? '-' : value),
      ),
    );
  }
}
