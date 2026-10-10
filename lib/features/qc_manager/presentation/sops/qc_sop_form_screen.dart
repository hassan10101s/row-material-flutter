import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_sop.dart';
import '../cubit/qc_sop_detail_cubit.dart';
import '../cubit/qc_sops_cubit.dart';

/// Create or edit an SOP.
///
/// Two modes, one form: creating goes through the register cubit, editing
/// through the detail cubit that is already on screen. Both end up at the same
/// guarded repository, so the only thing this widget decides is which cubit it
/// hands the result to.
class QcSopFormScreen extends StatefulWidget {
  const QcSopFormScreen({super.key, this.sop, this.detail, this.embedded = false});

  final QcSop? sop;
  final QcSopDetailCubit? detail;

  /// True inside the desktop [showAppWindow] dialog: no inner [Scaffold]
  /// (a Scaffold inside the window's scrollable body gets unbounded
  /// height and explodes) — the window provides the title chrome.
  final bool embedded;

  bool get isEdit => sop != null;

  static Future<void> open(
    BuildContext context, {
    QcSop? sop,
    QcSopDetailCubit? detail,
  }) {
    final register = context.read<QcSopsCubit>();
    final wide = MediaQuery.of(context).size.width >= AppBreakpoints.medium;
    if (wide) {
      return showAppWindow(
        context,
        title: sop == null
            ? AppText.t('إجراء قياسي جديد SOP', 'New SOP')
            : AppText.t('تعديل الإجراء القياسي SOP', 'Edit SOP'),
        icon: Icons.menu_book_outlined,
        size: AppWindowSize.lg,
        child: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: register),
            if (detail != null) BlocProvider.value(value: detail),
          ],
          child: QcSopFormScreen(sop: sop, detail: detail, embedded: true),
        ),
      );
    }
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

/// Simplified Word-like editor (plan §5): title + category + body only.
/// Roles, version tracking, expiry, read-ack and rejection reason stay in DB
/// but are hidden from the UI. Images via Firebase Storage are skipped.
class _QcSopFormScreenState extends State<QcSopFormScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _category;
  late final TextEditingController _body;
  bool _readMode = false;

  @override
  void initState() {
    super.initState();
    final sop = widget.sop;
    _title = TextEditingController(text: sop?.title ?? '');
    _category = TextEditingController(
      text: sop?.category.isNotEmpty == true
          ? sop!.category
          : AppText.t('إجراءات التشغيل', 'Operations'),
    );
    _body = TextEditingController(text: sop?.contentText ?? '');
  }

  @override
  void dispose() {
    for (final c in [_title, _category, _body]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sop = widget.sop;
    if (widget.embedded) {
      // Dialog mode: the window scrolls and titles, so the form is a plain
      // Column (a Scaffold/ListView here would take infinite height).
      return _withErrors(
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => setState(() => _readMode = !_readMode),
                icon: Icon(
                  _readMode ? Icons.edit_outlined : Icons.menu_book_outlined,
                  size: 18,
                ),
                label: Text(
                  _readMode
                      ? AppText.t('تحرير', 'Edit')
                      : AppText.t('عرض للقراءة', 'Read view'),
                ),
              ),
            ),
            Form(key: _form, child: Column(children: _formFields(sop))),
          ],
        ),
      );
    }
    return _withErrors(
      Scaffold(
        appBar: AppTopAppBar(
          title: widget.isEdit
              ? AppText.t('تعديل الإجراء', 'Edit procedure')
              : AppText.t('إجراء جديد', 'New procedure'),
          actions: [
            // Read / edit toggle like a Word doc.
            IconButton(
              tooltip: _readMode
                  ? AppText.t('تحرير', 'Edit')
                  : AppText.t('عرض للقراءة', 'Read view'),
              icon: Icon(_readMode ? Icons.edit_outlined : Icons.menu_book_outlined),
              onPressed: () => setState(() => _readMode = !_readMode),
            ),
          ],
        ),
        body: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.md),
            children: _formFields(sop),
          ),
        ),
      ),
    );
  }

  /// The form fields shared by the route (scrolls itself) and the dialog
  /// (the window scrolls, so no ListView/Expanded here).
  List<Widget> _formFields(QcSop? sop) => [
        // Title — editable on create; identity is fixed after (copyWith
        // cannot carry it, so an editable field would silently drop).
        _field(
          _title,
          AppText.t('إجراء: عنوان الإجراء', 'Procedure title'),
          required: true,
          enabled: !widget.isEdit || !_readMode,
        ),
        _field(
          _category,
          AppText.t('الفئة', 'Category'),
          enabled: !widget.isEdit || !_readMode,
        ),
        if (sop != null && sop.code.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text(
              '${sop.code}  •  rev ${sop.revNo}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        const Divider(),
        Text(
          AppText.t('─── المحتوى ───', '─── Body ───'),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_readMode)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE2E8F0)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              _body.text.isEmpty
                  ? AppText.t('(لا يوجد محتوى بعد)', '(Empty)')
                  : _body.text,
              style: const TextStyle(fontSize: 14, height: 1.7),
            ),
          )
        else
          TextFormField(
            controller: _body,
            minLines: 12,
            maxLines: 30,
            decoration: InputDecoration(
              hintText: AppText.t(
                '1. أوقف الماكينة قبل التنظيف\n2. استخدم المنظف المعتمد\n3. امسح جميع الأسطح',
                '1. Stop the machine\n2. Use the approved cleaner\n3. Wipe all surfaces',
              ),
              border: const OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(AppText.t('💾 حفظ', 'Save')),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _readMode = !_readMode),
                icon: const Icon(Icons.menu_book_outlined, size: 18),
                label: Text(AppText.t('📖 عرض للقراءة', 'Read view')),
              ),
            ),
          ],
        ),
      ];

  /// Surfaces whichever cubit owns the write.
  ///
  /// Edit saves through the detail cubit, create through the register, and only
  /// one of the two exists in a given mode - a listener on both would throw on
  /// the missing provider.
  Widget _withErrors(Widget child) {
    void show(String? message, VoidCallback clear) {
      if (message == null) return;
      AppFeedback.error(context, message);
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

  String _autoCode() {
    final now = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return 'SOP-${now.year}${p(now.month)}${p(now.day)}-${p(now.hour)}${p(now.minute)}';
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final now = nowIso();
    final existing = widget.sop;
    // Simplified: only the body is editable after creation; identity fields
    // are fixed. Hidden fields keep DB defaults.
    final next = (existing ??
            QcSop(
              code: _autoCode(),
              title: _title.text.trim(),
              category: _category.text.trim(),
              status: SopStatus.draft,
              createdAt: now,
              updatedAt: now,
            ))
        .copyWith(
      contentType: SopContentType.text,
      contentText: _body.text.trim(),
      updatedAt: now,
    );

    if (widget.isEdit) {
      final detail = context.read<QcSopDetailCubit>();
      await detail.save(next);
      if (detail.state.error != null) return;
    } else {
      final register = context.read<QcSopsCubit>();
      await register.createSop(
        QcSop(
          code: _autoCode(),
          title: _title.text.trim(),
          category: _category.text.trim(),
          status: SopStatus.draft,
          contentType: SopContentType.text,
          contentText: _body.text.trim(),
          createdAt: now,
          updatedAt: now,
        ),
      );
      if (register.state.error != null) return;
    }
    if (mounted) Navigator.of(context).pop();
  }
}
