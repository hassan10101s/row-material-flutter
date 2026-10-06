import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/auth/session_source.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../di/service_locator.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/qc_goal.dart';
import '../domain/qc_enums.dart';
import 'cubit/qc_goal_detail_cubit.dart';
import 'widgets/goal_pill.dart';

/// One goal in full: who is carrying it, what the steps are, how it is
/// measured, what it is evidenced against, and who closed it.
///
/// The completion action lives here rather than on the list because closing a
/// goal requires naming a finisher and a date; a one-tap "close" on a row in a
/// scrolling list is how a quarter closes with nobody accountable.
class QcGoalDetailScreen extends StatelessWidget {
  const QcGoalDetailScreen({super.key, this.isModal = false});

  final bool isModal;

  static Future<void> open(BuildContext context, int goalId) {
    final isDesktop = MediaQuery.of(context).size.width >= 1024;
    Widget detail({required bool modal}) => BlocProvider(
      create: (_) => getIt<QcGoalDetailCubit>(param1: goalId)..load(),
      child: QcGoalDetailScreen(isModal: modal),
    );

    if (isDesktop) {
      return showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (_) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 900),
            child: detail(modal: true),
          ),
        ),
      );
    }
    return Navigator.of(
      context,
    ).push(appMaterialPageRoute<void>(builder: (_) => detail(modal: false)));
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<QcGoalDetailCubit, QcGoalDetailState>(
      listenWhen: (a, b) =>
          a.notice != b.notice && b.notice != null ||
          a.error != b.error && b.error != null,
      listener: (context, state) {
        final cubit = context.read<QcGoalDetailCubit>();
        final text = state.notice ?? state.error;
        if (text == null) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(text)));
        if (state.notice != null) cubit.clearNotice();
        if (state.error != null) cubit.clearError();
      },
      builder: (context, state) {
        final goal = state.goal;
        return Scaffold(
          appBar: AppTopAppBar(
            title: goal != null && goal.title.isNotEmpty
                ? goal.title
                : AppText.t('الهدف', 'Goal'),
            leading: isModal
                ? IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  )
                : null,
          ),
          body: state.loading && goal == null
              ? const Center(child: CircularProgressIndicator())
              : goal == null
              ? AppEmptyState(
                  icon: state.error != null
                      ? Icons.error_outline
                      : Icons.search_off,
                  title: state.error != null
                      ? state.error!
                      : AppText.t(
                          'الهدف غير موجود',
                          'This goal no longer exists',
                        ),
                  action: state.error != null
                      ? FilledButton.tonal(
                          onPressed: () =>
                              context.read<QcGoalDetailCubit>().load(),
                          child: Text(AppText.t('إعادة المحاولة', 'Retry')),
                        )
                      : null,
                )
              : Column(
                  children: [
                    _TabStrip(state: state),
                    const Divider(height: 1),
                    Expanded(child: _TabBody(state: state)),
                  ],
                ),
        );
      },
    );
  }
}

List<MapEntry<String, String>> _knownPeople(
  QcGoal goal,
  List<QcGoalAssignment> assignments,
) {
  final people = <String, String>{};

  void add(String id, String name) {
    final normalizedId = id.trim();
    final normalizedName = name.trim();
    if (normalizedId.isNotEmpty && normalizedName.isNotEmpty) {
      people[normalizedId] = normalizedName;
    }
  }

  if (getIt.isRegistered<SessionSource>()) {
    final session = getIt<SessionSource>().session;
    add(session.uid, session.displayName);
  }
  add(goal.ownerId, goal.ownerName);
  for (final assignment in assignments) {
    add(assignment.assigneeId, assignment.assigneeName);
  }
  return people.entries.toList()
    ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
}

String _dateLabel(String value) {
  if (value.trim().isEmpty) return '-';
  final parsed = DateTime.tryParse(value);
  if (parsed != null) return parsed.toIso8601String().substring(0, 10);
  return value.length >= 10 ? value.substring(0, 10) : value;
}

