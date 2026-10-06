import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_date_field.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_sop.dart';
import 'cubit/qc_sop_detail_cubit.dart';
import 'cubit/qc_sops_cubit.dart';
import 'widgets/sop_pill.dart';

/// Create or edit an SOP.
///
/// Two modes, one form: creating goes through the register cubit, editing
/// through the detail cubit that is already on screen. Both end up at the same
/// guarded repository, so the only thing this widget decides is which cubit it
/// hands the result to.
class QcSopFormScreen extends StatefulWidget {
  const QcSopFormScreen({super.key, this.sop, this.detail});

  final QcSop? sop;
  final QcSopDetailCubit? detail;

  bool get isEdit => sop != null;

  static Future<void> open(
    BuildContext context, {
    QcSop? sop,
    QcSopDetailCubit? detail,
  }) {
    final register = context.read<QcSopsCubit>();
    return Navigator.of(context).push(
      appMaterialPageRoute<void>(
        builder: (_) => MultiBlocProvider(
          providers: [
            BlocProvider.value(value: register),
            if (detail != null) BlocProvider.value(value: detail),
          ],
          child: QcSopFormScreen(sop: sop, detail: detail),
        ),
      ),
    );
  }

  @override
  State<QcSopFormScreen> createState() => _QcSopFormScreenState();
}

