import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/responsive/form_factor.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../../domain/routine_repository.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_template.dart';

/// Shows the routine-list editor: dialog window on desktop, full-screen
/// route on phones. Name + department + daily/monthly + a flat item list.
/// Returns true when a list was saved.
Future<bool> showRoutineListEditor(
  BuildContext context, [
  QcTemplate? template,
]) async {
  // Current items for an edit (labels only, display order). Reading them
  // directly never creates a sheet as a side effect.
  List<String> items = const [];
  if (template?.templateId != null) {
    try {
      items = await getIt<RoutineListsRepository>().listItemLabels(
        template!.templateId!,
      );
    } catch (_) {
      items = const [];
    }
  }
  if (!context.mounted) return false;
  final form = _RoutineListForm(template: template, items: items);
  if (FormFactor.current.isDesktop) {
    final saved = await showAppWindow<bool>(
      context,
      title: template == null
          ? AppText.t('قائمة جديدة', 'New list')
          : AppText.t('تعديل القائمة', 'Edit list'),
      icon: Icons.checklist_outlined,
      maxWidth: 560,
      child: form,
    );
    return saved ?? false;
  }
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppTopAppBar(
          title: template == null
              ? AppText.t('قائمة جديدة', 'New list')
              : AppText.t('تعديل القائمة', 'Edit list'),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.pageMobile),
            child: form,
          ),
        ),
      ),
    ),
  );
  return saved ?? false;
}

class _RoutineListForm extends StatefulWidget {
  final QcTemplate? template;
  final List<String> items;

  const _RoutineListForm({this.template, required this.items});

  @override
  State<_RoutineListForm> createState() => _RoutineListFormState();
}

class _RoutineListFormState extends State<_RoutineListForm> {
  late final TextEditingController _name = TextEditingController(
    text: widget.template?.name ?? '',
  );
  late final TextEditingController _dept = TextEditingController(
    text: widget.template?.dept ?? '',
  );
  late String _recurrence = widget.template?.recurrence == QcRecurrence.monthly
      ? QcRecurrence.monthly
      : QcRecurrence.daily;
  late final List<TextEditingController> _items = [
    for (final label in widget.items) TextEditingController(text: label),
    if (widget.items.isEmpty) TextEditingController(),
  ];
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _dept.dispose();
    for (final c in _items) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      AppFeedback.error(
        context,
        AppText.t('القائمة تحتاج إلى اسم', 'A list needs a name.'),
      );
      return;
    }
    final labels = [
      for (final c in _items)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];
    if (labels.isEmpty) {
      AppFeedback.error(
        context,
        AppText.t('أضف بنداً واحداً على الأقل', 'Add at least one item.'),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      await getIt<RoutineListsRepository>().saveRoutineList(
        templateId: widget.template?.templateId,
        name: _name.text.trim(),
        dept: _dept.text.trim(),
        recurrence: _recurrence,
        items: labels,
      );
      if (mounted) {
        Navigator.of(context).pop(true); // the pop is the confirmation
      }
    } on AppError catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppField(
          label: AppText.t('اسم القائمة', 'List name'),
          controller: _name,
          enabled: !_saving,
          hint: AppText.t('مثال: نظافة الوردية', 'e.g. Shift cleanliness'),
          autofocus: widget.template == null,
        ),
        const SizedBox(height: AppSpacing.md),
        AppField(
          label: AppText.t('القسم', 'Department'),
          controller: _dept,
          enabled: !_saving,
        ),
        const SizedBox(height: AppSpacing.md),
        DropdownButtonFormField<String>(
          initialValue: _recurrence,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: AppText.t('التكرار', 'Repeats'),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            DropdownMenuItem(
              value: QcRecurrence.daily,
              child: Text(
                AppText.t('يومية — تتصفر كل يوم', 'Daily — resets every day'),
              ),
            ),
            DropdownMenuItem(
              value: QcRecurrence.monthly,
              child: Text(
                AppText.t(
                  'شهرية — تتصفر كل شهر',
                  'Monthly — resets every month',
                ),
              ),
            ),
          ],
          onChanged: _saving
              ? null
              : (v) => setState(() => _recurrence = v ?? _recurrence),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          AppText.t('البنود', 'Items'),
          style: TextStyle(
            fontSize: 13.spMax,
            fontWeight: FontWeight.w700,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _items.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, i) => Row(
              children: [
                Expanded(
                  child: AppField(
                    label: AppText.t('بند ${i + 1}', 'Item ${i + 1}'),
                    controller: _items[i],
                    enabled: !_saving,
                  ),
                ),
                IconButton(
                  tooltip: AppText.t('حذف البند', 'Remove item'),
                  onPressed: _saving || _items.length <= 1
                      ? null
                      : () => setState(() {
                          _items.removeAt(i).dispose();
                        }),
                  icon: Icon(
                    Icons.remove_circle_outline,
                    size: 22.r,
                    color: AppColors.danger,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          style: AppButtonStyle.secondary,
          small: true,
          label: AppText.t('إضافة بند', 'Add item'),
          icon: Icon(Icons.add, size: 18.r),
          onPressed: _saving
              ? null
              : () => setState(() => _items.add(TextEditingController())),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: AppButton(
                label: AppText.t('حفظ', 'Save'),
                icon: Icon(Icons.check, size: 18.r),
                loading: _saving,
                onPressed: _saving ? null : _save,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            AppButton(
              style: AppButtonStyle.secondary,
              label: AppText.t('إلغاء', 'Cancel'),
              onPressed: _saving
                  ? null
                  : () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ],
    );
  }
}