String _dateTimeLabel(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed != null) return parsed.toIso8601String().replaceFirst('T', ' ');
  return value.length >= 16 ? value.substring(0, 16) : value;
}

class _FinisherAutocomplete extends StatelessWidget {
  const _FinisherAutocomplete({
    required this.nameController,
    required this.idController,
    required this.people,
  });

  final TextEditingController nameController;
  final TextEditingController idController;
  final List<MapEntry<String, String>> people;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Autocomplete<MapEntry<String, String>>(
        initialValue: TextEditingValue(text: nameController.text),
        displayStringForOption: (person) => person.value,
        optionsBuilder: (value) {
          final query = value.text.trim().toLowerCase();
          return people.where(
            (person) =>
                query.isEmpty ||
                person.value.toLowerCase().contains(query) ||
                person.key.toLowerCase().contains(query),
          );
        },
        onSelected: (person) {
          nameController.text = person.value;
          idController.text = person.key;
        },
        fieldViewBuilder: (context, controller, focusNode, onSubmitted) =>
            TextField(
              controller: controller,
              focusNode: focusNode,
              decoration: InputDecoration(
                labelText: AppText.t('الاسم', 'Name'),
                helperText: AppText.t(
                  'اختر الاسم لربطه بالمعرّف الصحيح',
                  'Select a name to bind its matching ID',
                ),
              ),
              onChanged: (value) {
                nameController.text = value;
                idController.clear();
              },
              onSubmitted: (_) => onSubmitted(),
            ),
      ),
      const SizedBox(height: AppSpacing.xs),
      TextField(
        controller: idController,
        readOnly: true,
        decoration: InputDecoration(
          labelText: AppText.t('المعرّف', 'ID'),
          border: const OutlineInputBorder(),
        ),
      ),
    ],
  );
}

/// Tab bar wired to the cubit's tab, so the selection survives a reload.
class _TabStrip extends StatelessWidget {
  const _TabStrip({required this.state});

  final QcGoalDetailState state;

  static const _labels = <String, String>{
    'overview': 'نظرة عامة',
    'assignments': 'المسؤوليات',
    'actions': 'الخطوات',
    'kpis': 'المؤشرات',
    'links': 'الربط',
    'history': 'السجل',
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final tab in QcGoalTab.values)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: ChoiceChip(
                label: Text(AppText.t(_labels[tab.name]!, _english[tab.name]!)),
                selected: state.tab == tab,
                onSelected: (_) =>
                    context.read<QcGoalDetailCubit>().selectTab(tab),
              ),
            ),
        ],
      ),
    );
  }

  static const _english = <String, String>{
    'overview': 'Overview',
    'assignments': 'Assignments',
    'actions': 'Steps',
    'kpis': 'KPIs',
    'links': 'Links',
    'history': 'History',
  };
}

class _AutocompleteTextField extends StatelessWidget {
  const _AutocompleteTextField({
    required this.controller,
    required this.label,
    required this.options,
    this.maxLines = 1,
    this.required = false,
    this.onSelected,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final List<String> options;
  final int maxLines;
  final bool required;
  final ValueChanged<String>? onSelected;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => Autocomplete<String>(
    initialValue: TextEditingValue(text: controller.text),
    optionsBuilder: (value) {
      final query = value.text.trim().toLowerCase();
      return options.where(
        (option) => query.isEmpty || option.toLowerCase().contains(query),
      );
    },
    onSelected: (value) {
      controller.text = value;
      onSelected?.call(value);
    },
    fieldViewBuilder: (context, fieldController, focusNode, onSubmitted) {
      if (fieldController.text != controller.text) {
        fieldController.value = TextEditingValue(
          text: controller.text,
          selection: TextSelection.collapsed(offset: controller.text.length),
        );
      }
      return TextFormField(
        controller: fieldController,
        focusNode: focusNode,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label),
        validator: required
            ? (value) => value == null || value.trim().isEmpty
                  ? AppText.t('هذا الحقل مطلوب', 'This field is required')
                  : null
            : null,
        onChanged: (value) {
          controller.text = value;
          onChanged?.call(value);
        },
        onFieldSubmitted: (_) => onSubmitted(),
      );
    },
  );
}

class _TabBody extends StatelessWidget {
  const _TabBody({required this.state});

