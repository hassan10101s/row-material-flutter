import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/animations/app_animations.dart';
import '../../../../di/service_locator.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_expandable_card.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_inspection.dart';
import '../domain/qc_nc_capa.dart';
import 'cubit/qc_inspection_sheet_cubit.dart';
import 'widgets/qc_pill.dart';

/// Executes one checklist sheet: answer every item, attach evidence, raise
/// non-conformances, submit for review.
///
/// Built for a phone on a plant floor first. Sections collapse so a long
/// checklist is navigable one-handed, every item answers with one tap, and the
/// item that is blocking submission is the one the header tells you about -
/// rather than making the inspector hunt through forty questions to find out
/// what is missing.
class QcInspectionSheetScreen extends StatelessWidget {
  const QcInspectionSheetScreen({super.key});

  /// Pushes the sheet, building its cubit from the service locator.
  ///
  /// The router does the same thing for the deep link; this exists for the two
  /// call sites that are already inside a `Navigator.push` (the start form
  /// handing over the id it just created, and the register's row tap).
  static Future<void> open(BuildContext context, {required int inspectionId}) {
    return Navigator.of(context).push(
      appMaterialPageRoute<void>(
        builder: (_) => BlocProvider(
          create: (_) =>
              getIt<QcInspectionSheetCubit>(param1: inspectionId)..load(),
          child: const QcInspectionSheetScreen(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<QcInspectionSheetCubit, QcInspectionSheetState>(
      listenWhen: (a, b) =>
          (a.error != b.error && b.error != null) ||
          (a.notice != b.notice && b.notice != null) ||
          (a.submitted != b.submitted && b.submitted),
      listener: (context, state) {
        final cubit = context.read<QcInspectionSheetCubit>();
        final messenger = ScaffoldMessenger.of(context);
        if (state.error != null) {
          messenger.showSnackBar(SnackBar(content: Text(state.error!)));
          cubit.clearError();
        } else if (state.notice != null) {
          messenger.showSnackBar(SnackBar(content: Text(state.notice!)));
          cubit.clearNotice();
        }
        if (state.submitted) context.pop();
      },
      builder: (context, state) {
        final inspection = state.inspection;
        return Scaffold(
          appBar: AppTopAppBar(
            title: inspection?.refLabel ?? AppText.t('فحص', 'Inspection'),
            actions: [
              IconButton(
                tooltip: AppText.t('تحديث', 'Refresh'),
                onPressed: () =>
                    context.read<QcInspectionSheetCubit>().refresh(),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: state.loading && inspection == null
              ? const Center(child: CircularProgressIndicator())
              : inspection == null
              ? AppEmptyState(
                  icon: Icons.search_off,
                  title: AppText.t('الفحص غير موجود', 'Inspection not found'),
                )
              : _Body(state: state),
          bottomNavigationBar: inspection == null
              ? null
              : _SubmitBar(state: state),
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state});

  final QcInspectionSheetState state;

  @override
  Widget build(BuildContext context) {
    final inspection = state.inspection!;
    final progress = state.progress;
    return Column(
      children: [
        _Header(state: state),
        if (state.findings.isNotEmpty) _FindingsStrip(findings: state.findings),
        if (progress.canSubmit && progress.isComplete)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            child: Text(
              AppText.t(
                'كل البنود مستوفاة — يمكنك الإرسال للمراجعة',
                'All items answered — ready to submit for review',
              ),
              style: TextStyle(
                color: AppColors.success,
                fontSize: 12.spMax,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => context.read<QcInspectionSheetCubit>().refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.xl,
              ),
              children: [
                _MetaCard(inspection: inspection),
                for (final section in state.sections) ...[
                  _SectionCard(section: section, editable: state.isEditable),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Ref, verdict, score and progress: the numbers a reader checks first.
class _Header extends StatelessWidget {
  const _Header({required this.state});

  final QcInspectionSheetState state;

  @override
  Widget build(BuildContext context) {
    final inspection = state.inspection!;
    final progress = state.progress;
    final score = inspection.scorePct;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.sm,
      ),
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: AppSpacing.xs,
                  runSpacing: AppSpacing.xs,
                  children: [
                    QcPill.inspectionStatus(inspection.status),
                    QcPill.inspectionResult(inspection.resultOverall),
                    if (score != null)
                      QcPill(
                        '${score.toStringAsFixed(0)}%',
                        QcPill.inspectionResultColor(inspection.resultOverall),
                      ),
                    if (inspection.hasOpenNc)
                      QcPill('${inspection.ncCount} NC', AppColors.danger),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress.completion,
              minHeight: 8,
              backgroundColor: AppColors.borderMuted,
              color: progress.failed > 0
                  ? AppColors.warning
                  : AppColors.primary,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            AppText.t(
              '${progress.answered} من ${progress.total} بند',
              '${progress.answered} of ${progress.total} items answered',
            ),
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
          if (progress.blockers.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            for (final blocker in progress.blockers)
              Text(
                '• $blocker',
                style: TextStyle(
                  color: AppColors.danger,
                  fontSize: 12.spMax,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// The non-conformances already raised against this sheet.
class _FindingsStrip extends StatelessWidget {
  const _FindingsStrip({required this.findings});

  final List<QcFindingNc> findings;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      color: AppColors.danger.withValues(alpha: 0.08),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t(
              'عدم مطابقة مفتوحة (${findings.where((f) => !f.isClosed).length})',
              'Open non-conformances (${findings.where((f) => !f.isClosed).length})',
            ),
            style: TextStyle(
              color: AppColors.danger,
              fontSize: 12.spMax,
              fontWeight: FontWeight.w700,
            ),
          ),
          for (final f in findings.where((f) => !f.isClosed))
            Text(
              '• ${f.description}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            ),
        ],
      ),
    );
  }
}

/// What is being inspected, and by whom. Read-only: the header is set when the
/// sheet starts.
class _MetaCard extends StatelessWidget {
  const _MetaCard({required this.inspection});

  final QcInspection inspection;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      (
        AppText.t('قائمة الفحص', 'Checklist'),
        '#${inspection.templateId} v${inspection.templateVersion}',
      ),
      (
        AppText.t('نوع المرجع', 'Reference'),
        QcPill.refTypeLabel(inspection.refType),
      ),
      if (inspection.batchNo.isNotEmpty)
        (AppText.t('الدفعة', 'Batch'), inspection.batchNo),
      if (inspection.poNo.isNotEmpty)
        (AppText.t('أمر الشراء', 'PO'), inspection.poNo),
      if (inspection.dept.isNotEmpty)
        (AppText.t('القسم', 'Department'), inspection.dept),
      if (inspection.inspectorName.isNotEmpty)
        (AppText.t('الفاحص', 'Inspector'), inspection.inspectorName),
      // A sheet can be started by hand in the database or imported, so fall
      // back to the id rather than leaving the row out and making it look
      // unattributed.
      if (inspection.inspectorName.isEmpty && inspection.inspectorId.isNotEmpty)
        (AppText.t('الفاحص', 'Inspector'), inspection.inspectorId),
      (AppText.t('التاريخ', 'Date'), inspection.inspectionDate),
    ];
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110.w,
                    child: Text(
                      label,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.spMax,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(value, style: TextStyle(fontSize: 12.spMax)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One section of the checklist, collapsible.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section, required this.editable});

  final QcSheetSection section;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    return AppExpandableCard(
      title: section.section.title,
      initiallyExpanded: section.total <= 8,
      headerTrailing: _SectionProgress(section: section),
      child: Column(
        children: [
          for (final row in section.items)
            _ItemRow(row: row, editable: editable),
        ],
      ),
    );
  }
}

/// "4 / 6 answered" for a section, so a long checklist can be navigated
/// without expanding every section to find what is left.
class _SectionProgress extends StatelessWidget {
  const _SectionProgress({required this.section});

  final QcSheetSection section;

  @override
  Widget build(BuildContext context) {
    final color = section.isComplete
        ? AppColors.success
        : (section.failed > 0 ? AppColors.warning : AppColors.textMuted);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (section.failed > 0)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.xs),
            child: QcPill(
              '${section.failed} ${AppText.t('غير مطابق', 'fail')}',
              AppColors.danger,
            ),
          ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          '${section.answered}/${section.total}',
          style: TextStyle(color: color, fontSize: 12.spMax),
        ),
      ],
    );
  }
}

/// One item: the label, its rules, and the control that answers it.
class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.row, required this.editable});

  final QcSheetItem row;
  final bool editable;

  @override
  Widget build(BuildContext context) {
    final item = row.item;
    final response = row.response;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.sm),
        color: _tint(row),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.isCritical)
                  Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.xs),
                    child: Icon(
                      Icons.priority_high,
                      size: 16.r,
                      color: AppColors.danger,
                    ),
                  ),
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 13.spMax,
                      fontWeight: row.isBlocking
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (response?.isRecorded ?? false)
                  QcPill(
                    response!.isFail
                        ? AppText.t('غير مطابق', 'Fail')
                        : (response.isNa ? 'N/A' : AppText.t('مطابق', 'Pass')),
                    response.isFail
                        ? AppColors.danger
                        : (response.isNa
                              ? AppColors.textMuted
                              : AppColors.success),
                  ),
              ],
            ),
            if (item.helpText.isNotEmpty || item.boundsLabel.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                [
                  if (item.boundsLabel.isNotEmpty)
                    AppText.t(
                      'المسموح: ${item.boundsLabel}',
                      'Allowed: ${item.boundsLabel}',
                    ),
                  if (item.helpText.isNotEmpty) item.helpText,
                ].join(' • '),
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11.spMax,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
            if (editable)
              _ItemControls(row: row)
            else
              _ReadOnlyAnswer(row: row),
            if (row.isFail && editable) _FailureActions(row: row),
          ],
        ),
      ),
    );
  }

  /// A failed or blocking row is tinted so the eye finds it while scrolling.
  static Color? _tint(QcSheetItem row) {
    if (row.isFail) return AppColors.danger.withValues(alpha: 0.05);
    if (row.isBlocking) return AppColors.warning.withValues(alpha: 0.05);
    return null;
  }
}

