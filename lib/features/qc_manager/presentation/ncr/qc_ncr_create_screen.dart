import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_adaptive_list.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_date_field.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../di/service_locator.dart';
import '../cubit/qc_ncr_cubit.dart';
import '../../domain/ncr_report_repository.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_inspection.dart';
import '../../domain/qc_nc_capa.dart';
import '../../domain/qc_repositories.dart';
import '../../../../design_system/widgets/app_select_field.dart';

/// Raised standalone: the code uses 0 as "no inspection context" and the
/// write path turns that into a NULL `inspection_id` (a NULL child key is
/// what actually satisfies the FK to qc_inspections). The NCR report treats
/// the NULL family as reportable on its own account - see `ncr_report_repo`.
const _standaloneInspectionId = 0;

/// The create/edit non-conformance form.
///
/// Same window/route split as every QC editor: a unified [AppWindow] on
/// desktop (the window's ✕ dismisses it, no back stack) and a full-screen
/// pushed route on phones where the system back affordance is the natural
/// dismiss. The write goes through the domain [QcNcCapaRepository] facade,
/// which carries the §A9.4 write guard and the audit trail; this layer only
/// validates what the user actually typed.
class QcNcrCreateScreen extends StatefulWidget {
  const QcNcrCreateScreen({super.key, this.assignees = const [], this.finding});

  /// The assignee roster the dashboard already fetched (`id`/`name` pairs).
  /// Passing it in keeps the form from re-querying a members list it does
  /// not otherwise need.
  final List<({String id, String name})> assignees;

  /// The finding under edit. `null` keeps the form in create mode; a value
  /// prefills every field and routes the write through `saveFinding`, which
  /// never rewrites the creation facts nor the CAPA link.
  final QcFindingNc? finding;

  /// The assignee roster in edit mode when the caller had none: the same
  /// facet pass the filter drawer uses, so the picker shows real names.
  static Future<List<({String id, String name})>> _fetchRoster() async {
    final options = await getIt<QcNcReportRepository>().filterOptions();
    return options.assignees;
  }

  /// Opens the editor: the caller's [QcNcrCubit] refetches when a finding
  /// was written (`true` result), so the cards and the register show it
  /// immediately on whichever surface hosts the button.
  static Future<void> open(
    BuildContext context,
    QcNcrCubit cubit, {
    List<({String id, String name})> assignees = const [],
    QcFindingNc? finding,
  }) {
    final editing = finding != null;
    final title = editing
        ? AppText.t('تعديل عدم مطابقة', 'Edit non-conformance')
        : AppText.t('إنشاء عدم مطابقة', 'New non-conformance');
    final subtitle = editing
        ? AppText.t(
            'حدّث الوصف أو التصنيف أو المسؤول',
            'Update the description, classification or assignee',
          )
        : AppText.t(
            'مرتبطة بتفتيش أو مستقلة عنه',
            'Linked to an inspection, or standalone',
          );
    Future<bool?> action;
    if (!supportsDataTable) {
      action = Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) {
            return Scaffold(
              appBar: AppTopAppBar(title: title),
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.pageMobile),
                  child: QcNcrCreateScreen(
                    assignees: assignees,
                    finding: finding,
                  ),
                ),
              ),
            );
          },
        ),
      );
    } else {
      action = showAppWindow<bool>(
        context,
        title: title,
        subtitle: subtitle,
        icon: editing ? Icons.edit_outlined : Icons.flag_outlined,
        maxWidth: 720,
        child: QcNcrCreateScreen(assignees: assignees, finding: finding),
      );
    }
    return action.then((saved) {
      if (saved == true) cubit.load();
    });
  }

  @override
  State<QcNcrCreateScreen> createState() => _QcNcrCreateScreenState();
}