  final QcGoalDetailState state;

  @override
  Widget build(BuildContext context) {
    return switch (state.tab) {
      QcGoalTab.overview => _OverviewTab(state: state),
      QcGoalTab.assignments => _AssignmentsTab(state: state),
      QcGoalTab.actions => _ActionsTab(state: state),
      QcGoalTab.kpis => _KpisTab(state: state),
      QcGoalTab.links => _LinksTab(state: state),
      QcGoalTab.history => _HistoryTab(state: state),
    };
  }
}

/// The goal itself: its measures, its dates, and who closed it.
class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.state});

  final QcGoalDetailState state;

  @override
  Widget build(BuildContext context) {
    final goal = state.goal!;
    final bundle = state.bundle!;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Row(
          children: [
            GoalPill.status(goal.status),
            const SizedBox(width: AppSpacing.xs),
            GoalPill.priority(goal.priority),
            if (goal.isOverdue) ...[
              const SizedBox(width: AppSpacing.xs),
              GoalPill.overdue(),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: AppSummaryCard(
                label: AppText.t('مسؤوليات', 'Assignments'),
                value:
                    '${bundle.completedAssignments}/${bundle.totalAssignments}',
                icon: Icons.group_outlined,
                color: AppColors.info,
                hint: bundle.overdueAssignments > 0
                    ? '${bundle.overdueAssignments} late'
                    : null,
              ),
            ),
            Expanded(
              child: AppSummaryCard(
                label: AppText.t('خطوات', 'Steps'),
                value: '${bundle.doneActions}/${bundle.totalActions}',
                icon: Icons.checklist,
                color: AppColors.primary,
                hint: bundle.blockedActions > 0
                    ? '${bundle.blockedActions} blocked'
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Field(
                AppText.t('الرمز', 'Code'),
                goal.code.isEmpty ? '-' : goal.code,
              ),
              _Field(AppText.t('النوع', 'Type'), goal.goalType),
              _Field(
                AppText.t('المالك', 'Owner'),
                goal.ownerName.isNotEmpty ? goal.ownerName : goal.ownerId,
              ),
              _Field(AppText.t('البداية', 'Start'), _dateLabel(goal.startDate)),
              _Field(AppText.t('الاستحقاق', 'Due'), _dateLabel(goal.dueDate)),
              if (goal.targetValue != null)
                _Field(
                  AppText.t('المستهدف', 'Target'),
                  '${goal.targetValue} ${goal.targetUnit}',
                ),
              if (goal.baselineValue != null)
                _Field(
                  AppText.t('خط الأساس', 'Baseline'),
                  '${goal.baselineValue}',
                ),
              if (goal.currentValue != null)
                _Field(AppText.t('الحالي', 'Current'), '${goal.currentValue}'),
              if (goal.description.isNotEmpty) ...[
                const Divider(),
                Text(goal.description),
              ],
            ],
          ),
        ),
        if (goal.isCompleted || goal.hasFinisher) ...[
          const SizedBox(height: AppSpacing.md),
          // The accountability statement the whole feature exists for, shown
          // as its own card rather than another row in the field list.
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.verified_outlined, color: AppColors.success),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      AppText.t('مكتمل بواسطة', 'Completed by'),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.spMax,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                _Field(
                  AppText.t('الاسم', 'Name'),
                  goal.completedByName.isNotEmpty
                      ? goal.completedByName
                      : goal.completedBy,
                ),
                _Field(
                  AppText.t('التاريخ', 'When'),
                  _dateLabel(goal.completedAt),
                ),
                if (goal.completionNotes.isNotEmpty)
                  _Field(AppText.t('ملاحظات', 'Notes'), goal.completionNotes),
                if (goal.completionEvidence.isNotEmpty) ...[
                  const Divider(),
                  Text(
                    AppText.t('المرفقات', 'Evidence'),
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                  for (final item in goal.completionEvidence)
                    Text('- $item', style: TextStyle(fontSize: 12.spMax)),
                ],
              ],
            ),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.bundle != null &&
                    (!state.bundle!.allAssignmentsComplete ||
                        !state.bundle!.allActionsDone))
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      AppText.t(
                        'أكمل أو ألغِ جميع المسؤوليات والخطوات قبل إغلاق الهدف.',
                        'Complete or cancel all assignments and steps before closing this goal.',
                      ),
                      style: TextStyle(
                        color: AppColors.warning,
                        fontSize: 12.spMax,
                      ),
                    ),
                  ),
                FilledButton.icon(
                  onPressed: () => _completeDialog(context, goal),
                  icon: const Icon(Icons.task_alt),
                  label: Text(AppText.t('إكمال الهدف', 'Complete goal')),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _completeDialog(BuildContext context, QcGoal goal) async {
    final bundle = state.bundle;
    if (bundle == null) return;
    if (!bundle.allAssignmentsComplete || !bundle.allActionsDone) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppText.t(
              'أكمل أو ألغِ جميع المسؤوليات والخطوات أولاً',
              'Complete or cancel all assignments and steps first',
            ),
          ),
        ),
      );
      return;
    }
    final cubit = context.read<QcGoalDetailCubit>();
    final notes = TextEditingController();
    final who = TextEditingController();
    final name = TextEditingController();
    final evidenceController = TextEditingController();
    final evidenceList = <String>[];
    final result = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(AppText.t('إكمال الهدف', 'Complete goal')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppText.t(
                    'التسجيل يتطلب اسم من أنهى الهدف.',
                    'A finisher must be named before the goal can close.',
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: AppSpacing.sm),
                _FinisherAutocomplete(
                  nameController: name,
                  idController: who,
                  people: _knownPeople(goal, state.assignments),
                ),
                const SizedBox(height: AppSpacing.xs),
                _AutocompleteTextField(
                  controller: notes,
                  label: AppText.t('ملاحظات', 'Notes'),
                  options: state.goal?.completionNotes.isNotEmpty == true
                      ? [state.goal!.completionNotes]
                      : const [],
                  maxLines: 2,
                ),
                if (goal.needsEvidence) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    AppText.t(
                      'الأدلة مطلوبة لهذا الهدف الحرج',
                      'Evidence required for critical goal',
                    ),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Expanded(
                        child: _AutocompleteTextField(
                          controller: evidenceController,
                          label: AppText.t(
                            'رابط/وصف الدليل',
                            'Evidence URL/description',
                          ),
                          options: goal.completionEvidence,
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          final v = evidenceController.text.trim();
                          if (v.isNotEmpty) {
                            setState(() {
                              evidenceList.add(v);
                              evidenceController.clear();
                            });
                          }
                        },
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  if (evidenceList.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: evidenceList
                            .map(
                              (e) => Text(
                                '- $e',
                                style: const TextStyle(fontSize: 11),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(AppText.t('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(AppText.t('تأكيد', 'Confirm')),
            ),
          ],
        ),
      ),
    );
    final finisherId = who.text.trim();
    final finisherName = name.text.trim();
    final completionNotes = notes.text.trim();
    final evidence = List<String>.of(evidenceList);
    if (result != true) return;
    if (!context.mounted) return;
    if (finisherId.isEmpty || finisherName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppText.t(
              'لا يمكن الإكمال بدون مسؤول',
              'Cannot complete without a finisher',
            ),
          ),
        ),
      );
      return;
    }

    await cubit.completeGoal(
      completedBy: finisherId,
      completedByName: finisherName,
      notes: completionNotes,
      evidence: evidence,
    );
  }
}