/// The answer control, chosen by the item's declared type.
class _ItemControls extends StatelessWidget {
  const _ItemControls({required this.row});

  final QcSheetItem row;

  @override
  Widget build(BuildContext context) {
    final item = row.item;
    switch (item.itemType) {
      case QcItemType.passFail:
      case QcItemType.boolean:
        return _PassFailRow(row: row);
      case QcItemType.number:
        return _MeasurementRow(row: row);
      case QcItemType.dropdown:
      case QcItemType.multiSelect:
        return _ChoiceRow(row: row);
      case QcItemType.date:
      case QcItemType.text:
      case QcItemType.photo:
      case QcItemType.signature:
      case QcItemType.na:
        return _TextRow(row: row);
      default:
        return _PassFailRow(row: row);
    }
  }
}

/// Pass / Fail / N/A. One tap answers - the whole point of the control.
///
/// The evidence fields sit under the buttons rather than only appearing once
/// the item has failed: a fail with nowhere to write a note is a sheet that can
/// never be submitted, and the inspector would have to fail it, hunt for the
/// note field, and re-tap to find out why the button was greyed out.
class _PassFailRow extends StatelessWidget {
  const _PassFailRow({required this.row});

  final QcSheetItem row;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcInspectionSheetCubit>();
    final result = row.response?.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _ChoiceButton(
                label: AppText.t('مطابق', 'Pass'),
                icon: Icons.check_circle_outline,
                color: AppColors.success,
                selected: result == QcResponseResult.pass,
                onTap: () => cubit.markResult(row.item, QcResponseResult.pass),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: _ChoiceButton(
                label: AppText.t('غير مطابق', 'Fail'),
                icon: Icons.cancel_outlined,
                color: AppColors.danger,
                selected: result == QcResponseResult.fail,
                onTap: () => cubit.markResult(row.item, QcResponseResult.fail),
              ),
            ),
            if (row.item.allowNa) ...[
              const SizedBox(width: AppSpacing.xs),
              _ChoiceButton(
                label: 'N/A',
                icon: Icons.remove_circle_outline,
                color: AppColors.textMuted,
                selected: result == QcResponseResult.na,
                onTap: () => cubit.markNotApplicable(row.item),
                compact: true,
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        _EvidenceFields(row: row),
      ],
    );
  }
}

