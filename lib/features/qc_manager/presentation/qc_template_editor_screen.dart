import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_dropdown.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_template.dart';
import 'cubit/qc_templates_cubit.dart';
import 'widgets/qc_pill.dart';

/// The checklist tree editor: template, sections, items, and the publish gate.
///
/// One screen for both roles because they are the same decision at different
/// depths - a reader fixing a label and a quality manager issuing the checklist
/// want the same tree in front of them, and splitting them would mean two
/// layouts to keep in agreement.
class QcTemplateEditorScreen extends StatelessWidget {
  const QcTemplateEditorScreen({super.key, this.templateId});

  final int? templateId;

  bool get isNew => templateId == null;

  /// `null` opens the create form; an id opens the tree.
  ///
  /// Both cubits are scoped to the pushed route. The detail cubit is created
  /// here rather than resolved from DI because it needs the library instance:
  /// it holds the library so a publish or an archive lands in the list behind
  /// this screen, and two independently-resolved instances would each need its
  /// own refresh call - and the one nobody fires is the one that reads stale.
  static Future<void> open(BuildContext context, {int? templateId}) {
    return Navigator.of(context).push(_route(context, templateId: templateId));
  }

  /// The pushed route, shared with the create form so "just created" lands on
  /// the same editor with the same cubits as "opened from the library".
  static Route<void> _route(BuildContext context, {int? templateId}) {
    final library = context.read<QcTemplatesCubit>();
    return appMaterialPageRoute<void>(
      builder: (_) => MultiBlocProvider(
        providers: [
          BlocProvider.value(value: library),
          if (templateId != null)
            BlocProvider(
              create: (_) => QcTemplateDetailCubit(
                repo: library.repo,
                library: library,
                templateId: templateId,
              )..load(),
              child: const SizedBox.shrink(),
            ),
        ],
        child: QcTemplateEditorScreen(templateId: templateId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isNew) return const _NewTemplateForm();
    final detail = context.read<QcTemplateDetailCubit>();
    return BlocConsumer<QcTemplateDetailCubit, QcTemplateDetailState>(
      listenWhen: (a, b) =>
          (a.error != b.error && b.error != null) ||
          (a.notice != b.notice && b.notice != null),
      listener: (context, state) {
        if (state.error != null) {
          AppFeedback.error(context, state.error!);
          detail.clearError();
        } else if (state.notice != null) {
          AppFeedback.success(context, state.notice!);
          detail.clearNotice();
        }
      },
      builder: (context, state) {
        final template = state.template;
        return Scaffold(
          appBar: AppTopAppBar(
            title: template?.name ?? AppText.t('قائمة الفحص', 'Checklist'),
            actions: [
              if (state.dirty)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: Center(
                    child: Text(
                      AppText.t('غير محفوظ', 'Unsaved'),
                      style: TextStyle(
                        fontSize: 11.spMax,
                        color: AppColors.warning,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          body: state.loading && template == null
              ? const Center(child: CircularProgressIndicator())
              : template == null
              ? AppEmptyState(
                  icon: Icons.search_off,
                  title: AppText.t(
                    'القالب غير موجود',
                    'This template no longer exists',
                  ),
                )
              : _Tree(state: state, template: template),
        );
      },
    );
  }
}

class _Tree extends StatelessWidget {
  const _Tree({required this.state, required this.template});

  final QcTemplateDetailState state;
  final QcTemplate template;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcTemplateDetailCubit>();
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        Row(
          children: [
            QcPill.publication(
              published: template.isPublished,
              archived: template.isArchived,
            ),
            const SizedBox(width: AppSpacing.xs),
            QcPill.version('v${template.version}'),
            const SizedBox(width: AppSpacing.xs),
            QcPill.type(template.type),
            const SizedBox(width: AppSpacing.xs),
            QcPill(
              template.isPeriodic
                  ? AppText.t(
                      'مهام ${_recurrenceAr(template.recurrence)}',
                      template.recurrence,
                    )
                  : AppText.t('فحص جودة', 'Quality'),
              template.isPeriodic ? AppColors.info : AppColors.success,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _TemplateMetaCard(template: template),
        const SizedBox(height: AppSpacing.md),
        _PublishGate(state: state, template: template),
        const SizedBox(height: AppSpacing.md),
        for (final section in state.liveSections) ...[
          _SectionCard(
            section: section,
            items: state.itemsFor(section.sectionId ?? 0),
            frozen: state.isFrozen,
            onAddItem: () => cubit.addItem(section.sectionId ?? 0),
            onRemoveSection: () => cubit.removeSection(section.sectionId ?? 0),
            onEditItem: (item) => _editItem(context, item),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        if (!state.isFrozen)
          OutlinedButton.icon(
            onPressed: () => _addSection(context),
            icon: const Icon(Icons.add, size: 18),
            label: Text(AppText.t('إضافة قسم', 'Add section')),
          ),
        if (state.liveSections.isEmpty && !state.isFrozen) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            AppText.t(
              'أضف قسمًا أولًا حتى تصبح القائمة قابلة للنشر',
              'Add a section first - an empty checklist cannot be published',
            ),
            style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }

  Future<void> _addSection(BuildContext context) async {
    final cubit = context.read<QcTemplateDetailCubit>();
    final title = await _prompt(
      context,
      title: AppText.t('قسم جديد', 'New section'),
      label: AppText.t('عنوان القسم', 'Section title'),
      confirmLabel: AppText.t('إضافة', 'Add'),
    );
    if (title == null) return;
    cubit.addSection(title);
  }

  void _editItem(BuildContext context, QcItem item) {
    final cubit = context.read<QcTemplateDetailCubit>();
    showAppOverlay<void>(
      context,
      title: AppText.t('البند', 'Item'),
      icon: Icons.checklist_outlined,
      size: AppWindowSize.sm,
      builder: (_, _) => _ItemSheet(
        item: item,
        // The write happens here, on a copy the sheet builds. Letting the sheet
        // hold a cubit instead would put the tree's state under a modal's
        // lifetime.
        onSave: (edited) => cubit.updateItem(item.itemId ?? 0, edited),
        onDelete: () => cubit.removeItem(item.itemId ?? 0),
      ),
    );
  }
}

String _recurrenceAr(String r) => switch (r) {
  QcRecurrence.daily => 'يومية',
  QcRecurrence.weekly => 'أسبوعية',
  QcRecurrence.monthly => 'شهرية',
  _ => 'لمرة واحدة',
};

/// Asks for one line of text; returns it, or null if the reader backed out.
///
/// The controller belongs to [_PromptDialog] rather than the caller. A caller
/// that creates and disposes its own controller has to guess when the dialog
/// stops rebuilding - and it does not stop the instant `pop` returns, so
/// disposing on the next line throws "used after being disposed" on the way
/// down. Disposing with the widget is the only ordering that is correct.
Future<String?> _prompt(
  BuildContext context, {
  required String title,
  required String label,
  required String confirmLabel,
  String initialValue = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _PromptDialog(
      title: title,
      label: label,
      confirmLabel: confirmLabel,
      initialValue: initialValue,
    ),
  );
}

class _PromptDialog extends StatefulWidget {
  const _PromptDialog({
    required this.title,
    required this.label,
    required this.confirmLabel,
    this.initialValue = '',
  });

  final String title;
  final String label;
  final String confirmLabel;
  final String initialValue;

  @override
  State<_PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<_PromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppWindow(
      title: widget.title,
      icon: Icons.edit_outlined,
      size: AppWindowSize.sm,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppText.t('إلغاء', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.confirmLabel),
        ),
      ],
      child: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.label),
      ),
    );
  }
}

class _TemplateMetaCard extends StatelessWidget {
  const _TemplateMetaCard({required this.template});

  final QcTemplate template;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (template.code.isNotEmpty)
            _Row(label: AppText.t('الرمز', 'Code'), value: template.code),
          _Row(
            label: AppText.t('الطبيعة', 'Kind'),
            value: template.isPeriodic
                ? AppText.t(
                    'مهام ${_recurrenceAr(template.recurrence)}',
                    '${template.recurrence} tasks',
                  )
                : AppText.t('فحص جودة', 'Quality check'),
          ),
          _Row(label: AppText.t('القسم', 'Department'), value: template.dept),
          _Row(
            label: AppText.t('ساري من', 'Effective'),
            value: template.effectiveDate,
          ),
          _Row(
            label: AppText.t('ينتهي في', 'Expires'),
            value: template.expiryDate,
            danger: template.isExpired,
          ),
          if (template.description.isNotEmpty) ...[
            const Divider(),
            Text(template.description, style: TextStyle(fontSize: 12.spMax)),
          ],
          const Divider(),
          _Flag(
            label: AppText.t(
              'يتطلب موافقة قبل الإغلاق',
              'Approval before closing',
            ),
            value: template.requiresApprovalOnSubmit,
          ),
          _Flag(
            label: AppText.t('يسمح بـ N/A', 'Allows N/A'),
            value: template.allowNa,
          ),
          _Flag(
            label: AppText.t(
              'يطلب دليلًا عند الفشل',
              'Evidence required on failure',
            ),
            value: template.enforceEvidenceOnFail,
          ),
          _Flag(
            label: AppText.t(
              'يمنع الإرسال عند فشل حرج',
              'Blocks submission on a critical failure',
            ),
            value: template.blockSubmitIfCriticalFail,
          ),
        ],
      ),
    );
  }
}

/// The publish gate, with its reasons attached.
///
/// A disabled button on its own is a dead end; the list underneath says what is
/// missing, so the reader knows what to fix rather than guessing.
class _PublishGate extends StatelessWidget {
  const _PublishGate({required this.state, required this.template});

  final QcTemplateDetailState state;
  final QcTemplate template;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcTemplateDetailCubit>();
    final blockers = state.blockers;
    final frozen = state.isFrozen;
    return AppCard(
      color: frozen ? AppColors.textMuted.withValues(alpha: 0.06) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                frozen ? Icons.lock_outline : Icons.verified_outlined,
                size: 18.r,
                color: frozen ? AppColors.textMuted : AppColors.success,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Text(
                  frozen
                      ? AppText.t(
                          'قائمة منشورة - أي تعديل يتطلب نسخة جديدة',
                          'Published - any change needs a new version',
                        )
                      : AppText.t('نشر القائمة', 'Publish this checklist'),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.spMax,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (frozen)
            OutlinedButton.icon(
              onPressed: state.saving ? null : () => _duplicate(context),
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: Text(
                AppText.t('إنشاء نسخة مسودة', 'Create a draft version'),
              ),
            )
          else ...[
            for (final problem in blockers)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 15.r,
                      color: AppColors.danger,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        problem,
                        style: TextStyle(
                          fontSize: 12.spMax,
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                FilledButton(
                  onPressed: state.canPublish && !state.dirty && !state.saving
                      ? () => _publish(context)
                      : null,
                  child: Text(AppText.t('نشر', 'Publish')),
                ),
                OutlinedButton(
                  onPressed: state.dirty && !state.saving ? cubit.save : null,
                  child: Text(AppText.t('حفظ', 'Save')),
                ),
                OutlinedButton(
                  onPressed: state.saving ? null : cubit.archive,
                  child: Text(AppText.t('أرشفة', 'Archive')),
                ),
              ],
            ),
            if (state.dirty)
              Text(
                AppText.t(
                  'احفظ قبل النشر',
                  'Save the tree before publishing it',
                ),
                style: TextStyle(
                  fontSize: 11.spMax,
                  color: AppColors.textMuted,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Future<void> _publish(BuildContext context) async {
    // Read the cubit before the dialog: after the await, `context` may belong to
    // a disposed route and the dialog itself owned it just for that moment.
    final cubit = context.read<QcTemplateDetailCubit>();
    final effective = await _prompt(
      context,
      title: AppText.t('نشر القائمة', 'Publish checklist'),
      label: AppText.t('ساري من', 'Effective from'),
      confirmLabel: AppText.t('نشر', 'Publish'),
    );
    if (effective == null) return;
    await cubit.publish(effectiveDate: effective.trim());
  }

  Future<void> _duplicate(BuildContext context) async {
    final cubit = context.read<QcTemplateDetailCubit>();
    final ok = await showDialog<_DuplicateRequest>(
      context: context,
      builder: (_) => _DuplicateDialog(
        suggestedName: '${template.name} v${template.version + 1}',
      ),
    );
    if (ok == null) return;
    await cubit.duplicate(newCode: ok.code, newName: ok.name);
  }
}

/// What a duplicate is called: a name and a code, collected together because
/// they are decided in the same breath - a version whose code collides is not
/// a version.
class _DuplicateRequest {
  const _DuplicateRequest(this.name, this.code);

  final String name;
  final String code;
}

class _DuplicateDialog extends StatefulWidget {
  const _DuplicateDialog({required this.suggestedName});

  final String suggestedName;

  @override
  State<_DuplicateDialog> createState() => _DuplicateDialogState();
}

class _DuplicateDialogState extends State<_DuplicateDialog> {
  late final TextEditingController _name;
  final _code = TextEditingController();

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.suggestedName);
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppWindow(
      title: AppText.t('نسخة جديدة', 'New version'),
      icon: Icons.content_copy_outlined,
      size: AppWindowSize.sm,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppText.t('إلغاء', 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(_DuplicateRequest(_name.text.trim(), _code.text.trim())),
          child: Text(AppText.t('نسخ', 'Duplicate')),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: AppText.t('الاسم', 'Name')),
          ),
          TextField(
            controller: _code,
            decoration: InputDecoration(labelText: AppText.t('الرمز', 'Code')),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.section,
    required this.items,
    required this.frozen,
    required this.onAddItem,
    required this.onRemoveSection,
    required this.onEditItem,
  });

  final QcSection section;
  final List<QcItem> items;
  final bool frozen;
  final VoidCallback onAddItem;
  final VoidCallback onRemoveSection;
  final ValueChanged<QcItem> onEditItem;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  section.title.isEmpty
                      ? AppText.t('قسم بلا عنوان', 'Untitled section')
                      : section.title,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.spMax,
                  ),
                ),
              ),
              if (section.requiredAll)
                QcPill(
                  AppText.t('كل البنود إلزامية', 'All required'),
                  AppColors.info,
                ),
              if (!frozen)
                IconButton(
                  tooltip: AppText.t('حذف القسم', 'Remove section'),
                  onPressed: onRemoveSection,
                  icon: const Icon(Icons.delete_outline, size: 20),
                ),
            ],
          ),
          if (section.description.isNotEmpty)
            Text(
              section.description,
              style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
            ),
          const Divider(),
          if (items.isEmpty)
            Text(
              AppText.t(
                'لا توجد بنود في هذا القسم',
                'No items in this section',
              ),
              style: TextStyle(fontSize: 12.spMax, color: AppColors.danger),
            )
          else
            for (final item in items)
              _ItemRow(
                item: item,
                onTap: frozen ? null : () => onEditItem(item),
              ),
          if (!frozen) ...[
            const SizedBox(height: AppSpacing.sm),
            OutlinedButton.icon(
              onPressed: onAddItem,
              icon: const Icon(Icons.add, size: 18),
              label: Text(AppText.t('إضافة بند', 'Add item')),
            ),
          ],
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, this.onTap});

  final QcItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.label.trim().isEmpty
                        ? AppText.t('بند بلا نص', 'Item with no label')
                        : item.label,
                    style: TextStyle(
                      fontSize: 13.spMax,
                      fontStyle: item.label.trim().isEmpty
                          ? FontStyle.italic
                          : FontStyle.normal,
                      color: item.label.trim().isEmpty
                          ? AppColors.danger
                          : AppColors.textStrong,
                    ),
                  ),
                  Text(
                    _typeLabel(item.itemType) +
                        (item.unit.isNotEmpty ? ' (${item.unit})' : ''),
                    style: TextStyle(
                      fontSize: 11.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (item.required)
              Icon(Icons.star, size: 15.r, color: AppColors.warning),
            if (item.isCritical)
              QcPill(AppText.t('حرج', 'Critical'), AppColors.danger),
            if (onTap != null)
              Icon(Icons.chevron_right, size: 18.r, color: AppColors.textMuted),
          ],
        ),
      ),
    );
  }

  static String _typeLabel(String type) => switch (type) {
    QcItemType.boolean => AppText.t('نعم/لا', 'Yes/No'),
    QcItemType.passFail => AppText.t('مطابق/غير مطابق', 'Pass/Fail'),
    QcItemType.na => AppText.t('لا ينطبق', 'N/A'),
    QcItemType.text => AppText.t('نص', 'Text'),
    QcItemType.number => AppText.t('رقم', 'Number'),
    QcItemType.date => AppText.t('تاريخ', 'Date'),
    QcItemType.dropdown => AppText.t('قائمة', 'Dropdown'),
    QcItemType.multiSelect => AppText.t('قائمة متعددة', 'Multi-select'),
    QcItemType.photo => AppText.t('صورة', 'Photo'),
    QcItemType.signature => AppText.t('توقيع', 'Signature'),
    _ => type,
  };
}