/// One row per person carrying the goal, with their share's own finisher.
class _AssignmentsTab extends StatelessWidget {
  const _AssignmentsTab({required this.state});

  final QcGoalDetailState state;

  @override
  Widget build(BuildContext context) {
    if (state.assignments.isEmpty) {
      return AppEmptyState(
        icon: Icons.person_add_alt_outlined,
        title: AppText.t('لا يوجد مسؤوليات', 'Nobody is assigned'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: state.assignments.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) {
        final a = state.assignments[i];
        return AppCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a.assigneeLabel,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14.spMax,
                      ),
                    ),
                    Text(
                      [
                        a.role,
                        if (a.dueDate.isNotEmpty) _dateLabel(a.dueDate),
                      ].join(' - '),
                      style: TextStyle(
                        fontSize: 12.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                    if (a.hasFinisher)
                      Text(
                        '${AppText.t('أنجزها', 'Done by')}: ${a.completedByLabel}',
                        style: TextStyle(
                          fontSize: 12.spMax,
                          color: AppColors.success,
                        ),
                      ),
                  ],
                ),
              ),
              GoalPill.assignmentStatus(a.status),
              if (a.isOverdue) ...[
                const SizedBox(width: AppSpacing.xs),
                GoalPill.overdue(),
              ],
              if (a.isOpenState)
                IconButton(
                  icon: const Icon(Icons.task_alt, size: 18),
                  tooltip: AppText.t('إنجاز', 'Complete'),
                  onPressed: () =>
                      _completeAssignmentDialog(context, a.assignId!),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _completeAssignmentDialog(
    BuildContext context,
    int assignId,
  ) async {
    final cubit = context.read<QcGoalDetailCubit>();
    final who = TextEditingController();
    final name = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(AppText.t('إنجاز المسؤولية', 'Complete assignment')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FinisherAutocomplete(
              nameController: name,
              idController: who,
              people: _knownPeople(state.goal!, state.assignments),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(AppText.t('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(AppText.t('تأكيد', 'Confirm')),
          ),
        ],
      ),
    );
    final w = who.text.trim();
    final n = name.text.trim();
    if (result != true) return;
    if (!context.mounted) return;
    if (w.isEmpty || n.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppText.t(
              'اختر شخصاً من الاقتراحات',
              'Select a person from the suggestions',
            ),
          ),
        ),
      );
      return;
    }
    await cubit.completeAssignment(assignId, w, n);
  }
}

