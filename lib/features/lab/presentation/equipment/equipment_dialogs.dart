import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_date_field.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../../data/lab_repo.dart';
import '../../domain/lab_local_repository.dart';

/// Arabic/English label for an equipment event type.
String equipmentEventLabel(String type) => switch (type) {
      LabRepo.equipmentEventMaintenance =>
        AppText.t('صيانة', 'Maintenance'),
      LabRepo.equipmentEventRepair => AppText.t('إصلاح', 'Repair'),
      _ => AppText.t('معايرة', 'Calibration'),
    };

/// Shows the equipment form: dialog window on desktop, full-screen route
/// on phones. Returns true when a row was saved.
Future<bool> showEquipmentForm(BuildContext context,
    [Map<String, dynamic>? item]) async {
  final isDesktop = MediaQuery.sizeOf(context).width >= 800;
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

/// Shows the event form for [equipmentId]: dialog window on desktop,
/// full-screen route on phones. Returns true when a row was saved.
Future<bool> showEquipmentEventForm(
  BuildContext context,
  int equipmentId, [
  Map<String, dynamic>? event,
]) async {
  final isDesktop = MediaQuery.sizeOf(context).width >= 800;
  final form = _EquipmentEventForm(
    equipmentId: equipmentId,
    event: event,
  );
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
  late final TextEditingController _name =
      TextEditingController(text: '${widget.item?['name'] ?? ''}');
  late final TextEditingController _manufacturer = TextEditingController(
    text: '${widget.item?['manufacturer'] ?? ''}',
  );
  late final TextEditingController _description = TextEditingController(
    text: '${widget.item?['description'] ?? ''}',
  );
  late final TextEditingController _calibration = TextEditingController(
    text: '${widget.item?['last_calibration_date'] ?? ''}',
  );
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _manufacturer.dispose();
    _description.dispose();
    _calibration.dispose();
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
          description: _description.text.trim(),
          lastCalibrationDate: _calibration.text.trim(),
        );
      } else {
        await repo.updateEquipment(
          (widget.item!['id'] as num).toInt(),
          {
            'name': _name.text.trim(),
            'manufacturer': _manufacturer.text.trim(),
            'description': _description.text.trim(),
            'last_calibration_date': _calibration.text.trim(),
          },
        );
      }
      if (mounted) {
        AppFeedback.success(
          context,
          AppText.t('تم الحفظ', 'Saved.'),
        );
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
              onPressed:
                  _saving ? null : () => Navigator.of(context).pop(false),
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
          style: TextStyle(color: Colors.grey, fontSize: 13.spMax),
        ),
        const SizedBox(width: AppSpacing.sm),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.grey.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            code,
            textDirection: TextDirection.ltr,
            style: TextStyle(
              fontSize: 13.spMax,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          AppText.t('(تلقائي)', '(automatic)'),
          style: TextStyle(color: Colors.grey, fontSize: 12.spMax),
        ),
      ],
    );
  }
}

/// Event form: type (calibration/maintenance/repair) + date + notes.
class _EquipmentEventForm extends StatefulWidget {
  final int equipmentId;
  final Map<String, dynamic>? event;
  const _EquipmentEventForm({
    required this.equipmentId,
    this.event,
  });

  @override
  State<_EquipmentEventForm> createState() => _EquipmentEventFormState();
}

class _EquipmentEventFormState extends State<_EquipmentEventForm> {
  late String _type = LabRepo.normalizeEquipmentEventType(
    widget.event?['event_type'] ?? LabRepo.equipmentEventCalibration,
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
          eventDate: _date.text.trim().isEmpty
              ? todayIso()
              : _date.text.trim(),
          notes: _notes.text.trim(),
        );
      } else {
        await repo.updateEquipmentEvent(
          (widget.event!['id'] as num).toInt(),
          {
            'event_type': _type,
            'event_date': _date.text.trim().isEmpty
                ? todayIso()
                : _date.text.trim(),
            'notes': _notes.text.trim(),
          },
        );
      }
      if (mounted) {
        AppFeedback.success(
          context,
          AppText.t('تم الحفظ', 'Saved.'),
        );
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
          style: TextStyle(color: Colors.grey, fontSize: 13.spMax),
        ),
        const SizedBox(height: AppSpacing.xs),
        DropdownButtonFormField<String>(
          initialValue: _type,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final t in LabRepo.equipmentEventTypes)
              DropdownMenuItem(
                value: t,
                child: Text(equipmentEventLabel(t)),
              ),
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
              onPressed:
                  _saving ? null : () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ],
    );
  }
}