/// A measured value. The verdict is derived from the acceptance band, so the
/// inspector cannot file an out-of-tolerance reading as a pass.
class _MeasurementRow extends StatefulWidget {
  const _MeasurementRow({required this.row});

  final QcSheetItem row;

  @override
  State<_MeasurementRow> createState() => _MeasurementRowState();
}

class _MeasurementRowState extends State<_MeasurementRow> {
  late final TextEditingController _controller = TextEditingController(
    text: context.read<QcInspectionSheetCubit>().valueFor(widget.row),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final cubit = context.read<QcInspectionSheetCubit>();
    final item = widget.row.item;
    final raw = _controller.text.trim().replaceAll(',', '.');
    final value = double.tryParse(raw);
    if (value == null) {
      setState(() => _error = AppText.t('أدخل رقماً', 'Enter a number'));
      return;
    }
    setState(() => _error = null);
    cubit.answer(
      item: item,
      value: raw,
      measuredValue: value,
      notes: cubit.notesFor(widget.row),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.row.item;
    final typed = double.tryParse(_controller.text.trim().replaceAll(',', '.'));
    // Only meaningful once something numeric is typed; an empty field is not
    // "out of band", it is unanswered.
    final outOfBand =
        typed != null && item.acceptanceBand != null && !item.accepts(typed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: AppField(
                label: item.unit.isEmpty
                    ? AppText.t('القيمة', 'Value')
                    : AppText.t(
                        'القيمة (${item.unit})',
                        'Value (${item.unit})',
                      ),
                controller: _controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                error:
                    _error ??
                    (outOfBand
                        ? AppText.t(
                            'خارج النطاق المسموح',
                            'Outside the allowed range',
                          )
                        : null),
                onChanged: (v) {
                  context.read<QcInspectionSheetCubit>().stageValue(
                    item.itemId ?? 0,
                    v,
                  );
                  setState(() {});
                },
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            FilledButton(
              onPressed: _commit,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              child: Text(AppText.t('حفظ', 'Save')),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        _EvidenceFields(row: widget.row),
      ],
    );
  }
}

/// Dropdown / multi-select: the item's declared options as a chip row.
class _ChoiceRow extends StatefulWidget {
  const _ChoiceRow({required this.row});

  final QcSheetItem row;

  @override
  State<_ChoiceRow> createState() => _ChoiceRowState();
}

class _ChoiceRowState extends State<_ChoiceRow> {
  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcInspectionSheetCubit>();
    final options = widget.row.item.options;
    final current = widget.row.response?.value ?? '';
    if (options.isEmpty) return _TextRow(row: widget.row);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            for (final option in options)
              ChoiceChip(
                label: Text(option),
                selected: current == option,
                onSelected: (_) => cubit.answer(
                  item: widget.row.item,
                  value: option,
                  notes: cubit.notesFor(widget.row),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        _EvidenceFields(row: widget.row),
      ],
    );
  }
}

/// Free text, date, photo and signature items: notes plus a typed value.
class _TextRow extends StatefulWidget {
  const _TextRow({required this.row});

