import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/constants/report_form_keys.dart';
import '../../../../../core/responsive/form_factor.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_date_field.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../../../settings/domain/settings_repository.dart';
import '../../domain/lab_local_repository.dart';
import '../../../../design_system/widgets/app_select_field.dart';

/// Arabic/English label for an equipment event type.
String equipmentEventLabel(String type) => switch (type) {
  EquipmentEventType.maintenance => AppText.t('صيانة', 'Maintenance'),
  EquipmentEventType.repair => AppText.t('إصلاح', 'Repair'),
  _ => AppText.t('معايرة', 'Calibration'),
};

/// Shows the equipment form: dialog window on desktop, full-screen route
/// on phones. Returns true when a row was saved.
Future<bool> showEquipmentForm(
  BuildContext context, [
  Map<String, dynamic>? item,
]) async {
  final isDesktop = FormFactor.current.isDesktop;
  final form = _EquipmentForm(item: item);
  if (isDesktop) {
    final saved = await showAppWindow<bool>(
      context,
      title: item == null
          ? AppText.t('جهاز جديد', 'New equipment')
          : AppText.t('تعديل الجهاز', 'Edit equipment'),
      icon: Icons.precision_manufacturing_outlined,
      maxWidth: 560,
      child: form,
    );
    return saved ?? false;
  }
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppTopAppBar(
          title: item == null
              ? AppText.t('جهاز جديد', 'New equipment')
              : AppText.t('تعديل الجهاز', 'Edit equipment'),
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

/// One editable form-number line: its settings [key] and the [label]
/// describing which document the number belongs to.
class FormNoField {
  const FormNoField({required this.key, required this.label});

  final String key;
  final String label;
}

/// Shows the QA form-number editor for a single document [key] (the gear
/// next to a print/export action). Returns true when saved.
Future<bool> showQaFormNoDialog(
  BuildContext context, {
  String key = ReportFormKeys.global,
  String title = '',
}) {
  return showFormNumbersDialog(
    context,
    title: title,
    fields: [
      FormNoField(key: key, label: AppText.t('رقم الفورم', 'Form number')),
    ],
  );
}

/// Shows the QA form-number editor with one field per [fields] entry — each
/// printed document (report, label, ...) keeps its own number.
/// Returns true when saved.
Future<bool> showFormNumbersDialog(
  BuildContext context, {
  required List<FormNoField> fields,
  String title = '',
}) async {
  final saved = await showAppWindow<bool>(
    context,
    title: title.isEmpty
        ? AppText.t('رقم فورم الجودة', 'QA form number')
        : title,
    icon: Icons.settings_outlined,
    maxWidth: 440,
    child: _FormNoForm(fields: fields),
  );
  return saved ?? false;
}

/// One editable line per document; each is stored under its own settings key
/// and printed only on that document's form/report.
class _FormNoForm extends StatefulWidget {
  const _FormNoForm({required this.fields});

  final List<FormNoField> fields;

  @override
  State<_FormNoForm> createState() => _FormNoFormState();
}

class _FormNoFormState extends State<_FormNoForm> {
  late final Map<String, TextEditingController> _controllers = {
    for (final field in widget.fields) field.key: TextEditingController(),
  };
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final repo = getIt<SettingsRepository>();
      for (final field in widget.fields) {
        _controllers[field.key]!.text =
            await repo.getSettingValue(field.key) ?? '';
      }
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.errorFrom(context, e);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await getIt<SettingsRepository>().updateSettings({
        for (final field in widget.fields)
          field.key: _controllers[field.key]!.text.trim(),
      });
      if (mounted) {
        // The dialog closing with the list refreshed is the confirmation;
        // a transient "Saved." toast right before the pop was pure noise.
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() => _saving = false);
      if (mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppSkeletonList(
        rows: 3,
        height: 120,
        padding: EdgeInsets.zero,
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in widget.fields) ...[
          AppField(
            label: field.label,
            controller: _controllers[field.key]!,
            enabled: !_saving,
            hint: AppText.t('مثال: QA-F-07', 'e.g. QA-F-07'),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Text(
          AppText.t(
            'لكل نموذج رقم مستقل يُطبع في تقريره فقط.',
            'Each form keeps its own number, printed on that document only.',
          ),
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
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

/// Shows the event form for [equipmentId]: dialog window on desktop,
/// full-screen route on phones. Returns true when a row was saved.
Future<bool> showEquipmentEventForm(
  BuildContext context,
  int equipmentId, [
  Map<String, dynamic>? event,
]) async {
  final isDesktop = FormFactor.current.isDesktop;
  final form = _EquipmentEventForm(equipmentId: equipmentId, event: event);
  if (isDesktop) {
    final saved = await showAppWindow<bool>(
      context,
      title: event == null
          ? AppText.t('حدث جديد', 'New event')
          : AppText.t('تعديل الحدث', 'Edit event'),
      icon: Icons.event_outlined,
      maxWidth: 520,
      child: form,
    );
    return saved ?? false;
  }
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppTopAppBar(
          title: event == null
              ? AppText.t('حدث جديد', 'New event')
              : AppText.t('تعديل الحدث', 'Edit event'),
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

/// Device form: name (required) + manufacturer + description +
/// last-calibration date. The code is minted automatically and shown
/// read-only when editing.
class _EquipmentForm extends StatefulWidget {
  final Map<String, dynamic>? item;
  const _EquipmentForm({this.item});

  @override
  State<_EquipmentForm> createState() => _EquipmentFormState();
}

class _EquipmentFormState extends State<_EquipmentForm> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.item?['name'] ?? ''}',
  );
  late final TextEditingController _manufacturer = TextEditingController(
    text: '${widget.item?['manufacturer'] ?? ''}',
  );
  late final TextEditingController _serial = TextEditingController(
    text: '${widget.item?['serial_number'] ?? ''}',
  );
  late final TextEditingController _description = TextEditingController(
    text: '${widget.item?['description'] ?? ''}',
  );
  late final TextEditingController _calibration = TextEditingController(
    text: '${widget.item?['last_calibration_date'] ?? ''}',
  );
  late final TextEditingController _nextCalibration = TextEditingController(
    text: '${widget.item?['next_calibration_date'] ?? ''}',
  );
  // True once the user types a next date by hand: auto-suggest (last + 1
  // year) must never overwrite an explicit choice afterwards.
  bool _nextTouched = false;
  bool _saving = false;

  /// Suggests next = last + 1 year while the field is still untouched.
  void _suggestNext() {
    if (_nextTouched) return;
    final suggestion = plusOneYearIso(_calibration.text.trim());
    if (suggestion.isEmpty) return;
    if (_nextCalibration.text.trim() == suggestion) return;
    _nextCalibration.text = suggestion;
  }

  @override
  void dispose() {
    _name.dispose();
    _manufacturer.dispose();
    _serial.dispose();
    _description.dispose();
    _calibration.dispose();
    _nextCalibration.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      AppFeedback.error(
        context,
        AppText.t('اسم الجهاز مطلوب', 'Equipment name is required.'),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final repo = getIt<LabLocalRepository>();
      if (widget.item == null) {
        await repo.createEquipment(
          name: _name.text.trim(),
          manufacturer: _manufacturer.text.trim(),
          serialNumber: _serial.text.trim(),
          description: _description.text.trim(),
          lastCalibrationDate: _calibration.text.trim(),
          nextCalibrationDate: _nextCalibration.text.trim(),
        );
      } else {
        await repo.updateEquipment((widget.item!['id'] as num).toInt(), {
          'name': _name.text.trim(),
          'manufacturer': _manufacturer.text.trim(),
          'serial_number': _serial.text.trim(),
          'description': _description.text.trim(),
          'last_calibration_date': _calibration.text.trim(),
          'next_calibration_date': _nextCalibration.text.trim(),
        });
      }
      if (mounted) {
        // The dialog closing with the list refreshed is the confirmation;
        // a transient "Saved." toast right before the pop was pure noise.
        Navigator.of(context).pop(true);
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
        if (widget.item != null) ...[
          _ReadOnlyCode(code: '${widget.item!['code'] ?? ''}'),
          const SizedBox(height: AppSpacing.md),
        ],
        AppField(
          label: AppText.t('اسم الجهاز', 'Equipment name'),
          controller: _name,
          enabled: !_saving,
          hint: AppText.t('مثال: فرن التجفيف', 'e.g. Drying oven'),
          autofocus: widget.item == null,
        ),
        const SizedBox(height: AppSpacing.md),
        AppField(
          label: AppText.t('الشركة المصنعة', 'Manufacturer'),
          controller: _manufacturer,
          enabled: !_saving,
        ),
        const SizedBox(height: AppSpacing.md),
        AppField(
          label: AppText.t('السيريال نمبر', 'Serial number'),
          controller: _serial,
          enabled: !_saving,
          hint: AppText.t('مثال: SN-2024-001', 'e.g. SN-2024-001'),
        ),
        const SizedBox(height: AppSpacing.md),
        AppField(
          label: AppText.t('وصف الجهاز', 'Description'),
          controller: _description,
          enabled: !_saving,
          maxLines: 3,
        ),
        const SizedBox(height: AppSpacing.md),
        AppDateField(
          label: AppText.t('تاريخ آخر معايرة', 'Last calibration date'),
          controller: _calibration,
          enabled: !_saving,
          onChanged: (_) => _suggestNext(),
        ),
        const SizedBox(height: AppSpacing.md),
        AppDateField(
          label: AppText.t('المعايرة القادمة', 'Next calibration'),
          controller: _nextCalibration,
          enabled: !_saving,
          onChanged: (_) => _nextTouched = true,
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

/// The auto-minted code, shown read-only (never typed by hand).
class _ReadOnlyCode extends StatelessWidget {
  final String code;
  const _ReadOnlyCode({required this.code});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          AppText.t('الكود', 'Code'),
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
        const SizedBox(width: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surfaceSoft,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            code,
            textDirection: TextDirection.ltr,
            style: TextStyle(fontSize: 13.spMax, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          AppText.t('(تلقائي)', '(automatic)'),
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
      ],
    );
  }
}

/// Event form: type (calibration/maintenance/repair) + date + notes.
class _EquipmentEventForm extends StatefulWidget {
  final int equipmentId;
  final Map<String, dynamic>? event;
  const _EquipmentEventForm({required this.equipmentId, this.event});

  @override
  State<_EquipmentEventForm> createState() => _EquipmentEventFormState();
}

class _EquipmentEventFormState extends State<_EquipmentEventForm> {
  late String _type = EquipmentEventType.normalize(
    widget.event?['event_type'] ?? EquipmentEventType.calibration,
  );
  late final TextEditingController _date = TextEditingController(
    text: '${widget.event?['event_date'] ?? todayIso()}',
  );
  late final TextEditingController _notes = TextEditingController(
    text: '${widget.event?['notes'] ?? ''}',
  );
  bool _saving = false;

  @override
  void dispose() {
    _date.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final repo = getIt<LabLocalRepository>();
      if (widget.event == null) {
        await repo.addEquipmentEvent(
          equipmentId: widget.equipmentId,
          eventType: _type,
          eventDate: _date.text.trim().isEmpty ? todayIso() : _date.text.trim(),
          notes: _notes.text.trim(),
        );
      } else {
        await repo.updateEquipmentEvent((widget.event!['id'] as num).toInt(), {
          'event_type': _type,
          'event_date': _date.text.trim().isEmpty
              ? todayIso()
              : _date.text.trim(),
          'notes': _notes.text.trim(),
        });
      }
      if (mounted) {
        // The dialog closing with the list refreshed is the confirmation;
        // a transient "Saved." toast right before the pop was pure noise.
        Navigator.of(context).pop(true);
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
        Text(
          AppText.t('نوع الحدث', 'Event type'),
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
        const SizedBox(height: AppSpacing.xs),
        AppSelectField<String>(
          initialValue: _type,
          isExpanded: true,
          menuMaxHeight: 320,
          decoration: const InputDecoration(),
          items: [
            for (final t in EquipmentEventType.values)
              DropdownMenuItem(value: t, child: Text(equipmentEventLabel(t))),
          ],
          onChanged: _saving ? null : (v) => setState(() => _type = v ?? _type),
        ),
        const SizedBox(height: AppSpacing.md),
        AppDateField(
          label: AppText.t('تاريخ الحدث', 'Event date'),
          controller: _date,
          enabled: !_saving,
        ),
        const SizedBox(height: AppSpacing.md),
        AppField(
          label: AppText.t('ملاحظات', 'Notes'),
          controller: _notes,
          enabled: !_saving,
          maxLines: 3,
          hint: AppText.t(
            'مثال: تمت المعايرة بواسطة...',
            'e.g. Calibrated by...',
          ),
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