/// Editing one item's question.
///
/// Only the fields a checklist author actually changes are exposed. The
/// predicate columns - conditional rules, fail triggers, tolerances - are
/// JSON blobs with no UI yet, and pretending to offer them as text boxes would
/// hand the author a field they cannot get right.
class _ItemSheet extends StatefulWidget {
  const _ItemSheet({
    required this.item,
    required this.onSave,
    required this.onDelete,
  });

  final QcItem item;
  final ValueChanged<QcItem> onSave;
  final VoidCallback onDelete;

  @override
  State<_ItemSheet> createState() => _ItemSheetState();
}

class _ItemSheetState extends State<_ItemSheet> {
  late final TextEditingController _label;
  late final TextEditingController _unit;
  late final TextEditingController _options;
  late String _type;
  late bool _required;
  late bool _allowNa;
  late bool _critical;
  late bool _evidenceIfFail;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.item.label);
    _unit = TextEditingController(text: widget.item.unit);
    _options = TextEditingController(text: widget.item.options.join(', '));
    _type = widget.item.itemType;
    _required = widget.item.required;
    _allowNa = widget.item.allowNa;
    _critical = widget.item.isCritical;
    _evidenceIfFail = widget.item.requireEvidenceIfFail;
  }

  @override
  void dispose() {
    _label.dispose();
    _unit.dispose();
    _options.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final wantsOptions =
        _type == QcItemType.dropdown || _type == QcItemType.multiSelect;
    // Chrome (title, padding, scroll) comes from the overlay that hosts this
    // sheet; only the fields live here so desktop and phones share one look.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _label,
          decoration: InputDecoration(
            labelText: AppText.t('نص البند', 'Item label'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppDropdown<String>(
          value: _type,
          labelText: AppText.t('النوع', 'Type'),
          items: [
            for (final t in QcItemType.all)
              AppDropdownItem(value: t, label: _ItemRow._typeLabel(t)),
          ],
          onChanged: (v) => setState(() => _type = v ?? _type),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _unit,
          decoration: InputDecoration(
            labelText: AppText.t('الوحدة', 'Unit'),
            border: const OutlineInputBorder(),
          ),
        ),
        if (wantsOptions) ...[
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _options,
            decoration: InputDecoration(
              labelText: AppText.t(
                'الخيارات (مفصولة بفاصلة)',
                'Options (comma separated)',
              ),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _required,
          title: Text(AppText.t('إلزامي', 'Required')),
          onChanged: (v) => setState(() => _required = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _allowNa,
          title: Text(AppText.t('يسمح بـ N/A', 'Allows N/A')),
          onChanged: (v) => setState(() => _allowNa = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _critical,
          title: Text(AppText.t('بند حرج', 'Critical item')),
          subtitle: Text(
            AppText.t(
              'فشله يرفع عدم مطابقة حرج',
              'Failing it raises a critical NC',
            ),
            style: const TextStyle(fontSize: 12),
          ),
          onChanged: (v) => setState(() => _critical = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _evidenceIfFail,
          title: Text(
            AppText.t('يطلب دليلًا عند الفشل', 'Requires evidence on failure'),
          ),
          onChanged: (v) => setState(() => _evidenceIfFail = v),
        ),
            // Three buttons never fit one 376dp footer row: a Wrap folds
            // them instead of overflowing (the unified footer stays a Row
            // for the usual one/two-button case).
            Wrap(
              alignment: WrapAlignment.end,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                TextButton(
                  onPressed: () {
                    widget.onDelete();
                    Navigator.of(context).pop();
                  },
                  child: Text(
                    AppText.t('حذف البند', 'Delete item'),
                    style: TextStyle(color: AppColors.danger),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(AppText.t('إلغاء', 'Cancel')),
                ),
                FilledButton(
                  onPressed: () {
                    final options = _options.text
                        .split(',')
                        .map((o) => o.trim())
                        .where((o) => o.isNotEmpty)
                        .toList();
                    widget.onSave(
                      widget.item.copyWith(
                        label: _label.text.trim(),
                        itemType: _type,
                        unit: _unit.text.trim(),
                        optionsJson: options.join(', '),
                        required: _required,
                        allowNa: _allowNa,
                        isCritical: _critical,
                        requireEvidenceIfFail: _evidenceIfFail,
                      ),
                    );
                    Navigator.of(context).pop();
                  },
                  child: Text(AppText.t('حفظ', 'Save')),
                ),
              ],
            ),
      ],
    );
  }
}

/// Create a template, then hand the id to the tree editor.
///
/// A checklist with no sections is a legal draft but an unusable one, so the
/// form only collects identity and the tree is built next.
class _NewTemplateForm extends StatefulWidget {
  const _NewTemplateForm();

  @override
  State<_NewTemplateForm> createState() => _NewTemplateFormState();
}

class _NewTemplateFormState extends State<_NewTemplateForm> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _code = TextEditingController();
  final _dept = TextEditingController();
  final _description = TextEditingController();
  String _type = QcTemplateType.incoming;
  String _recurrence = QcRecurrence.once;

  static String _recurrenceLabel(String r) => switch (r) {
    QcRecurrence.daily => AppText.t('مهام يومية', 'Daily tasks'),
    QcRecurrence.weekly => AppText.t('مهام أسبوعية', 'Weekly tasks'),
    QcRecurrence.monthly => AppText.t('مهام شهرية', 'Monthly tasks'),
    _ => AppText.t('فحص جودة (مرة واحدة)', 'Quality check (once)'),
  };

  /// Why the last create was refused, rendered inline.
  ///
  /// A snackbar would have been the shorter answer, but it is gone by the time
  /// the reader looks back up at the form they are still standing in - and a
  /// create that failed with no visible reason looks like the button is broken.
  String? _failure;

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _dept.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = context.read<QcTemplatesCubit>();
    return Scaffold(
      appBar: AppTopAppBar(
        title: AppText.t('قائمة فحص جديدة', 'New checklist'),
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            if (_failure != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppSpacing.sm),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18.r,
                      color: AppColors.danger,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        _failure!,
                        style: TextStyle(
                          fontSize: 12.spMax,
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
            ],
            TextFormField(
              controller: _name,
              decoration: InputDecoration(
                labelText: AppText.t('الاسم', 'Name'),
                border: const OutlineInputBorder(),
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? AppText.t('هذا الحقل مطلوب', 'This field is required')
                  : null,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _code,
              decoration: InputDecoration(
                labelText: AppText.t('الرمز', 'Code'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _dept,
              decoration: InputDecoration(
                labelText: AppText.t('القسم', 'Department'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: InputDecoration(
                labelText: AppText.t('النوع', 'Type'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final t in QcTemplateType.all)
                  DropdownMenuItem(value: t, child: Text(QcPill.typeLabel(t))),
              ],
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: AppSpacing.sm),
            // Plan §3 — نوعان فقط: فحص جودة (مرة واحدة) أو مهام دورية.
            DropdownButtonFormField<String>(
              initialValue: _recurrence,
              decoration: InputDecoration(
                labelText: AppText.t('طبيعة القائمة', 'List kind'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final r in QcRecurrence.all)
                  DropdownMenuItem(value: r, child: Text(_recurrenceLabel(r))),
              ],
              onChanged: (v) => setState(() => _recurrence = v ?? _recurrence),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextFormField(
              controller: _description,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: AppText.t('الوصف', 'Description'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton(
              onPressed: library.state.saving ? null : _create,
              child: Text(AppText.t('إنشاء', 'Create')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _create() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final library = context.read<QcTemplatesCubit>();
    final now = nowIso();
    final id = await library.createTemplate(
      QcTemplate(
        name: _name.text.trim(),
        code: _code.text.trim(),
        dept: _dept.text.trim(),
        description: _description.text.trim(),
        type: _type,
        recurrence: _recurrence,
        createdAt: now,
        updatedAt: now,
      ),
    );
    if (!mounted) return;
    if (id == null) {
      // Stay put with the reason on screen. The typed values are still in the
      // fields, so the reader fixes one thing rather than retyping the form.
      setState(() => _failure = library.state.error);
      library.clearError();
      return;
    }
    setState(() => _failure = null);
    // Straight into the tree: a checklist whose sections are built in a second
    // screen is one more step between "I have a checklist" and "I can use it".
    await Navigator.of(
      context,
    ).pushReplacement(QcTemplateEditorScreen._route(context, templateId: id));
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, this.danger = false});

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: TextStyle(
                fontSize: 13.spMax,
                color: danger ? AppColors.danger : AppColors.textStrong,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Flag extends StatelessWidget {
  const _Flag({required this.label, required this.value});

  final String label;
  final bool value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            value ? Icons.check_circle_outline : Icons.remove_circle_outline,
            size: 15.r,
            color: value ? AppColors.success : AppColors.textMuted,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.spMax,
                color: value ? AppColors.textStrong : AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