class _QcSopFormScreenState extends State<QcSopFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _title;
  late final TextEditingController _category;
  late final TextEditingController _dept;
  late final TextEditingController _site;
  late final TextEditingController _owner;
  late final TextEditingController _tags;
  late final TextEditingController _effective;
  late final TextEditingController _expiry;
  late final TextEditingController _body;

  late String _criticality;
  late String _contentType;
  late bool _requiresAck;

  @override
  void initState() {
    super.initState();
    final sop = widget.sop;
    _code = TextEditingController(text: sop?.code ?? '');
    _title = TextEditingController(text: sop?.title ?? '');
    _category = TextEditingController(text: sop?.category ?? '');
    _dept = TextEditingController(text: sop?.dept ?? '');
    _site = TextEditingController(text: sop?.site ?? '');
    _owner = TextEditingController(text: sop?.ownerId ?? '');
    _tags = TextEditingController(text: sop?.tags ?? '');
    _effective = TextEditingController(text: sop?.effectiveDate ?? '');
    _expiry = TextEditingController(text: sop?.expiryDate ?? '');
    _body = TextEditingController(text: sop?.contentText ?? '');
    _criticality = sop?.criticality ?? QcPriority.medium;
    _contentType = sop?.contentType ?? SopContentType.text;
    _requiresAck = sop?.requiresReadAck ?? true;
  }

  @override
  void dispose() {
    for (final c in [
      _code,
      _title,
      _category,
      _dept,
      _site,
      _owner,
      _tags,
      _effective,
      _expiry,
      _body,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _withErrors(
      Scaffold(
        appBar: AppTopAppBar(
          title: widget.isEdit
              ? AppText.t('تعديل الإجراء', 'Edit procedure')
              : AppText.t('إجراء جديد', 'New procedure'),
        ),
        body: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              // Identity and classification are fixed once a SOP exists:
              // `copyWith` cannot carry them, so an editable field here would
              // accept a change and silently drop it on save.
              _field(
                _code,
                AppText.t('الرمز', 'Code'),
                required: true,
                enabled: !widget.isEdit,
              ),
              _field(
                _title,
                AppText.t('العنوان', 'Title'),
                required: true,
                enabled: !widget.isEdit,
              ),
              _field(
                _category,
                AppText.t('التصنيف', 'Category'),
                enabled: !widget.isEdit,
              ),
              _field(
                _dept,
                AppText.t('القسم', 'Department'),
                enabled: !widget.isEdit,
              ),
              _field(
                _site,
                AppText.t('الموقع', 'Site'),
                enabled: !widget.isEdit,
              ),
              _field(
                _owner,
                AppText.t('المالك', 'Owner id'),
                enabled: !widget.isEdit,
              ),
              _field(
                _tags,
                AppText.t('الوسوم', 'Tags'),
                enabled: !widget.isEdit,
              ),
              const SizedBox(height: AppSpacing.sm),
              _dropdown<String>(
                label: AppText.t('الأهمية', 'Criticality'),
                value: _criticality,
                enabled: !widget.isEdit,
                items: {
                  for (final v in QcPriority.all)
                    v: SopPill.criticalityLabel(v),
                },
                onChanged: (v) =>
                    setState(() => _criticality = v ?? _criticality),
              ),
              _dropdown<String>(
                label: AppText.t('نوع المحتوى', 'Content type'),
                value: _contentType,
                items: {
                  for (final v in SopContentType.all)
                    v: v == SopContentType.file
                        ? AppText.t('ملف', 'File')
                        : AppText.t('نص', 'Text'),
                },
                onChanged: (v) =>
                    setState(() => _contentType = v ?? _contentType),
              ),
              _dateField(_effective, AppText.t('ساري من', 'Effective from')),
              _dateField(_expiry, AppText.t('ينتهي في', 'Expires')),
              const SizedBox(height: AppSpacing.sm),
              TextFormField(
                controller: _body,
                minLines: 5,
                maxLines: 12,
                decoration: InputDecoration(
                  labelText: AppText.t('نص الإجراء', 'Procedure body'),
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              if (!widget.isEdit)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _requiresAck,
                  title: Text(
                    AppText.t(
                      'يتطلب إشعار قراءة',
                      'Requires read acknowledgement',
                    ),
                  ),
                  subtitle: Text(
                    AppText.t(
                      'يسجل كل مستخدم قرأ هذه المراجعة',
                      'Records who has read this revision',
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                  onChanged: (v) => setState(() => _requiresAck = v),
                ),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(
                onPressed: _save,
                child: Text(AppText.t('حفظ', 'Save')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Surfaces whichever cubit owns the write.
  ///
  /// Edit saves through the detail cubit, create through the register, and only
  /// one of the two exists in a given mode - a listener on both would throw on
  /// the missing provider.
  Widget _withErrors(Widget child) {
    void show(String? message, VoidCallback clear) {
      if (message == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      clear();
    }

    if (widget.isEdit) {
      return BlocListener<QcSopDetailCubit, QcSopDetailState>(
        listenWhen: (a, b) => a.error != b.error && b.error != null,
        listener: (context, state) {
          final cubit = context.read<QcSopDetailCubit>();
          show(state.error, cubit.clearError);
        },
        child: child,
      );
    }
    return BlocListener<QcSopsCubit, QcSopsState>(
      listenWhen: (a, b) => a.error != b.error && b.error != null,
      listener: (context, state) {
        final cubit = context.read<QcSopsCubit>();
        show(state.error, cubit.clearError);
      },
      child: child,
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        validator: required
            ? (v) => (v == null || v.trim().isEmpty)
                  ? AppText.t('هذا الحقل مطلوب', 'This field is required')
                  : null
            : null,
      ),
    );
  }

  Widget _dateField(TextEditingController controller, String label) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: AppDateField(controller: controller, label: label),
  );

  Widget _dropdown<T>({
    required String label,
    required T? value,
    required Map<T, String> items,
    required ValueChanged<T?> onChanged,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: DropdownButtonFormField<T>(
        initialValue: items.containsKey(value) ? value : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final entry in items.entries)
            DropdownMenuItem(value: entry.key, child: Text(entry.value)),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    );
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final now = nowIso();
    final existing = widget.sop;
    final base =
        existing ??
        QcSop(
          code: _code.text.trim(),
          title: _title.text.trim(),
          status: SopStatus.draft,
          createdAt: now,
          updatedAt: now,
          createdBy: _owner.text.trim(),
        );
    final next = base.copyWith(
      // `copyWith` deliberately cannot change code/title/category/dept/site or
      // criticality - they are identity and classification, and editing them
      // after creation is a different operation than editing the body. The
      // field values are therefore only applied on create, which is what the
      // guard expects to see.
      contentType: _contentType,
      contentText: _body.text.trim(),
      effectiveDate: _effective.text.trim(),
      expiryDate: _expiry.text.trim(),
      updatedAt: now,
    );

    if (widget.isEdit) {
      final detail = context.read<QcSopDetailCubit>();
      await detail.save(next);
      // The guard may refuse the write. Popping anyway would throw away
      // everything typed and read as a save that worked.
      if (detail.state.error != null) return;
    } else {
      final register = context.read<QcSopsCubit>();
      await register.createSop(
        QcSop(
          code: _code.text.trim(),
          title: _title.text.trim(),
          category: _category.text.trim(),
          dept: _dept.text.trim(),
          site: _site.text.trim(),
          status: SopStatus.draft,
          contentType: _contentType,
          contentText: _body.text.trim(),
          ownerId: _owner.text.trim(),
          tags: _tags.text.trim(),
          criticality: _criticality,
          effectiveDate: _effective.text.trim(),
          expiryDate: _expiry.text.trim(),
          requiresReadAck: _requiresAck,
          readAckMandatory: _requiresAck,
          createdAt: now,
          updatedAt: now,
          createdBy: _owner.text.trim(),
        ),
      );
      if (register.state.error != null) return;
    }
    if (mounted) Navigator.of(context).pop();
  }
}
