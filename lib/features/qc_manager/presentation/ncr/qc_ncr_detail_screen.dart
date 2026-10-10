import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../domain/ncr_report_row.dart';
import '../cubit/qc_ncr_cubit.dart';
import '../widgets/ncr_pill.dart';

/// One finding with its inspection context and CAPA timeline
/// (plan V6_ENHANCED §22.6).
class QcNcrDetailScreen extends StatefulWidget {
  const QcNcrDetailScreen({super.key, this.cubit, this.findingId});

  /// Optional so the same widget works under a `BlocProvider` (the router,
  /// which then owns and closes the cubit) and standalone (tests, previews).
  final QcNcrCubit? cubit;

  /// Optional when the caller has already selected the finding.
  final int? findingId;

  @override
  State<QcNcrDetailScreen> createState() => _QcNcrDetailScreenState();
}

class _QcNcrDetailScreenState extends State<QcNcrDetailScreen> {
  QcNcrCubit? _cubit;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolved here rather than in initState because `context.read` is not
    // legal before the element is mounted.
    final cubit = widget.cubit ?? context.read<QcNcrCubit>();
    if (identical(cubit, _cubit)) return;
    _cubit = cubit;
    final id = widget.findingId ?? cubit.state.selectedFindingId;
    if (id != null) cubit.selectFinding(id);
  }

  @override
  Widget build(BuildContext context) {
    final cubit = _cubit ?? (widget.cubit ?? context.read<QcNcrCubit>());
    return BlocBuilder<QcNcrCubit, QcNcrState>(
      bloc: cubit,
      builder: (context, state) {
        return Scaffold(
          appBar: AppTopAppBar(
            title: state.detail == null
                ? AppText.t('تفاصيل الحالة', 'Finding detail')
                : state.detail!.reference,
          ),
          body: switch ((
            state.detailLoading,
            state.detailError,
            state.detail,
          )) {
            (true, _, _) => const Center(child: CircularProgressIndicator()),
            (_, final String error, _) => AppEmptyState(
              icon: Icons.error_outline,
              title: AppText.t('تعذر فتح الحالة', 'Finding unavailable'),
              subtitle: error,
            ),
            (_, _, null) => AppEmptyState(
              icon: Icons.search_off,
              title: AppText.t('لم يتم اختيار حالة', 'No finding selected'),
            ),
            _ => _Body(row: state.detail!),
          },
        );
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.row});

  final NcrReportRow row;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        _Header(row: row),
        const SizedBox(height: AppSpacing.md),
        _Section(
          title: AppText.t('الحالة', 'Finding'),
          icon: Icons.report_outlined,
          children: [
            _Field(label: AppText.t('المرجع', 'Ref'), value: row.reference),
            _Field(
              label: AppText.t('الوصف', 'Description'),
              value: row.description,
            ),
            _Field(label: AppText.t('النوع', 'Type'), value: row.type),
            _Field(
              label: AppText.t('التصنيف', 'Category'),
              value: row.category,
            ),
            _Field(
              label: AppText.t('الخطورة', 'Severity'),
              badge: ncrSeverityPill(row.severity),
            ),
            _Field(
              label: AppText.t('الحالة', 'Status'),
              badge: ncrStatePill(row.status),
            ),
            _Field(
              label: AppText.t('الكمية المتأثرة', 'Affected qty'),
              value: _qty(row),
            ),
            _Field(
              label: AppText.t('المصير', 'Disposition'),
              value: row.disposition,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _Section(
          title: AppText.t('سياق التفتيش', 'Inspection context'),
          icon: Icons.fact_check_outlined,
          children: [
            _Field(
              label: AppText.t('الرقم المرجعي', 'Reference'),
              value: row.inspectionRefId,
            ),
            _Field(
              label: AppText.t('نوع المرجع', 'Ref type'),
              value: row.inspectionRefType,
            ),
            _Field(label: AppText.t('المخزون', 'Lot'), value: row.lotNo),
            _Field(label: AppText.t('التشغيلة', 'Batch'), value: row.batchNo),
            _Field(label: AppText.t('أمر الشراء', 'PO'), value: row.poNo),
            _Field(label: AppText.t('القسم', 'Department'), value: row.dept),
            _Field(label: AppText.t('الموقع', 'Location'), value: row.location),
            _Field(label: AppText.t('الخط', 'Line'), value: row.line),
            _Field(
              label: AppText.t('المفتش', 'Inspector'),
              value: row.inspectorName,
            ),
            _Field(
              label: AppText.t('تاريخ التفتيش', 'Inspection date'),
              value: row.inspectionDate,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _Timeline(row: row),
        const SizedBox(height: AppSpacing.md),
        if (row.hasCapa)
          _Section(
            title: AppText.t('الإجراء التصحيحي', 'Corrective action'),
            icon: Icons.build_outlined,
            children: [
              _Field(label: AppText.t('الرقم', 'CAPA no'), value: row.capaNo),
              _Field(label: AppText.t('النوع', 'Type'), value: row.capaType),
              _Field(
                label: AppText.t('الحالة', 'Status'),
                badge: ncrCapaPill(row.capaStatus),
              ),
              _Field(
                label: AppText.t('الأولوية', 'Priority'),
                value: row.capaPriority,
              ),
              _Field(
                label: AppText.t('المسند', 'Assigned to'),
                value: row.capaAssignedToName,
              ),
              _Field(
                label: AppText.t('تاريخ الاستحقاق', 'Due'),
                value: row.capaDueAt,
                highlightOverdue:
                    row.capaDueAt.isNotEmpty && row.capaIsOverdueToday,
              ),
              _Field(
                label: AppText.t('مستهدف الإنجاز', 'Target completion'),
                value: row.capaTargetCompletionAt,
              ),
              _Field(
                label: AppText.t('اكتمل التنفيذ', 'Action completed'),
                value: row.capaActionCompletedAt,
              ),
              _Field(
                label: AppText.t('تم التحقق', 'Verified'),
                value: row.capaVerifiedAt,
              ),
              _Field(
                label: AppText.t('الفعالية', 'Effectiveness'),
                value: row.capaIsEffective
                    ? AppText.t('فعّال', 'Effective')
                    : AppText.t('لم تُثبت', 'Not established'),
              ),
            ],
          ),
        if (row.rootCause.isNotEmpty || row.actionPlan.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          _Section(
            title: AppText.t('التحليل والإجراء', 'Analysis and action'),
            icon: Icons.biotech_outlined,
            children: [
              if (row.rootCause.isNotEmpty)
                _Field(
                  label: AppText.t('السبب الجذري', 'Root cause'),
                  value: row.rootCause,
                ),
              if (row.actionPlan.isNotEmpty)
                _Field(
                  label: AppText.t('خطة الإجراء', 'Action plan'),
                  value: row.actionPlan,
                ),
            ],
          ),
        ],
      ],
    );
  }

  static String _qty(NcrReportRow row) {
    final qty = row.qtyAffected;
    if (qty == null || qty < 0) return '—';
    return row.qtyUnit.isEmpty ? '$qty' : '$qty ${row.qtyUnit}';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.row});

  final NcrReportRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ncrSeverityPill(row.severity),
              const SizedBox(width: AppSpacing.sm),
              ncrStatePill(row.status),
              const Spacer(),
              if (row.isOverdue)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    AppText.t('متأخرة', 'Overdue'),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: AppColors.danger,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(row.description, style: theme.textTheme.titleMedium),
          if (row.dueDate.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              AppText.t(
                'الاستحقاق ${row.dueDate} · الفتح ${row.createdAt.substring(0, 10)}',
                'Due ${row.dueDate} · raised ${row.createdAt.substring(0, 10)}',
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The finding's history as an ordered list of the stamps that actually exist.
///
/// A finding closed before it was raised, or verified after it was closed, still
/// renders - the order is derived from the data, so an inconsistent history
/// shows up as an odd sequence rather than being silently reordered into
/// something plausible.
class _Timeline extends StatelessWidget {
  const _Timeline({required this.row});

  final NcrReportRow row;

  @override
  Widget build(BuildContext context) {
    final steps = <({String label, String at, String who})>[
      (
        label: AppText.t('فُتحت', 'Raised'),
        at: row.createdAt,
        who: row.createdBy,
      ),
      if (row.assignedAt.isNotEmpty)
        (
          label: AppText.t('أُسندت', 'Assigned'),
          at: row.assignedAt,
          who: row.assignedToName,
        ),
      if (row.verifiedAt.isNotEmpty)
        (
          label: AppText.t('تم التحقق', 'Verified'),
          at: row.verifiedAt,
          who: row.verifiedByName,
        ),
      if (row.closedAt.isNotEmpty)
        (
          label: AppText.t('أُغلقت', 'Closed'),
          at: row.closedAt,
          who: row.verifiedByName,
        ),
      if (row.rejectedAt.isNotEmpty)
        (label: AppText.t('رُفضت', 'Rejected'), at: row.rejectedAt, who: ''),
    ];

    return _Section(
      title: AppText.t('المسار الزمني', 'Timeline'),
      icon: Icons.timeline,
      children: [
        if (steps.isEmpty)
          Text(
            AppText.t('لا توجد أحداث مسجلة', 'No events recorded'),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          )
        else
          for (final step in steps) _TimelineStep(step: step),
      ],
    );
  }
}

class _TimelineStep extends StatelessWidget {
  const _TimelineStep({required this.step});

  final ({String label, String at, String who}) step;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: Icon(Icons.circle, size: 8),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(step.label),
                Text(
                  step.who.isEmpty ? step.at : '${step.at} · ${step.who}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: AppColors.primary),
              const SizedBox(width: AppSpacing.xs),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          ...children,
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    this.value = '',
    this.badge,
    this.highlightOverdue = false,
  });

  final String label;
  final String value;

  /// Rendered instead of [value] for fields whose value is a state, not text.
  final Widget? badge;

  final bool highlightOverdue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child:
                badge ??
                (highlightOverdue
                    ? Text(
                        value,
                        style: TextStyle(
                          color: AppColors.danger,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : Text(value.isEmpty ? '—' : value)),
          ),
        ],
      ),
    );
  }
}