class _QcNcrCreateScreenState extends State<QcNcrCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _category = TextEditingController();
  final _proposedAction = TextEditingController();
  final _qty = TextEditingController();
  final _unit = TextEditingController();
  final _due = TextEditingController();

  List<QcDefectCode> _defects = const [];
  List<QcInspection> _inspections = const [];
  List<({String id, String name})> _roster = const [];
  QcDefectCode? _defect;
  QcInspection? _inspection;

  /// True once the user touched the inspection link - until then an edit
  /// keeps whatever inspection the finding was raised against, even when
  /// that inspection is older than the newest-50 picker window.
  bool _inspectionChanged = false;

  /// True once the user touched the defect pick - until then an edit keeps
  /// the finding's stored code even when the code list cannot offer it.
  bool _defectChanged = false;
  String _type = NcType.nonConformance;
  String _severity = NcSeverity.minor;
  String _disposition = NcDisposition.pending;
  ({String id, String name})? _assignee;
  bool _loading = true;
  bool _saving = false;

  QcFindingNc? get _base => widget.finding;
  bool get _editing => widget.finding != null;

  @override
  void initState() {
    super.initState();
    // Seeded here rather than at declaration: the dropdown asserts the
    // initial value is one of its items, so the roster must be live from
    // the first build, before the bootstrap round-trip returns.
    _roster = widget.assignees;
    final base = _base;
    if (base != null) {
      _description.text = base.description;
      _category.text = base.category;
      _proposedAction.text = base.proposedAction;
      final qty = base.qtyAffected;
      if (qty != null) {
        _qty.text = qty == qty.roundToDouble() && qty.abs() < 1e15
            ? qty.truncate().toString()
            : '$qty';
      }
      _unit.text = base.qtyUnit;
      _due.text = base.dueDate;
      _type = NcType.normalize(base.type);
      _severity = NcSeverity.normalize(base.severity);
      _disposition = NcDisposition.normalize(base.disposition);
      _assignee = switch (base.assignedTo) {
        '' => null,
        _ => (id: base.assignedTo, name: base.assignedToName),
      };
    }
    _bootstrap();
  }

  @override
  void dispose() {
    _description.dispose();
    _category.dispose();
    _proposedAction.dispose();
    _qty.dispose();
    _unit.dispose();
    _due.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    // Both pickers are catalogues, not filters: the newest 50 inspections
    // cover the working set, and a failure in either degrades to the manual
    // entry path rather than blocking the whole form.
    final base = _base;
    final capa = getIt<QcNcCapaRepository>();
    final inspections = getIt<QcInspectionRepository>();
    try {
      final results = await Future.wait<Object?>([
        capa.listDefectCodes(),
        inspections.listInspections(limit: 50),
      ]);
      if (!mounted) return;
      final defects = results[0] as List<QcDefectCode>;
      final insps = results[1] as List<QcInspection>;
      // In edit mode opened from the detail screen there is no roster: the
      // facet pass the filter drawer already runs is the cheapest source.
      // A failure here only empties the picker; the stored assignee still
      // keeps their human name (below), so it must not sink the catalogue
      // pull with it.
      var roster = widget.assignees;
      if (base != null && roster.isEmpty) {
        try {
          roster = await QcNcrCreateScreen._fetchRoster();
          if (!mounted) return;
        } on Object {
          // The roster is best-effort; the stored assignee (below) keeps
          // their name even without it.
        }
      }
      final defect = _resolveDefect(base?.code, defects);
      final inspection = _resolveInspection(base?.inspectionId, insps);
      var people = roster;
      if (_resolveAssignee(base, people) case final picked?
          when people.every((p) => p.id != picked.id)) {
        // An assignee the roster does not know still shows their human name
        // rather than a raw record dump in the picker's value line.
        people = [...people, picked];
      }
      setState(() {
        _defects = defects;
        _inspections = insps;
        _roster = people;
        _defect = defect;
        _inspection = inspection;
        _assignee = _resolveAssignee(base, people);
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      AppFeedback.errorFrom(context, e);
    }
  }

  QcDefectCode? _resolveDefect(String? code, List<QcDefectCode> defects) {
    if (code == null || code.isEmpty) return null;
    for (final d in defects) {
      if (d.code == code) return d;
    }
    return null;
  }

  QcInspection? _resolveInspection(int? id, List<QcInspection> insps) {
    if (id == null || id == 0) return null;
    for (final i in insps) {
      if (i.inspectionId == id) return i;
    }
    return null;
  }

  /// The edit prefill keeps the finding's current assignee even when the
  /// roster has not loaded or no longer lists them; create mode keeps
  /// whatever was picked.
  ({String id, String name})? _resolveAssignee(
    QcFindingNc? base,
    List<({String id, String name})> roster,
  ) {
    if (base == null) return null;
    if (base.assignedTo.isEmpty) return null;
    for (final a in roster) {
      if (a.id == base.assignedTo) return a;
    }
    return (id: base.assignedTo, name: base.assignedToName);
  }

  String _nextStatus(String previous, ({String id, String name})? assignee) {
    final nowAssigned = (assignee?.id ?? '').isNotEmpty;
    if (nowAssigned && previous == NcStatus.open) return NcStatus.assigned;
    if (!nowAssigned && previous == NcStatus.assigned) return NcStatus.open;
    return previous;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final session = getIt<AuthGate>().session;
    final base = _base;
    final assignee = _assignee;
    final due = _due.text.trim();
    final dueDate = due.length >= 10 ? due.substring(0, 10) : due;
    final qty = _qty.text.trim().isEmpty
        ? null
        : num.tryParse(_qty.text.trim().replaceAll(',', ''))?.toDouble();
    final finding = base == null
        ? QcFindingNc(
            inspectionId: _inspection?.inspectionId ?? _standaloneInspectionId,
            code: _defect?.code ?? '',
            type: _type,
            severity: _severity,
            category: _category.text.trim(),
            description: _description.text.trim(),
            status: assignee == null ? NcStatus.open : NcStatus.assigned,
            dueDate: dueDate,
            assignedTo: assignee?.id ?? '',
            assignedToName: assignee?.name ?? '',
            assignedAt: assignee == null ? '' : nowIso(),
            proposedAction: _proposedAction.text.trim(),
            qtyAffected: qty,
            qtyUnit: _unit.text.trim(),
            disposition: _disposition,
            // The local insert requires the stamps; the audit trail records the
            // actor independently from the live session at write time.
            createdAt: nowIso(),
            updatedAt: nowIso(),
            createdBy: session.uid,
            updatedBy: session.uid,
          )
        : QcFindingNc(
            findingId: base.findingId,
            inspectionId:
                _inspection?.inspectionId ??
                (_inspectionChanged
                    ? _standaloneInspectionId
                    : base.inspectionId),
            itemId: base.itemId,
            respId: base.respId,
            code: _defect?.code ?? (_defectChanged ? '' : base.code),
            type: _type,
            severity: _severity,
            category: _category.text.trim(),
            description: _description.text.trim(),
            status: _nextStatus(base.status, assignee),
            dueDate: dueDate,
            assignedTo: assignee?.id ?? '',
            assignedToName: assignee?.name ?? '',
            assignedAt:
                (assignee?.id ?? '') != base.assignedTo && assignee != null
                ? nowIso()
                : base.assignedAt,
            rootCause: base.rootCause,
            actionPlan: base.actionPlan,
            proposedAction: _proposedAction.text.trim(),
            qtyAffected: qty,
            qtyUnit: _unit.text.trim(),
            disposition: _disposition,
            // Lifecycle stamps and the CAPA link are creation-level facts the
            // edit form does not touch; `saveFinding` freezes them anyway.
            verifiedBy: base.verifiedBy,
            verifiedByName: base.verifiedByName,
            verifiedAt: base.verifiedAt,
            closedAt: base.closedAt,
            closedBy: base.closedBy,
            rejectedAt: base.rejectedAt,
            rejectionReason: base.rejectionReason,
            evidenceJson: base.evidenceJson,
            capaId: base.capaId,
            createdAt: base.createdAt,
            createdBy: base.createdBy,
            updatedAt: nowIso(),
            updatedBy: session.uid,
          );
    setState(() => _saving = true);
    try {
      if (base == null) {
        await getIt<QcNcCapaRepository>().createFinding(finding);
      } else {
        await getIt<QcNcCapaRepository>().saveFinding(finding);
      }
      if (!mounted) return;
      AppFeedback.success(
        context,
        base == null
            ? AppText.t(
                'تم إنشاء حالة عدم المطابقة.',
                'Non-conformance created.',
              )
            : AppText.t(
                'تم تحديث حالة عدم المطابقة.',
                'Non-conformance updated.',
              ),
      );
      Navigator.of(context).pop(true);
    } on AppError catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.error(context, e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) ...[
            const LinearProgressIndicator(minHeight: 2),
            const SizedBox(height: AppSpacing.lg),
          ],
          _SectionTitle(AppText.t('نوع الحالة', 'Classification')),
          LayoutBuilder(
            builder: (context, constraints) {
              return Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.md,
                children: [
                  SizedBox(
                    width: _colWidth(constraints.maxWidth, 3, 2),
                    child: _DropdownTile(
                      label: AppText.t(
                        'رمز العيب (اختياري)',
                        'Defect code (optional)',
                      ),
                      hint: _defects.isEmpty
                          ? AppText.t(
                              'لا توجد رموز معرفة',
                              'No defect codes defined',
                            )
                          : null,
                      enabled: !_saving && !_loading && _defects.isNotEmpty,
                      value: _defect,
                      items: [
                        for (final d in _defects)
                          (item: d, label: '${d.code} — ${d.name}'),
                      ],
                      onChanged: _pickDefect,
                      clearable: true,
                    ),
                  ),
                  SizedBox(
                    width: _colWidth(constraints.maxWidth, 3, 2),
                    child: _DropdownTile(
                      label: AppText.t(
                        'التفتيش المرتبط (اختياري)',
                        'Inspection link (optional)',
                      ),
                      hint: _inspections.isEmpty
                          ? AppText.t(
                              'لا توجد عمليات تفتيش',
                              'No inspections yet',
                            )
                          : AppText.t(
                              'اتركه فارغاً لحالة مستقلة',
                              'Leave empty for a standalone finding',
                            ),
                      enabled: !_saving && !_loading && _inspections.isNotEmpty,
                      value: _inspection,
                      items: [
                        for (final i in _inspections)
                          (item: i, label: _inspectionLabel(i)),
                      ],
                      onChanged: (v) => setState(() {
                        _inspection = v;
                        _inspectionChanged = true;
                      }),
                      clearable: true,
                    ),
                  ),
                  SizedBox(
                    width: _colWidth(constraints.maxWidth, 3, 2),
                    child: _DropdownTile(
                      label: AppText.t('النوع', 'Type'),
                      value: _type,
                      items: [
                        for (final t in NcType.all)
                          (item: t, label: _typeLabel(t)),
                      ],
                      onChanged: (v) => setState(() => _type = v),
                    ),
                  ),
                  SizedBox(
                    width: _colWidth(constraints.maxWidth, 3, 2),
                    child: _DropdownTile(
                      label: AppText.t('الخطورة', 'Severity'),
                      value: _severity,
                      items: [
                        for (final s in NcSeverity.all)
                          (item: s, label: _severityLabel(s)),
                      ],
                      onChanged: (v) => setState(() => _severity = v),
                    ),
                  ),
                  SizedBox(
                    width: _colWidth(constraints.maxWidth, 3, 2),
                    child: _DropdownTile(
                      label: AppText.t('المصير', 'Disposition'),
                      value: _disposition,
                      items: [
                        for (final d in NcDisposition.all)
                          (item: d, label: _dispositionLabel(d)),
                      ],
                      onChanged: (v) => setState(() => _disposition = v),
                    ),
                  ),
                  SizedBox(
                    width: _colWidth(constraints.maxWidth, 3, 2),
                    child: _DropdownTile(
                      label: AppText.t(
                        'المسند إلى (اختياري)',
                        'Assign to (optional)',
                      ),
                      // Only a value the item list can back: before the
                      // bootstrap lands the roster is still empty and the
                      // dropdown asserts its initial value is among items.
                      value: _roster.any((a) => a == _assignee)
                          ? _assignee
                          : null,
                      enabled: !_saving,
                      hint: _roster.isEmpty
                          ? AppText.t(
                              'لا يتوفر مسندوون',
                              'No assignees available',
                            )
                          : null,
                      items: [
                        for (final a in _roster)
                          (item: a, label: a.name.isEmpty ? a.id : a.name),
                      ],
                      onChanged: (v) => setState(() => _assignee = v),
                      clearable: true,
                    ),
                  ),
                ],
              );
            },
          ),
          _SectionTitle(AppText.t('وصف الحالة', 'The finding')),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoColumns = constraints.maxWidth >= 430;
              final itemWidth = twoColumns
                  ? (constraints.maxWidth - AppSpacing.md) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.md,
                children: [
                  SizedBox(
                    width: itemWidth,
                    child: AppField(
                      label: AppText.t('الوصف', 'Description'),
                      controller: _description,
                      maxLines: 3,
                      enabled: !_saving,
                      textInputAction: TextInputAction.next,
                      hint: AppText.t(
                        'ما الذي لا يطابق المواصفة؟',
                        'What does not conform?',
                      ),
                      validator: (v) => (v ?? '').trim().isEmpty
                          ? AppText.t(
                              'الوصف مطلوب',
                              'A description is required',
                            )
                          : null,
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: AppField(
                      label: AppText.t(
                        'التصنيف (اختياري)',
                        'Category (optional)',
                      ),
                      controller: _category,
                      enabled: !_saving,
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: AppField(
                      label: AppText.t(
                        'الكمية المتأثرة (اختياري)',
                        'Affected qty (optional)',
                      ),
                      controller: _qty,
                      enabled: !_saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,\-]')),
                      ],
                      hint: '0.00',
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: AppField(
                      label: AppText.t('الوحدة (اختياري)', 'Unit (optional)'),
                      controller: _unit,
                      enabled: !_saving,
                      hint: AppText.t('كجم، قطعة...', 'kg, pcs...'),
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: AppDateField(
                      label: AppText.t(
                        'تاريخ الاستحقاق (اختياري)',
                        'Due date (optional)',
                      ),
                      controller: _due,
                      enabled: !_saving,
                    ),
                  ),
                  SizedBox(
                    width: itemWidth,
                    child: AppField(
                      label: AppText.t(
                        'الإجراء المقترح (اختياري)',
                        'Proposed action (optional)',
                      ),
                      controller: _proposedAction,
                      enabled: !_saving,
                      maxLines: 2,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: _editing
                      ? AppText.t('حفظ', 'Save')
                      : AppText.t('إنشاء', 'Create'),
                  icon: _editing
                      ? Icon(Icons.save_outlined, size: 18.r)
                      : Icon(Icons.flag, size: 18.r),
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
      ),
    );
  }

  /// One column of [perRow] on a wide body, one of [onNarrow] when the
  /// space can no longer fit three pickers side by side.
  double _colWidth(double width, int perRow, int onNarrow) {
    final cols = width >= 560 ? perRow : onNarrow;
    return (width - AppSpacing.md * (cols - 1)) / cols;
  }

  void _pickDefect(QcDefectCode? code) {
    setState(() {
      _defect = code;
      _defectChanged = true;
      if (code != null) {
        _severity = code.severity;
        _type = code.defaultType;
        if (code.category.trim().isNotEmpty) _category.text = code.category;
        if (code.suggestedCapa.trim().isNotEmpty) {
          _proposedAction.text = code.suggestedCapa;
        }
      }
    });
  }

  String _inspectionLabel(QcInspection i) {
    final ref = [
      i.refType,
      i.refId,
    ].where((s) => s.trim().isNotEmpty).join(' ');
    final lot = i.lotNo.trim();
    final batch = i.batchNo.trim();
    final tail = [lot, batch].where((s) => s.isNotEmpty).join(' · ');
    final day = i.inspectionDate.length >= 10
        ? i.inspectionDate.substring(0, 10)
        : i.inspectionDate;
    final out = tail.isEmpty ? ref : (ref.isEmpty ? tail : '$ref · $tail');
    return day.isEmpty ? out : (out.isEmpty ? day : '$out ($day)');
  }

  String _typeLabel(String v) => switch (v) {
    NcType.nonConformance => AppText.t('عدم مطابقة', 'Non-conformance'),
    NcType.observation => AppText.t('ملاحظة', 'Observation'),
    NcType.deviation => AppText.t('انحراف معتمد', 'Deviation'),
    _ => v,
  };

  String _severityLabel(String v) => switch (v) {
    NcSeverity.minor => AppText.t('بسيطة', 'Minor'),
    NcSeverity.major => AppText.t('كبرى', 'Major'),
    NcSeverity.critical => AppText.t('حرجة', 'Critical'),
    _ => v,
  };

  String _dispositionLabel(String v) => switch (v) {
    NcDisposition.rework => AppText.t('إعادة تشغيل', 'Rework'),
    NcDisposition.scrap => AppText.t('إتلاف', 'Scrap'),
    NcDisposition.useAsIs => AppText.t('استخدام كما هو', 'Use as is'),
    NcDisposition.returnToSupplier => AppText.t('إرجاع', 'Return'),
    NcDisposition.concession => AppText.t('تنازل', 'Concession'),
    NcDisposition.pending => AppText.t('مؤجل', 'Pending'),
    _ => v,
  };
}

/// The AppField look (label above a dense outlined input) for a
/// [DropdownButtonFormField], because [AppField] is strictly a text field.
/// The value cleared out of a "clearable" tile falls back to its hint.
class _DropdownTile<T extends Object?> extends StatelessWidget {
  const _DropdownTile({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
    this.hint,
    this.clearable = false,
  });

  final String label;
  final T? value;

  /// `(item, label)` pairs — records keep the dropdown's display text and
  /// its typed value together without a parallel list.
  final List<({T item, String label})> items;
  final ValueChanged<T> onChanged;
  final bool enabled;
  final String? hint;

  /// Adds an empty entry so "no defect code" and "not linked to an
  /// inspection" can be un-picked.
  final bool clearable;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
        const SizedBox(height: AppSpacing.xs),
        AppSelectField<T>(
          initialValue: value,
          isExpanded: true,
          decoration: InputDecoration(enabled: enabled, hintText: hint),
          items: [
            for (final entry in items)
              DropdownMenuItem<T>(value: entry.item, child: Text(entry.label)),
            if (clearable) DropdownMenuItem<T>(child: const Text('')),
          ],
          onChanged: enabled ? (v) => onChanged(v as T) : null,
        ),
      ],
    );
  }
}

/// Section heading inside the form.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md, bottom: AppSpacing.sm),
      child: Text(label, style: Theme.of(context).textTheme.titleSmall),
    );
  }
}