/// The steps, each with its own finisher and its own blocked reason.
class _ActionsTab extends StatelessWidget {
  const _ActionsTab({required this.state});

  final QcGoalDetailState state;

  @override
  Widget build(BuildContext context) {
    if (state.actions.isEmpty) {
      return AppEmptyState(
        icon: Icons.checklist,
        title: AppText.t('لا توجد خطوات', 'No steps yet'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: state.actions.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) {
        final action = state.actions[i];
        return AppCard(
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      action.actionText,
                      style: TextStyle(fontSize: 13.spMax),
                    ),
                    if (action.dueDate.isNotEmpty)
                      Text(
                        _dateLabel(action.dueDate),
                        style: TextStyle(
                          fontSize: 11.spMax,
                          color: action.isOverdue
                              ? AppColors.danger
                              : AppColors.textMuted,
                        ),
                      ),
                    if (action.isBlocked && action.blockedReason.isNotEmpty)
                      Text(
                        action.blockedReason,
                        style: TextStyle(
                          fontSize: 11.spMax,
                          color: AppColors.danger,
                        ),
                      ),
                    if (action.isDone && action.doneAt.isNotEmpty)
                      Text(
                        '${AppText.t('أنجزها', 'Done by')}: '
                        '${action.doneByLabel}',
                        style: TextStyle(
                          fontSize: 11.spMax,
                          color: AppColors.success,
                        ),
                      ),
                  ],
                ),
              ),
              GoalPill.actionStatus(action.status),
              if (!action.isDone &&
                  action.status != QcGoalActionStatus.cancelled)
                IconButton(
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  tooltip: AppText.t('إنجاز', 'Complete'),
                  onPressed: () =>
                      _completeActionDialog(context, action.actionId!),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _completeActionDialog(BuildContext context, int actionId) async {
    final cubit = context.read<QcGoalDetailCubit>();
    final who = TextEditingController();
    final name = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(AppText.t('إنجاز الخطوة', 'Complete step')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FinisherAutocomplete(
              nameController: name,
              idController: who,
              people: _knownPeople(state.goal!, state.assignments),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(AppText.t('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(AppText.t('تأكيد', 'Confirm')),
          ),
        ],
      ),
    );
    final w = who.text.trim();
    final n = name.text.trim();
    if (result != true) return;
    if (!context.mounted) return;
    if (w.isEmpty || n.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            AppText.t(
              'اختر شخصاً من الاقتراحات',
              'Select a person from the suggestions',
            ),
          ),
        ),
      );
      return;
    }
    await cubit.completeAction(actionId, w, n);
  }
}

