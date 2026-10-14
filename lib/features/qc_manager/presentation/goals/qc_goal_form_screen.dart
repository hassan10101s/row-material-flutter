import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/auth/session_source.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../di/service_locator.dart';
import '../../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_autocomplete_overlay.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_date_field.dart';
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_goal.dart';
import '../cubit/qc_goals_cubit.dart';

/// Full goal form: title + description + type + owner + dept + site +
/// priority + status + start/due dates.
///
/// Replaces the old simplified easy-goal flow (title + owner + due only,
/// `critical` coerced to `high`, type/site hidden). Code stays auto
/// Q-YYYY-NN read-only; KPIs/assignments/evidence live on the detail screen.
class QcGoalFormScreen extends StatefulWidget {
  const QcGoalFormScreen({super.key, this.goal});

  /// Null to create, set to edit.
  final QcGoal? goal;

  static Future<void> open(BuildContext context, {QcGoal? goal}) {
    final cubit = context.read<QcGoalsCubit>();
    final wide = MediaQuery.of(context).size.width >= AppBreakpoints.medium;
    if (wide) {
      return showAppWindow(
        context,
        title: goal == null
            ? AppText.t('هدف جديد', 'New goal')
            : AppText.t('تعديل الهدف', 'Edit goal'),
        icon: Icons.flag_outlined,
        size: AppWindowSize.lg,
        child: BlocProvider.value(
          value: cubit,
          child: QcGoalFormScreen(goal: goal),
        ),
      );
    }
    return Navigator.of(context).push(
      appMaterialPageRoute<void>(
        builder: (_) => BlocProvider.value(
          value: cubit,
          child: QcGoalFormScreen(goal: goal),
        ),
      ),
    );
  }

  @override
  State<QcGoalFormScreen> createState() => _QcGoalFormScreenState();
}

const _priorities = [
  QcPriority.low,
  QcPriority.medium,
  QcPriority.high,
  QcPriority.critical,
];

String _priorityLabel(String p) => switch (p) {
  QcPriority.low => AppText.t('عادي', 'Low'),
  QcPriority.medium => AppText.t('مهم', 'Medium'),
  QcPriority.high => AppText.t('عاجل', 'High'),
  _ => AppText.t('حرج', 'Critical'),
};

String _statusLabel(String s) => switch (s) {
  QcGoalStatus.draft => AppText.t('مسودة', 'Draft'),
  QcGoalStatus.active => AppText.t('نشط', 'Active'),
  QcGoalStatus.onHold => AppText.t('موقوف', 'On hold'),
  QcGoalStatus.completed => AppText.t('مكتمل', 'Completed'),
  _ => s,
};

String _goalTypeLabel(String t) => t;