  final QcSheetItem row;

  @override
  State<_TextRow> createState() => _TextRowState();
}

class _TextRowState extends State<_TextRow> {
  late final TextEditingController _notes = TextEditingController(
    text: context.read<QcInspectionSheetCubit>().notesFor(widget.row),
  );

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcInspectionSheetCubit>();
    final item = widget.row.item;
    final isEvidenceItem = QcItemType.isEvidence(item.itemType);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isEvidenceItem)
          AppField(
            label: AppText.t('ملاحظات', 'Notes'),
            controller: _notes,
            maxLines: 2,
            onChanged: (v) => cubit.stageNotes(item.itemId ?? 0, v),
          ),
        if (!isEvidenceItem) const SizedBox(height: AppSpacing.xs),
        _EvidenceFields(row: widget.row),
        const SizedBox(height: AppSpacing.xs),
        FilledButton(
          onPressed: () => cubit.answer(
            item: item,
            value: isEvidenceItem ? 'Recorded' : '',
            notes: isEvidenceItem ? _notes.text : cubit.notesFor(widget.row),
            result: QcResponseResult.pass,
          ),
          child: Text(AppText.t('حفظ', 'Save')),
        ),
      ],
    );
  }
}

/// Notes and photos - the evidence a failure has to carry.
class _EvidenceFields extends StatefulWidget {
  const _EvidenceFields({required this.row});

  final QcSheetItem row;

  @override
  State<_EvidenceFields> createState() => _EvidenceFieldsState();
}