/// Target against actual, per measured KPI.
class _KpisTab extends StatelessWidget {
  const _KpisTab({required this.state});

  final QcGoalDetailState state;

  Future<void> _recordKpi(BuildContext context) async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController();
    final target = TextEditingController();
    final actual = TextEditingController();
    final unit = TextEditingController();
    final measuredById = TextEditingController();
    final measuredByName = TextEditingController();
    final notes = TextEditingController();
    var higherIsBetter = true;
    var measureDate = DateTime.now().toIso8601String().substring(0, 10);
    var selectedExistingName = '';

    final result = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(AppText.t('إضافة/تسجيل مؤشر', 'Add or record KPI')),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _AutocompleteTextField(
                    controller: name,
                    label: AppText.t('اسم المؤشر', 'KPI name'),
                    options: state.kpis.map((kpi) => kpi.name).toSet().toList(),
                    required: true,
                    onSelected: (value) {
                      final existing = state.kpis
                          .where((kpi) => kpi.name == value)
                          .firstOrNull;
                      if (existing == null) return;
                      selectedExistingName = existing.name;
                      target.text = '${existing.target}';
                      actual.text = existing.actual == null
                          ? ''
                          : '${existing.actual}';
                      unit.text = existing.unit;
                      measuredById.text = existing.measuredBy;
                      measuredByName.text = existing.measuredByName;
                      notes.text = existing.notes;
                      setState(() {
                        higherIsBetter = existing.higherIsBetter;
                        if (existing.measureDate.isNotEmpty) {
                          measureDate = existing.measureDate;
                        }
                      });
                    },
                    onChanged: (value) {
                      if (selectedExistingName.isEmpty ||
                          value == selectedExistingName) {
                        return;
                      }
                      selectedExistingName = '';
                      target.clear();
                      actual.clear();
                      unit.clear();
                      measuredById.clear();
                      measuredByName.clear();
                      notes.clear();
                      setState(() {
                        higherIsBetter = true;
                        measureDate = DateTime.now()
                            .toIso8601String()
                            .substring(0, 10);
                      });
                    },
                  ),
                  TextFormField(
                    controller: target,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: AppText.t('المستهدف', 'Target'),
                    ),
                    validator: (value) {
                      final parsed = double.tryParse(value?.trim() ?? '');
                      return parsed == null || !parsed.isFinite
                          ? AppText.t(
                              'أدخل قيمة رقمية صحيحة',
                              'Enter a valid number',
                            )
                          : null;
                    },
                  ),
                  TextFormField(
                    controller: actual,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: AppText.t(
                        'القيمة الحالية (اختياري)',
                        'Actual (optional)',
                      ),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) return null;
                      final parsed = double.tryParse(value.trim());
                      return parsed == null || !parsed.isFinite
                          ? AppText.t(
                              'أدخل قيمة رقمية صحيحة',
                              'Enter a valid number',
                            )
                          : null;
                    },
                  ),
                  _AutocompleteTextField(
                    controller: unit,
                    label: AppText.t('الوحدة', 'Unit'),
                    options: state.kpis
                        .map((kpi) => kpi.unit)
                        .where((value) => value.isNotEmpty)
                        .toSet()
                        .toList(),
                  ),
                  _FinisherAutocomplete(
                    nameController: measuredByName,
                    idController: measuredById,
                    people: _knownPeople(state.goal!, state.assignments),
                  ),
                  _AutocompleteTextField(
                    controller: notes,
                    label: AppText.t('ملاحظات', 'Notes'),
                    options: state.kpis
                        .map((kpi) => kpi.notes)
                        .where((value) => value.isNotEmpty)
                        .toSet()
                        .toList(),
                    maxLines: 2,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(AppText.t('الأعلى أفضل', 'Higher is better')),
                    value: higherIsBetter,
                    onChanged: (value) =>
                        setState(() => higherIsBetter = value),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: dialog,
                          initialDate:
                              DateTime.tryParse(measureDate) ?? DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(DateTime.now().year + 10),
                        );
                        if (picked != null) {
                          setState(() {
                            measureDate = picked.toIso8601String().substring(
                              0,
                              10,
                            );
                          });
                        }
                      },
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text(
                        '${AppText.t('تاريخ القياس', 'Measure date')}: $measureDate',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(AppText.t('إلغاء', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                final isExistingName = state.kpis.any(
                  (kpi) => kpi.name == name.text.trim(),
                );
                if (formKey.currentState!.validate() &&
                    name.text.trim().isNotEmpty &&
                    (!isExistingName ||
                        selectedExistingName == name.text.trim()) &&
                    measuredById.text.trim().isNotEmpty) {
                  Navigator.of(dialog).pop(true);
                } else if (isExistingName &&
                    selectedExistingName != name.text.trim()) {
                  ScaffoldMessenger.of(dialog).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppText.t(
                          'اختر المؤشر الموجود من الاقتراحات لتحديثه بأمان',
                          'Select the existing KPI suggestion to update it safely',
                        ),
                      ),
                    ),
                  );
                } else if (measuredById.text.trim().isEmpty) {
                  ScaffoldMessenger.of(dialog).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppText.t(
                          'اختر مسؤول القياس من الاقتراحات',
                          'Select the measurement owner from suggestions',
                        ),
                      ),
                    ),
                  );
                }
              },
              child: Text(AppText.t('حفظ', 'Save')),
            ),
          ],
        ),
      ),
    );

    if (result == true && context.mounted) {
      await context.read<QcGoalDetailCubit>().saveKpi(
        name: name.text.trim(),
        target: double.parse(target.text.trim()),
        actual: actual.text.trim().isEmpty
            ? null
            : double.parse(actual.text.trim()),
        unit: unit.text.trim(),
        measureDate: measureDate,
        measuredBy: measuredById.text.trim(),
        measuredByName: measuredByName.text.trim(),
        notes: notes.text.trim(),
        higherIsBetter: higherIsBetter,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (state.kpis.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppEmptyState(
              icon: Icons.track_changes,
              title: AppText.t('لا توجد مؤشرات', 'No KPIs recorded'),
            ),
            FilledButton.icon(
              onPressed: state.saving ? null : () => _recordKpi(context),
              icon: const Icon(Icons.add),
              label: Text(AppText.t('إضافة مؤشر', 'Add KPI')),
            ),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonalIcon(
            onPressed: state.saving ? null : () => _recordKpi(context),
            icon: const Icon(Icons.add),
            label: Text(AppText.t('إضافة مؤشر', 'Add KPI')),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final kpi in state.kpis) ...[
          AppCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kpi.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13.spMax,
                        ),
                      ),
                      Text(
                        '${AppText.t('المستهدف', 'Target')}: '
                        '${kpi.target} ${kpi.unit} · '
                        '${kpi.higherIsBetter ? AppText.t('الأعلى أفضل', 'higher is better') : AppText.t('الأقل أفضل', 'lower is better')}',
                        style: TextStyle(
                          fontSize: 11.spMax,
                          color: AppColors.textMuted,
                        ),
                      ),
                      if (kpi.measuredByLabel.isNotEmpty)
                        Text(
                          kpi.measuredByLabel,
                          style: TextStyle(
                            fontSize: 11.spMax,
                            color: AppColors.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      kpi.isMeasured ? '${kpi.actual} ${kpi.unit}' : '-',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15.spMax,
                        color: kpi.isMeasured
                            ? (kpi.isMet ? AppColors.success : AppColors.danger)
                            : AppColors.textMuted,
                      ),
                    ),
                    if (kpi.variance != null)
                      Text(
                        '${kpi.variance! > 0 ? '+' : ''}${kpi.variance}',
                        style: TextStyle(
                          fontSize: 11.spMax,
                          color: kpi.isMet
                              ? AppColors.success
                              : AppColors.danger,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

/// What the goal is evidenced against: the SOP, finding or CAPA it serves.
class _LinksTab extends StatelessWidget {
  const _LinksTab({required this.state});

  final QcGoalDetailState state;

  @override
  Widget build(BuildContext context) {
    if (state.links.isEmpty) {
      return AppEmptyState(
        icon: Icons.link,
        title: AppText.t('لا يوجد ربط', 'Nothing linked yet'),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount: state.links.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) {
        final link = state.links[i];
        return AppCard(
          child: Row(
            children: [
              Icon(Icons.link, color: AppColors.primary, size: 18.r),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${link.linkType} #${link.refId}',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13.spMax,
                      ),
                    ),
                    if (link.notes.isNotEmpty)
                      Text(
                        link.notes,
                        style: TextStyle(
                          fontSize: 11.spMax,
                          color: AppColors.textMuted,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                link.targetTable,
                style: TextStyle(
                  fontSize: 10.spMax,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The goal's slice of the append-only trail.
class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.state});

  final QcGoalDetailState state;

  @override
  Widget build(BuildContext context) {
    if (state.history.isEmpty) {
      if (state.historyError != null) {
        return AppEmptyState(
          icon: Icons.error_outline,
          title: AppText.t(
            'تعذر تحميل سجل الهدف',
            'Could not load goal history',
          ),
          subtitle: state.historyError,
          action: FilledButton.tonal(
            onPressed: () => context.read<QcGoalDetailCubit>().reloadHistory(),
            child: Text(AppText.t('إعادة المحاولة', 'Retry')),
          ),
        );
      }
      return AppEmptyState(
        icon: Icons.history,
        title: AppText.t('لا يوجد سجل', 'No history yet'),
      );
    }
    final hasLimitNotice = state.history.length == 200;
    final errorNoticeCount = state.historyError == null ? 0 : 1;
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.md),
      itemCount:
          state.history.length + errorNoticeCount + (hasLimitNotice ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == 0 && errorNoticeCount == 1) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    AppText.t(
                      'تعذر تحديث سجل التدقيق',
                      'Could not refresh audit history',
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      context.read<QcGoalDetailCubit>().reloadHistory(),
                  child: Text(AppText.t('إعادة المحاولة', 'Retry')),
                ),
              ],
            ),
          );
        }
        if (hasLimitNotice && i == errorNoticeCount) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: Text(
              AppText.t(
                'يُعرض أحدث 200 سجل فقط؛ السجلات الأقدم غير محمّلة هنا.',
                'Showing the latest 200 entries; older history is not loaded here.',
              ),
              style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
            ),
          );
        }
        final entryIndex = i - errorNoticeCount - (hasLimitNotice ? 1 : 0);
        final entry = state.history[entryIndex];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.circle, size: 8, color: AppColors.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.action,
                      style: TextStyle(
                        fontSize: 13.spMax,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      [
                        if (entry.byUserName.isNotEmpty) entry.byUserName,
                        if (entry.at.isNotEmpty) _dateTimeLabel(entry.at),
                      ].join(' - '),
                      style: TextStyle(
                        fontSize: 11.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(value, style: TextStyle(fontSize: 13.spMax)),
          ),
        ],
      ),
    );
  }
}