class _QcGoalFormScreenState extends State<QcGoalFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _ownerId;
  late final TextEditingController _ownerName;
  late final TextEditingController _dept;
  late final TextEditingController _site;
  late final TextEditingController _startDate;
  late final TextEditingController _dueDate;
  late String _priority;
  late String _status;
  late String _goalType;

  static const _editableStatuses = [
    QcGoalStatus.draft,
    QcGoalStatus.active,
    QcGoalStatus.onHold,
    QcGoalStatus.completed,
  ];

  @override
  void initState() {
    super.initState();
    final g = widget.goal;
    _title = TextEditingController(text: g?.title ?? '');
    _description = TextEditingController(text: g?.description ?? '');
    _ownerId = TextEditingController(text: g?.ownerId ?? '');
    _ownerName = TextEditingController(text: g?.ownerName ?? '');
    _dept = TextEditingController(text: g?.dept ?? '');
    _site = TextEditingController(text: g?.site ?? '');
    _startDate = TextEditingController(
      text: g?.startDate != null && g!.startDate.length >= 10
          ? g.startDate.substring(0, 10)
          : '',
    );
    _dueDate = TextEditingController(text: g?.dueDate ?? '');
    _priority = QcPriority.normalize(g?.priority);
    final rawStatus = QcGoalStatus.normalize(g?.status ?? QcGoalStatus.draft);
    _status = _editableStatuses.contains(rawStatus)
        ? rawStatus
        : QcGoalStatus.draft;
    _goalType = QcGoalType.normalize(g?.goalType);
    // Default owner to current session when creating.
    if (widget.goal == null &&
        getIt.isRegistered<SessionSource>() &&
        _ownerId.text.isEmpty) {
      final session = getIt<SessionSource>().session;
      if (session.uid.isNotEmpty) {
        _ownerId.text = session.uid;
        _ownerName.text = session.displayName;
      }
    }
  }

  static String _suggestedGoalCode(List<QcGoal> goals) {
    final year = DateTime.now().year;
    final pattern = RegExp(r'^Q-(\d{4})-(\d+)$', caseSensitive: false);
    var highestSequence = 0;
    for (final goal in goals) {
      final match = pattern.firstMatch(goal.code.trim());
      if (match == null || int.tryParse(match.group(1)!) != year) continue;
      final sequence = int.tryParse(match.group(2)!);
      if (sequence != null && sequence > highestSequence) {
        highestSequence = sequence;
      }
    }
    return 'Q-$year-${(highestSequence + 1).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    for (final c in [
      _title,
      _description,
      _ownerId,
      _ownerName,
      _dept,
      _site,
      _startDate,
      _dueDate,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.goal != null;
    return BlocConsumer<QcGoalsCubit, QcGoalsState>(
      listenWhen: (a, b) => a.saved != b.saved && b.saved,
      listener: (context, state) {
        Navigator.of(context).pop();
        context.read<QcGoalsCubit>().clearSaved();
      },
      builder: (context, state) {
        final suggestedCode =
            widget.goal?.code.isNotEmpty == true && widget.goal!.code.isNotEmpty
            ? widget.goal!.code
            : _suggestedGoalCode(state.goals);
        final ownerSuggestions = [...state.userSuggestions];
        if (getIt.isRegistered<SessionSource>()) {
          final session = getIt<SessionSource>().session;
          if (session.uid.isNotEmpty && session.displayName.isNotEmpty) {
            ownerSuggestions.removeWhere((e) => e.key == session.uid);
            ownerSuggestions.add(MapEntry(session.uid, session.displayName));
          }
        }
        ownerSuggestions.sort((a, b) => a.value.compareTo(b.value));
        return Scaffold(
          appBar: AppTopAppBar(
            title: editing
                ? AppText.t('تعديل الهدف', 'Edit goal')
                : AppText.t('هدف جديد', 'New goal'),
          ),
          body: AbsorbPointer(
            absorbing: state.saving,
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  // Code: auto, read-only.
                  AppField(
                    label: AppText.t('الرمز (تلقائي)', 'Code (auto)'),
                    initialValue: suggestedCode,
                    enabled: false,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppField(
                    label: AppText.t('العنوان *', 'Title *'),
                    controller: _title,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? AppText.t('العنوان مطلوب', 'A title is required')
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppField(
                    label: AppText.t(
                      'الوصف (اختياري)',
                      'Description (optional)',
                    ),
                    controller: _description,
                    maxLines: 3,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppDropdown<String>(
                    labelText: AppText.t('نوع الهدف', 'Goal type'),
                    value: _goalType,
                    items: [
                      for (final t in QcGoalType.all)
                        AppDropdownItem(value: t, label: _goalTypeLabel(t)),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _goalType = v);
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('الأولوية', 'Priority')),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final p in _priorities)
                        AppButton(
                          small: true,
                          style: _priority == p
                              ? AppButtonStyle.primary
                              : AppButtonStyle.secondary,
                          label: _priorityLabel(p),
                          onPressed: () => setState(() => _priority = p),
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('الحالة', 'Status')),
                  Wrap(
                    spacing: AppSpacing.xs,
                    runSpacing: AppSpacing.xs,
                    children: [
                      for (final s in _editableStatuses)
                        AppButton(
                          small: true,
                          style: _status == s
                              ? AppButtonStyle.primary
                              : AppButtonStyle.secondary,
                          label: _statusLabel(s),
                          onPressed: () => setState(() => _status = s),
                        ),
                    ],
                  ),
                  if (!editing)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Text(
                        AppText.t(
                          'المسودة والنشط والموقوف قابلة للتحرير لاحقاً؛ الإكمال من شاشة التفاصيل بمنجز مسمى.',
                          'Draft, active and on-hold stay editable; completion happens on the detail screen with a named finisher.',
                        ),
                        style: TextStyle(
                          fontSize: 12.spMax,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('المسؤول', 'Owner')),
                  // Inherits the design-system overlay (full field width,
                  // one look everywhere) instead of the framework default.
                  AppFullWidthAutocomplete<MapEntry<String, String>>(
                    initialValue: TextEditingValue(text: _ownerName.text),
                    displayStringForOption: (e) => e.value,
                    optionsBuilder: (textEditingValue) {
                      final query = textEditingValue.text.toLowerCase();
                      return ownerSuggestions.where(
                        (e) =>
                            query.isEmpty ||
                            e.value.toLowerCase().contains(query) ||
                            e.key.toLowerCase().contains(query),
                      );
                    },
                    onSelected: (e) {
                      _ownerId.text = e.key;
                      _ownerName.text = e.value;
                    },
                    fieldViewBuilder:
                        (context, controller, focusNode, onFieldSubmitted) {
                          if (controller.text != _ownerName.text) {
                            controller.value = TextEditingValue(
                              text: _ownerName.text,
                              selection: TextSelection.collapsed(
                                offset: _ownerName.text.length,
                              ),
                            );
                          }
                          return AppField(
                            label: AppText.t('اسم المسؤول', 'Owner name'),
                            controller: controller,
                            focusNode: focusNode,
                            onChanged: (v) {
                              _ownerName.text = v;
                              _ownerId.clear();
                            },
                          );
                        },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppField(
                    label: AppText.t('القسم', 'Department'),
                    controller: _dept,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppField(
                    label: AppText.t('الموقع', 'Site'),
                    controller: _site,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('التواريخ', 'Dates')),
                  Row(
                    children: [
                      Expanded(
                        child: AppDateField(
                          label: AppText.t('البداية', 'Start'),
                          controller: _startDate,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: AppDateField(
                          label: AppText.t('الاستحقاق', 'Due'),
                          controller: _dueDate,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  AppButton(
                    label: editing
                        ? AppText.t('حفظ', 'Save')
                        : AppText.t('إنشاء', 'Create'),
                    expanded: true,
                    loading: state.saving,
                    onPressed: () => _save(suggestedCode),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.spMax,
        fontWeight: FontWeight.w600,
        color: AppColors.textMuted,
      ),
    ),
  );

  void _save(String code) {
    if (!_formKey.currentState!.validate()) return;
    final cubit = context.read<QcGoalsCubit>();
    final existing = widget.goal;
    final now = nowIso();
    final start = _startDate.text.trim().isNotEmpty
        ? _startDate.text.trim()
        : (existing?.startDate.isNotEmpty == true
              ? existing!.startDate
              : now.substring(0, 10));
    final goal = QcGoal(
      goalId: existing?.goalId,
      code: existing?.code.isNotEmpty == true ? existing!.code : code,
      title: _title.text.trim(),
      description: _description.text.trim(),
      goalType: _goalType,
      dept: _dept.text.trim(),
      site: _site.text.trim(),
      status: _status,
      priority: _priority,
      startDate: start,
      dueDate: _dueDate.text.trim(),
      ownerId: _ownerId.text.trim(),
      ownerName: _ownerName.text.trim(),
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      createdBy: existing?.createdBy ?? '',
    );
    if (existing == null) {
      cubit.createGoal(goal);
    } else {
      cubit.saveGoal(goal);
    }
  }
}