class _EvidenceFieldsState extends State<_EvidenceFields> {
  late final TextEditingController _notes = TextEditingController(
    text: context.read<QcInspectionSheetCubit>().notesFor(widget.row),
  );

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcInspectionSheetCubit>();
    final item = widget.row.item;
    final response = widget.row.response;
    final photos = response?.photos ?? const [];
    final needsEvidence =
        item.needsEvidenceOnFail && (response?.isFail ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppField(
          label: needsEvidence
              ? AppText.t(
                  'إثبات لازم (مطلوب للغير المطابق)',
                  'Evidence required (failing item)',
                )
              : AppText.t('ملاحظات', 'Notes'),
          controller: _notes,
          maxLines: 2,
          onChanged: (v) => cubit.stageNotes(item.itemId ?? 0, v),
        ),
        if (photos.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final path in photos)
                Chip(
                  avatar: const Icon(Icons.photo_outlined, size: 16),
                  label: Text(
                    path.split(RegExp(r'[/\\]')).last,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: AppSpacing.xs),
        OutlinedButton.icon(
          onPressed: () => _attachPhoto(context),
          icon: const Icon(Icons.photo_camera_outlined, size: 18),
          label: Text(AppText.t('إرفاق صورة', 'Attach photo')),
        ),
      ],
    );
  }

  /// Photo capture is best-effort: on a device without a camera, or where the
  /// picker is unavailable, the notes still satisfy the evidence rule and the
  /// inspector is told rather than left with a dead button.
  Future<void> _attachPhoto(BuildContext context) async {
    final cubit = context.read<QcInspectionSheetCubit>();
    final messenger = ScaffoldMessenger.of(context);
    final item = widget.row.item;
    String? path;
    try {
      path = await _pickImage();
    } catch (_) {
      path = null;
    }
    if (path == null || path.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            AppText.t(
              'تعذّر إرفاق صورة — اكتب ملاحظة بدلاً منها',
              'Could not attach a photo — write a note instead',
            ),
          ),
        ),
      );
      return;
    }
    await cubit.attachPhoto(item, path);
  }

  Future<String?> _pickImage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 1600,
      imageQuality: 70,
    );
    return file?.path;
  }
}

/// What a submitted or reviewed sheet shows instead of the controls.
class _ReadOnlyAnswer extends StatelessWidget {
  const _ReadOnlyAnswer({required this.row});

  final QcSheetItem row;

  @override
  Widget build(BuildContext context) {
    final response = row.response;
    if (!row.isRecorded) {
      return Text(
        AppText.t('لم يُجب', 'Not answered'),
        style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
      );
    }
    final parts = <String>[
      if (response!.value.isNotEmpty && response.value != 'Recorded')
        '${AppText.t('القيمة', 'Value')}: ${response.value}',
      if (response.notes.trim().isNotEmpty) response.notes,
      if (response.photos.isNotEmpty)
        '${response.photos.length} ${AppText.t('صورة', 'photo(s)')}',
    ];
    return Text(
      parts.isEmpty ? AppText.t('تم التسجيل', 'Recorded') : parts.join(' • '),
      style: TextStyle(fontSize: 12.spMax),
    );
  }
}

/// Raising an NC and attaching evidence, offered only on a failure.
class _FailureActions extends StatelessWidget {
  const _FailureActions({required this.row});

  final QcSheetItem row;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcInspectionSheetCubit>();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        children: [
          TextButton.icon(
            onPressed: () =>
                cubit.raiseNc(item: row.item, description: row.item.label),
            icon: const Icon(Icons.report_gmailerrorred, size: 18),
            label: Text(AppText.t('رفع عدم مطابقة', 'Raise NC')),
          ),
        ],
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  const _ChoiceButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
    this.compact = false,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? color.withValues(alpha: 0.14) : AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8.w : 12.w,
            vertical: 10.h,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
              color: selected ? color : AppColors.border,
              width: selected ? 1.6 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 18.r,
                color: selected ? color : AppColors.textMuted,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: selected ? color : AppColors.textMuted,
                    fontSize: 12.spMax,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The persistent submit bar: progress and the one button that commits the
/// sheet, so it is reachable without scrolling a long checklist back up.
class _SubmitBar extends StatelessWidget {
  const _SubmitBar({required this.state});

  final QcInspectionSheetState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcInspectionSheetCubit>();
    final progress = state.progress;
    if (!state.isEditable) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Text(
            state.inspection!.isSubmitted
                ? AppText.t('تم الإرسال للمراجعة', 'Submitted for review')
                : AppText.t('هذا الفحص مقفل', 'This sheet is locked'),
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
        ),
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final advisory in progress.advisories)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: AppColors.danger,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        advisory,
                        style: TextStyle(
                          color: AppColors.danger,
                          fontSize: 11.spMax,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            FilledButton.icon(
              onPressed: state.submitting ? null : () => cubit.submit(),
              icon: state.submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: Text(
                progress.canSubmit
                    ? AppText.t('إرسال للمراجعة', 'Submit for review')
                    : AppText.t(
                        'متبقٍ ${progress.blocking + progress.missingEvidence}',
                        '${progress.blocking + progress.missingEvidence} outstanding',
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
