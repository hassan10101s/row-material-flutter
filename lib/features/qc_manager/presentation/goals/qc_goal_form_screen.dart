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
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_goal.dart';
import '../cubit/qc_goals_cubit.dart';

/// Simplified goal form (plan §4): title + owner + due date + priority.
///
/// Hidden from UI (kept in DB): KPIs, approver fields, site, type.
/// Code is auto-generated Q-YYYY-NN and read-only.
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

/// Simplified priority: 3 buttons only.
const _simplePriorities = [QcPriority.low, QcPriority.medium, QcPriority.high];

String _priorityAr(String p) => switch (p) {
      QcPriority.low => 'عادي',
      QcPriority.high => 'عاجل',
      _ => 'مهم',
    };

String _statusAr(String s) =>
    s == QcGoalStatus.completed ? 'مكتمل' : 'مفتوح';

class _QcGoalFormScreenState extends State<QcGoalFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _ownerId;
  late final TextEditingController _ownerName;
  late String _priority;
  late String _status;
  String _dueDate = '';

  @override
  void initState() {
    super.initState();
    final g = widget.goal;
    _title = TextEditingController(text: g?.title ?? '');
    _description = TextEditingController(text: g?.description ?? '');
    _ownerId = TextEditingController(text: g?.ownerId ?? '');
    _ownerName = TextEditingController(text: g?.ownerName ?? '');
    final raw = g?.priority ?? QcPriority.medium;
    _priority = raw == QcPriority.critical ? QcPriority.high : raw;
    if (!_simplePriorities.contains(_priority)) {
      _priority = QcPriority.medium;
    }
    _status = g?.status ?? QcGoalStatus.active;
    if (_status != QcGoalStatus.completed) _status = QcGoalStatus.active;
    _dueDate = g?.dueDate ?? '';
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
    for (final c in [_title, _description, _ownerId, _ownerName]) {
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
                  _label(AppText.t('الرمز (تلقائي)', 'Code (auto)')),
                  TextFormField(
                    initialValue: suggestedCode,
                    readOnly: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('العنوان *', 'Title *')),
                  TextFormField(
                    controller: _title,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? AppText.t('العنوان مطلوب', 'A title is required')
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('الوصف (اختياري)', 'Description (optional)')),
                  TextField(
                    controller: _description,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // Priority: 3 buttons.
                  _label(AppText.t('الأولوية', 'Priority')),
                  Wrap(
                    spacing: AppSpacing.xs,
                    children: [
                      for (final p in _simplePriorities)
                        ChoiceChip(
                          label: Text(_priorityAr(p)),
                          selected: _priority == p,
                          onSelected: (_) => setState(() => _priority = p),
                        ),
                    ],
                  ),
                  if (editing) ...[
                    const SizedBox(height: AppSpacing.md),
                    _label(AppText.t('الحالة', 'Status')),
                    Wrap(
                      spacing: AppSpacing.xs,
                      children: [
                        for (final s in [
                          QcGoalStatus.active,
                          QcGoalStatus.completed,
                        ])
                          ChoiceChip(
                            label: Text(_statusAr(s)),
                            selected: _status == s,
                            onSelected: (_) => setState(() => _status = s),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('المسؤول', 'Owner')),
                  Autocomplete<MapEntry<String, String>>(
                    optionsBuilder: (textEditingValue) {
                      final query = textEditingValue.text.toLowerCase();
                      return ownerSuggestions.where(
                        (e) =>
                            query.isEmpty ||
                            e.value.toLowerCase().contains(query) ||
                            e.key.toLowerCase().contains(query),
                      );
                    },
                    displayStringForOption: (e) => e.value,
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
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: InputDecoration(
                          labelText: AppText.t('اسم المسؤول', 'Owner name'),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) {
                          _ownerName.text = v;
                          _ownerId.clear();
                        },
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('الموعد', 'Due date')),
                  _DateField(
                    label: AppText.t('الاستحقاق', 'Due'),
                    value: _dueDate,
                    onPicked: (d) => setState(() => _dueDate = d),
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  FilledButton(
                    onPressed: state.saving ? null : () => _save(suggestedCode),
                    child: state.saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            editing
                                ? AppText.t('حفظ', 'Save')
                                : AppText.t('إنشاء', 'Create'),
                          ),
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
    final goal = QcGoal(
      goalId: existing?.goalId,
      code: existing?.code.isNotEmpty == true ? existing!.code : code,
      title: _title.text.trim(),
      description: _description.text.trim(),
      goalType: existing?.goalType ?? QcGoalType.other,
      status: _status,
      priority: _priority,
      startDate: existing?.startDate.isNotEmpty == true
          ? existing!.startDate
          : now.substring(0, 10),
      dueDate: _dueDate,
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
          lastDate: DateTime(now.year + 10),
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
