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
import '../../domain/qc_custom_table.dart';
import '../../domain/qc_repositories.dart';
import '../../../../design_system/widgets/app_select_field.dart';

/// One editable row of the editor's field list: what the form holds per
/// column while open. Kept outside the widgets so [showQcTableEditor] can
/// seed it with an existing definition and reconcile identities on save.
class _FieldDraft {
  _FieldDraft({this.fieldId, this.sortOrder = 0});

  final int? fieldId;
  final int sortOrder;
  final TextEditingController label = TextEditingController();
  String colType = QcCustomColType.text;
  bool required = false;

  void dispose() => label.dispose();
}

/// Shows the custom-table editor: dialog window on desktop, full-screen
/// route on phones - the same split the routine list editor uses. A definition
/// plus its columns are saved through [QcCustomTablesRepository] as one
/// reconciled write. Returns true when something was saved.
Future<bool> showQcTableEditor(
  BuildContext context, [
  ({QcCustomTable table, List<QcCustomTableField> fields})? bundle,
]) async {
  final form = _QcTableForm(bundle: bundle);
  if (FormFactor.current.isDesktop) {
    final saved =
        await showAppWindow<bool>(
          context,
          title: bundle == null
              ? AppText.t('جدول جديد', 'New table')
              : AppText.t('تعديل الجدول', 'Edit table'),
          icon: Icons.tune,
          maxWidth: 560,
          child: form,
        ) ??
        false;
    return saved;
  }
  final saved =
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppTopAppBar(
              title: bundle == null
                  ? AppText.t('جدول جديد', 'New table')
                  : AppText.t('تعديل الجدول', 'Edit table'),
            ),
            body: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.pageMobile),
                child: form,
              ),
            ),
          ),
        ),
      ) ??
      false;
  return saved;
}

class _QcTableForm extends StatefulWidget {
  const _QcTableForm({this.bundle});

  final ({QcCustomTable table, List<QcCustomTableField> fields})? bundle;

  @override
  State<_QcTableForm> createState() => _QcTableFormState();
}

class _QcTableFormState extends State<_QcTableForm> {
  late final TextEditingController _title = TextEditingController(
    text: widget.bundle?.table.title ?? '',
  );
  late final TextEditingController _description = TextEditingController(
    text: widget.bundle?.table.description ?? '',
  );
  late final List<_FieldDraft> _drafts = [
    for (final f in (widget.bundle?.fields ?? const <QcCustomTableField>[]))
      _FieldDraft(fieldId: f.fieldId, sortOrder: f.sortOrder)
        ..label.text = f.label
        ..colType = f.colType
        ..required = f.required,
    if (widget.bundle == null) _FieldDraft(),
  ];

  bool _saving = false;

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      AppFeedback.error(
        context,
        AppText.t('الجدول يحتاج إلى اسم', 'A table needs a name.'),
      );
      return;
    }
    final drafts = [
      for (final d in _drafts)
        if (d.label.text.trim().isNotEmpty) d,
    ];
    if (drafts.isEmpty) {
      AppFeedback.error(
        context,
        AppText.t('أضف عموداً واحداً على الأقل', 'Add at least one column.'),
      );
      return;
    }
    // Duplicate labels among kept drafts must not reach the repository.
    final labels = drafts.map((d) => d.label.text.trim()).toList();
    if (labels.toSet().length != labels.length) {
      AppFeedback.error(
        context,
        AppText.t(
          'اسم كل عمود يجب أن يختلف',
          'Every column needs a distinct label.',
        ),
      );
      return;
    }
    setState(() => _saving = true);
    final fields = drafts
        .map(
          (d) => QcCustomTableField(
            // Only the id matters to the facade: matched drafts are
            // updated in place, unmatched ones tombstoned, new ones
            // inserted with a fresh remote id. All other stamps come
            // from the live row inside the facade's transaction.
            fieldId: d.fieldId,
            label: d.label.text.trim(),
            colType: d.colType,
            required: d.required,
            // Column order never shuffles in this editor; drafts keep
            // their stored positions and new ones are appended.
            sortOrder: d.sortOrder,
            createdAt: '',
            updatedAt: '',
          ),
        )
        .toList();
    final existing = widget.bundle?.table;
    final table = QcCustomTable(
      tableId: existing?.tableId,
      remoteId: existing?.remoteId ?? '',
      title: title,
      description: _description.text.trim(),
      createdAt: existing?.createdAt ?? DateTime.now().toIso8601String(),
      updatedAt: DateTime.now().toIso8601String(),
      version: existing?.version ?? 1,
    );
    try {
      final repo = getIt<QcCustomTablesRepository>();
      if (existing == null) {
        await repo.createTable(table, fields);
      } else {
        await repo.saveTable(table, fields);
      }
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
  void dispose() {
    _title.dispose();
    _description.dispose();
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppField(
          label: AppText.t('اسم الجدول', 'Table name'),
          controller: _title,
          enabled: !_saving,
          hint: AppText.t('مثال: أوزان العينات', 'e.g. Sample weights'),
          autofocus: widget.bundle == null,
        ),
        const SizedBox(height: AppSpacing.md),
        AppField(
          label: AppText.t('الوصف (اختياري)', 'Description (optional)'),
          controller: _description,
          enabled: !_saving,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          AppText.t('الأعمدة', 'Columns'),
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
            itemCount: _drafts.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
            itemBuilder: (context, i) {
              final draft = _drafts[i];
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: AppField(
                      label: AppText.t('العمود ${i + 1}', 'Column ${i + 1}'),
                      controller: draft.label,
                      enabled: !_saving,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    flex: 2,
                    child: AppSelectField<String>(
                      initialValue: draft.colType,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: AppText.t('النوع', 'Type'),
                      ),
                      items: [
                        for (final t in QcCustomColType.all)
                          DropdownMenuItem(
                            value: t,
                            child: Text(QcCustomColType.label(t)),
                          ),
                      ],
                      onChanged: _saving
                          ? null
                          : (v) => setState(
                              () => draft.colType = v ?? draft.colType,
                            ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  // `required` flips the column from nice-to-have to
                  // blocking: a record missing it is rejected on write.
                  Tooltip(
                    message: AppText.t(
                      'مطلوب في كل تسجيل',
                      'Required on every record',
                    ),
                    child: Checkbox(
                      value: draft.required,
                      tristate: false,
                      visualDensity: VisualDensity.compact,
                      onChanged: _saving
                          ? null
                          : (v) => setState(() => draft.required = v ?? false),
                    ),
                  ),
                  IconButton(
                    tooltip: AppText.t('حذف العمود', 'Remove column'),
                    onPressed: _saving || _drafts.length <= 1
                        ? null
                        : () => setState(() {
                            final d = _drafts.removeAt(i);
                            d.dispose();
                          }),
                    icon: Icon(
                      Icons.remove_circle_outline,
                      size: 22.r,
                      color: AppColors.danger,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton(
          style: AppButtonStyle.secondary,
          small: true,
          label: AppText.t('إضافة عمود', 'Add column'),
          icon: Icon(Icons.add, size: 18.r),
          onPressed: _saving
              ? null
              : () => setState(() => _drafts.add(_FieldDraft())),
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
