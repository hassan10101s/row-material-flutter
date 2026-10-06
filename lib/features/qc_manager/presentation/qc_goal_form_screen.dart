import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/auth/session_source.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../di/service_locator.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_goal.dart';
import 'cubit/qc_goals_cubit.dart';
import 'widgets/goal_pill.dart';

/// Create or edit a quality goal.
///
/// Edits go through [QcGoalsCubit] rather than a cubit of their own: the list
/// underneath is the thing that has to reload afterwards, and a second cubit
/// would mean the same save logic in two places.
class QcGoalFormScreen extends StatefulWidget {
  const QcGoalFormScreen({super.key, this.goal});

  /// Null to create, set to edit.
  final QcGoal? goal;

  static Future<void> open(BuildContext context, {QcGoal? goal}) {
    final cubit = context.read<QcGoalsCubit>();
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

class _QcGoalFormScreenState extends State<QcGoalFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _dept;
  late final TextEditingController _site;
  late final TextEditingController _ownerId;
  late final TextEditingController _ownerName;
  late final TextEditingController _targetValue;
  late final TextEditingController _targetUnit;
  late final TextEditingController _baseline;
  late final TextEditingController _current;
  late String _goalType;
  late String _priority;
  late String _status;
  String _startDate = '';
  String _dueDate = '';

  @override
  void initState() {
    super.initState();
    final g = widget.goal;
    _code = TextEditingController(text: g?.code ?? '');
    _title = TextEditingController(text: g?.title ?? '');
    _description = TextEditingController(text: g?.description ?? '');
    _dept = TextEditingController(text: g?.dept ?? '');
    _site = TextEditingController(text: g?.site ?? '');
    _ownerId = TextEditingController(text: g?.ownerId ?? '');
    _ownerName = TextEditingController(text: g?.ownerName ?? '');
    _targetValue = TextEditingController(text: _num(g?.targetValue));
    _targetUnit = TextEditingController(text: g?.targetUnit ?? '');
    _baseline = TextEditingController(text: _num(g?.baselineValue));
    _current = TextEditingController(text: _num(g?.currentValue));
    _goalType = g?.goalType ?? QcGoalType.kpi;
    _priority = g?.priority ?? QcPriority.medium;
    _status = g?.status ?? QcGoalStatus.draft;
    _startDate = g?.startDate ?? '';
    _dueDate = g?.dueDate ?? '';
  }

  static String _num(double? v) => v == null ? '' : '$v';

  static String? _validateCode(String? value) =>
      value == null || value.trim().isEmpty
      ? AppText.t('الرمز مطلوب', 'A code is required')
      : null;

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
      _code,
      _title,
      _description,
      _dept,
      _site,
      _ownerId,
      _ownerName,
      _targetValue,
      _targetUnit,
      _baseline,
      _current,
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
        final ownerSuggestions = [...state.userSuggestions];
        if (getIt.isRegistered<SessionSource>()) {
          final session = getIt<SessionSource>().session;
          if (session.uid.isNotEmpty && session.displayName.isNotEmpty) {
            ownerSuggestions.removeWhere((e) => e.key == session.uid);
            ownerSuggestions.add(MapEntry(session.uid, session.displayName));
          }
        }
        ownerSuggestions.sort((a, b) => a.value.compareTo(b.value));
        final suggestedCode = _suggestedGoalCode(state.goals);
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
                  _label(AppText.t('الرمز', 'Code')),
                  if (editing)
                    TextFormField(
                      controller: _code,
                      decoration: const InputDecoration(
                        hintText: 'Q-2026-01',
                        border: OutlineInputBorder(),
                      ),
                      readOnly: true,
                      validator: _validateCode,
                    )
                  else
                    Autocomplete<String>(
                      optionsBuilder: (value) {
                        final query = value.text.toLowerCase();
                        return suggestedCode.toLowerCase().contains(query)
                            ? [suggestedCode]
                            : const <String>[];
                      },
                      onSelected: (value) => _code.text = value,
                      fieldViewBuilder:
                          (context, controller, focusNode, onSubmitted) {
                            if (controller.text != _code.text) {
                              controller.value = TextEditingValue(
                                text: _code.text,
                                selection: TextSelection.collapsed(
                                  offset: _code.text.length,
                                ),
                              );
                            }
                            return TextFormField(
                              controller: controller,
                              focusNode: focusNode,
                              decoration: InputDecoration(
                                hintText: suggestedCode,
                                border: const OutlineInputBorder(),
                              ),
                              validator: _validateCode,
                              onChanged: (value) => _code.text = value,
                              onFieldSubmitted: (_) => onSubmitted(),
                            );
                          },
                    ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('العنوان', 'Title')),
                  Autocomplete<String>(
                    optionsBuilder: (textEditingValue) {
                      final query = textEditingValue.text.toLowerCase();
                      return state.titleSuggestions.where(
                        (t) => query.isEmpty || t.toLowerCase().contains(query),
                      );
                    },
                    onSelected: (v) => _title.text = v,
                    fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                      if (controller.text != _title.text) {
                        controller.value = TextEditingValue(
                          text: _title.text,
                          selection: TextSelection.collapsed(
                            offset: _title.text.length,
                          ),
                        );
                      }
                      return TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? AppText.t('العنوان مطلوب', 'A title is required')
                            : null,
                        onChanged: (v) => _title.text = v,
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('الوصف', 'Description')),
                  Autocomplete<String>(
                    optionsBuilder: (textEditingValue) {
                      final query = textEditingValue.text.toLowerCase();
                      return state.goals
                          .map((goal) => goal.description)
                          .where((value) => value.trim().isNotEmpty)
                          .toSet()
                          .where(
                            (value) =>
                                query.isEmpty ||
                                value.toLowerCase().contains(query),
                          );
                    },
                    onSelected: (value) => _description.text = value,
                    fieldViewBuilder:
                        (context, controller, focusNode, onFieldSubmitted) {
                          if (controller.text != _description.text) {
                            controller.value = TextEditingValue(
                              text: _description.text,
                              selection: TextSelection.collapsed(
                                offset: _description.text.length,
                              ),
                            );
                          }
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (value) => _description.text = value,
                          );
                        },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('النوع', 'Type')),
                  _ChoiceRow(
                    values: QcGoalType.all,
                    selected: _goalType,
                    labelOf: (v) => v,
                    onChanged: (v) => setState(() => _goalType = v),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('الأولوية', 'Priority')),
                  _ChoiceRow(
                    values: QcPriority.all,
                    selected: _priority,
                    labelOf: GoalPill.priorityLabel,
                    onChanged: (v) => setState(() => _priority = v),
                  ),
                  if (editing) ...[
                    const SizedBox(height: AppSpacing.md),
                    _label(AppText.t('الحالة', 'Status')),
                    _ChoiceRow(
                      values: QcGoalStatus.all,
                      selected: _status,
                      labelOf: GoalPill.statusLabel,
                      onChanged: (v) => setState(() => _status = v),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('القسم', 'Department')),
                  Autocomplete<String>(
                    optionsBuilder: (textEditingValue) {
                      final query = textEditingValue.text.toLowerCase();
                      return state.deptSuggestions.where(
                        (d) => query.isEmpty || d.toLowerCase().contains(query),
                      );
                    },
                    onSelected: (v) => _dept.text = v,
                    fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                      if (controller.text != _dept.text) {
                        controller.value = TextEditingValue(
                          text: _dept.text,
                          selection: TextSelection.collapsed(
                            offset: _dept.text.length,
                          ),
                        );
                      }
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => _dept.text = v,
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  _label(AppText.t('الموقع', 'Site')),
                  Autocomplete<String>(
                    optionsBuilder: (textEditingValue) {
                      final query = textEditingValue.text.toLowerCase();
                      return state.siteSuggestions.where(
                        (s) => query.isEmpty || s.toLowerCase().contains(query),
                      );
                    },
                    onSelected: (v) => _site.text = v,
                    fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                      if (controller.text != _site.text) {
                        controller.value = TextEditingValue(
                          text: _site.text,
                          selection: TextSelection.collapsed(
                            offset: _site.text.length,
                          ),
                        );
                      }
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => _site.text = v,
                      );
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('المالك', 'Owner')),
                  Row(
                    children: [
                      Expanded(
                          child: Autocomplete<MapEntry<String, String>>(
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
                            fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                              if (controller.text != _ownerName.text) {
                                controller.value = TextEditingValue(
                                  text: _ownerName.text,
                                  selection: TextSelection.collapsed(
                                    offset: _ownerName.text.length,
                                  ),
                                );
                              }
                              return TextFormField(
                                controller: controller,
                                focusNode: focusNode,
                                decoration: InputDecoration(
                                  labelText: AppText.t('الاسم', 'Name'),
                                  border: const OutlineInputBorder(),
                                  isDense: true,
                                ),
                                validator: (value) =>
                                    value != null &&
                                        value.trim().isNotEmpty &&
                                        _ownerId.text.trim().isEmpty
                                    ? AppText.t(
                                        'اختر مالكاً من الاقتراحات',
                                        'Select an owner from the suggestions',
                                      )
                                    : null,
                                onChanged: (v) {
                                  _ownerName.text = v;
                                  _ownerId.clear();
                                },
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: TextField(
                            controller: _ownerId,
                            readOnly: true,
                            decoration: InputDecoration(
                              labelText: AppText.t('المعرّف', 'Id'),
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: AppSpacing.md),
                  _label(AppText.t('الهدف والقياس', 'Target and baseline')),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _targetValue,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: AppText.t('القيمة المستهدفة', 'Target'),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                      child: Autocomplete<String>(
                        optionsBuilder: (textEditingValue) {
                          final query = textEditingValue.text.toLowerCase();
                          return state.unitSuggestions.where(
                            (u) => query.isEmpty || u.toLowerCase().contains(query),
                          );
                        },
                        onSelected: (v) => _targetUnit.text = v,
                        fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                          if (controller.text != _targetUnit.text) {
                            controller.value = TextEditingValue(
                              text: _targetUnit.text,
                              selection: TextSelection.collapsed(
                                offset: _targetUnit.text.length,
                              ),
                            );
                          }
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            decoration: InputDecoration(
                              labelText: AppText.t('الوحدة', 'Unit'),
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onChanged: (v) => _targetUnit.text = v,
                          );
                        },
                      ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _baseline,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: AppText.t('خط الأساس', 'Baseline'),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: TextField(
                          controller: _current,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: AppText.t('الحالي', 'Current'),
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Row(
                    children: [
                      Expanded(
                        child: _DateField(
                          label: AppText.t('البداية', 'Start'),
                          value: _startDate,
                          onPicked: (d) => setState(() => _startDate = d),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: _DateField(
                          label: AppText.t('الاستحقاق', 'Due'),
                          value: _dueDate,
                          onPicked: (d) => setState(() => _dueDate = d),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  FilledButton(
                    onPressed: state.saving ? null : _save,
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

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final cubit = context.read<QcGoalsCubit>();
    final existing = widget.goal;
    final now = nowIso();
    final goal = QcGoal(
      goalId: existing?.goalId,
      code: _code.text.trim(),
      title: _title.text.trim(),
      description: _description.text.trim(),
      goalType: _goalType,
      dept: _dept.text.trim(),
      site: _site.text.trim(),
      priority: _priority,
      status: _status,
      targetValue: double.tryParse(_targetValue.text.trim()),
      targetUnit: _targetUnit.text.trim(),
      baselineValue: double.tryParse(_baseline.text.trim()),
      currentValue: double.tryParse(_current.text.trim()),
      startDate: _startDate,
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

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final List<String> values;
  final String selected;
  final String Function(String) labelOf;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: [
        for (final value in values)
          ChoiceChip(
            label: Text(labelOf(value)),
            selected: value == selected,
            onSelected: (_) => onChanged(value),
          ),
      ],
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
