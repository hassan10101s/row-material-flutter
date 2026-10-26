import '../../../../design_system/widgets/app_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_summary_card.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../di/service_locator.dart';
import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../domain/ncr_kpis.dart';
import '../../domain/ncr_report_row.dart';
import '../cubit/qc_ncr_cubit.dart';
import '../widgets/ncr_pill.dart';
import 'qc_ncr_create_screen.dart';

/// NCR dashboard (plan V6_ENHANCED §22.6).
///
/// Four cards - Open / Overdue / Critical / On-Time% - over the currently
/// filtered population, then the aging bands and the recurring-defect panels.
/// Everything here is a pure function of [QcNcrState], so the cards and the
/// table underneath them can never describe different populations.
class QcNcrDashboardScreen extends StatelessWidget {
  const QcNcrDashboardScreen({
    super.key,
    this.cubit,
    this.onOpenList,
    this.onOpenFinding,
    this.embedded = false,
  });

  /// Optional so the same widget works under a `BlocProvider` (the router,
  /// which then owns and closes the cubit) and standalone (tests and previews,
  /// which own it themselves). When omitted it is read from the tree.
  final QcNcrCubit? cubit;

  /// Pushes the table view. Optional so the dashboard is usable standalone.
  final VoidCallback? onOpenList;

  /// Called with the tapped finding's id so the records below the KPI cards
  /// open the detail screen (where edit/delete live). Optional for tests.
  final void Function(int findingId)? onOpenFinding;

  /// Embedded inside the QC hub tab row: the hub owns the chrome, so this
  /// widget drops the [Scaffold]/app bar and the surrounding padding.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final cubit = this.cubit ?? context.read<QcNcrCubit>();
    return BlocBuilder<QcNcrCubit, QcNcrState>(
      bloc: cubit,
      builder: (context, state) {
        final body = state.loading && state.kpis.total == 0
            ? const AppSkeletonList(rows: 8)
            : RefreshIndicator(
                onRefresh: cubit.load,
                child: ListView(
                  padding: embedded
                      ? const EdgeInsets.all(AppSpacing.md)
                      : const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    _FilterSummary(state: state, cubit: cubit),
                    _CreateActionRow(cubit: cubit),
                    const SizedBox(height: AppSpacing.md),
                    _KpiRow(kpis: state.kpis),
                    const SizedBox(height: AppSpacing.md),
                    _RecordsPanel(
                      rows: state.rows,
                      total: state.total,
                      onOpenFinding: onOpenFinding,
                      onOpenList: onOpenList,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _AgingPanel(buckets: state.aging, total: state.total),
                    const SizedBox(height: AppSpacing.md),
                    _Panels(
                      defects: state.topDefects,
                      repeats: state.repeatRefs,
                      onOpenList: onOpenList,
                    ),
                    if (state.error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      _ErrorNote(message: state.error!),
                    ],
                  ],
                ),
              );
        if (embedded) return body;
        return Scaffold(
          appBar: AppTopAppBar(
            title: AppText.t('تقرير عدم المطابقة', 'Non-conformance report'),
            actions: [
              IconButton(
                tooltip: AppText.t('تحديث', 'Refresh'),
                onPressed: state.loading ? null : cubit.load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: body,
        );
      },
    );
  }
}

/// The create button, tucked under the filter summary. Only whoever holds
/// `qc.write` sees it — the repository re-checks the same permission inside
/// its write transaction, and the reject surfaces as the message there.
/// Desktop opens the unified window; phones push the form as a route with
/// the system Back affordance.
class _CreateActionRow extends StatelessWidget {
  const _CreateActionRow({required this.cubit});

  final QcNcrCubit cubit;

  @override
  Widget build(BuildContext context) {
    bool canCreate;
    try {
      canCreate = getIt<AuthGate>().canWrite(Permission.qcWrite);
    } on Object catch (_) {
      // No live session yet (tests, previews): no button rather than a
      // button that always fails.
      canCreate = false;
    }
    if (!canCreate) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: AppButton(
          small: true,
          label: AppText.t('إنشاء عدم مطابقة', 'New non-conformance'),
          icon: const Icon(Icons.flag_outlined, size: 18),
          onPressed: () => QcNcrCreateScreen.open(
            context,
            cubit,
            assignees: cubit.state.options.assignees,
          ),
        ),
      ),
    );
  }
}

/// The active filter, spelled out. A report that does not say what it is
/// looking at cannot be reconciled with the ledger when the two disagree.
class _FilterSummary extends StatelessWidget {
  const _FilterSummary({required this.state, required this.cubit});

  final QcNcrState state;
  final QcNcrCubit cubit;

  @override
  Widget build(BuildContext context) {
    final text = state.filters.describe;
    return Row(
      children: [
        Icon(Icons.filter_alt_outlined, size: 16, color: AppColors.textMuted),
        const SizedBox(width: AppSpacing.xs),
        Expanded(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (state.hasFilters)
          AppButton(
            onPressed: cubitClear(context),
            label: AppText.t('مسح', 'Clear'),
            style: AppButtonStyle.ghost,
            small: true,
          ),
      ],
    );
  }

  VoidCallback cubitClear(BuildContext context) => cubit.clearFilters;
}

class _KpiRow extends StatelessWidget {
  const _KpiRow({required this.kpis});

  final NcrKpis kpis;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900 ? 4 : 2;
        final width =
            (constraints.maxWidth - AppSpacing.md * (columns - 1)) / columns;
        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            SizedBox(
              width: width,
              child: AppSummaryCard(
                label: AppText.t('مفتوحة', 'Open'),
                value: '${kpis.cardOpen}',
                icon: Icons.pending_actions_outlined,
                color: AppColors.info,
                hint: AppText.t(
                  'لم تُغلق ولم تُرفض',
                  'Neither closed nor rejected',
                ),
              ),
            ),
            SizedBox(
              width: width,
              child: AppSummaryCard(
                label: AppText.t('متأخرة', 'Overdue'),
                value: '${kpis.cardOverdue}',
                icon: Icons.schedule,
                color: AppColors.danger,
                hint: AppText.t(
                  '${kpis.overduePct.toStringAsFixed(0)}% من الإجمالي',
                  '${kpis.overduePct.toStringAsFixed(0)}% of total',
                ),
              ),
            ),
            SizedBox(
              width: width,
              child: AppSummaryCard(
                label: AppText.t('حرجة', 'Critical'),
                value: '${kpis.cardCritical}',
                icon: Icons.report_gmailerrorred_outlined,
                color: AppColors.pdf,
                hint: AppText.t(
                  '${kpis.major} حرجة كبرى · ${kpis.minor} بسيطة',
                  '${kpis.major} major · ${kpis.minor} minor',
                ),
              ),
            ),
            SizedBox(
              width: width,
              child: AppSummaryCard(
                label: AppText.t('إغلاق في الموعد', 'Closed on time'),
                // Null means nothing has been closed in range; printing 0%
                // would read as "every closure we made was late".
                value: kpis.cardOnTimePct == null
                    ? '—'
                    : '${kpis.cardOnTimePct!.toStringAsFixed(0)}%',
                icon: Icons.task_alt,
                color: AppColors.success,
                hint: kpis.mttcDays == null
                    ? AppText.t('لا توجد إغلاقات', 'No closures in range')
                    : AppText.t(
                        'MTTC ${kpis.mttcDays!.toStringAsFixed(1)} يوم',
                        'MTTC ${kpis.mttcDays!.toStringAsFixed(1)} days',
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The findings themselves, directly under the KPI cards: each record with
/// its NCR reference, status and description, tappable into the detail
/// screen (where the edit/delete actions live). The dashboard previously
/// surfaced findings only through the KPI math — the actual records were
/// reachable solely from the repeat panel, which meant a population with no
/// repeats had no visible path to any record. The register's full list stays
/// one "view all" tap away for filters and paging.
class _RecordsPanel extends StatelessWidget {
  const _RecordsPanel({
    required this.rows,
    required this.total,
    this.onOpenFinding,
    this.onOpenList,
  });

  final List<NcrReportRow> rows;
  final int total;
  final void Function(int findingId)? onOpenFinding;
  final VoidCallback? onOpenList;

  static const _preview = 8;

  @override
  Widget build(BuildContext context) {
    final canSeeAll = onOpenList != null && total > _preview;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppText.t('السجلات', 'Records'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '$total',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              const Spacer(),
              if (canSeeAll)
                AppButton(
                  small: true,
                  style: AppButtonStyle.ghost,
                  label: AppText.t('عرض الكل', 'View all'),
                  onPressed: onOpenList,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (rows.isEmpty)
            Text(
              AppText.t('لا توجد سجلات مطابقة', 'No matching records'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            )
          else
            for (final row in rows.take(_preview))
              _RecordTile(
                row: row,
                onTap: onOpenFinding == null
                    ? null
                    : () => onOpenFinding!(row.findingId),
              ),
        ],
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.row, this.onTap});

  final NcrReportRow row;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = row.createdAt.length >= 10
        ? row.createdAt.substring(0, 10)
        : row.createdAt;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      title: Row(
        children: [
          Flexible(
            child: Text(
              row.reference.isNotEmpty
                  ? row.reference
                  : AppText.t('بدون مرجع', 'No reference'),
              style: theme.textTheme.titleSmall?.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          ncrStatePill(row.status),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(row.description, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: AppSpacing.xs),
          Text(
            created,
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}

/// The five aging bands as labelled horizontal bars.
///
/// Bars rather than a pie: the bands are ordered magnitudes, and a reader
/// comparing "15-30 days" against "31-60 days" should compare lengths, not
/// angles.
class _AgingPanel extends StatelessWidget {
  const _AgingPanel({required this.buckets, required this.total});

  final List<NcrAgingBucket> buckets;
  final int total;

  @override
  Widget build(BuildContext context) {
    final bands = buckets.isEmpty ? NcrAgingBucket.bands : buckets;
    final peak = bands.fold<int>(0, (max, b) => b.count > max ? b.count : max);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('أعمار حالات عدم المطابقة', 'Finding aging'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            AppText.t(
              'من تاريخ الفتح حتى الإغلاق، أو حتى اليوم إن كانت ما زالت مفتوحة',
              'From raise to closure, or to today while still open',
            ),
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          if (peak == 0)
            Text(
              AppText.t('لا توجد حالات', 'No findings in range'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            )
          else
            for (final band in bands)
              _AgingBar(band: band, peak: peak, total: total),
        ],
      ),
    );
  }
}

class _AgingBar extends StatelessWidget {
  const _AgingBar({
    required this.band,
    required this.peak,
    required this.total,
  });

  final NcrAgingBucket band;
  final int peak;
  final int total;

  @override
  Widget build(BuildContext context) {
    final pct = total == 0 ? 0.0 : band.count / total * 100;
    // Older bands read hotter, so the eye is drawn to the backlog not the noise.
    final color = switch (band.minDays) {
      >= 60 => AppColors.pdf,
      >= 31 => AppColors.danger,
      >= 15 => AppColors.partial,
      _ => AppColors.info,
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(width: 92.w, child: Text(band.label)),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: band.count / peak,
                    minHeight: 8,
                    backgroundColor: color.withValues(alpha: 0.15),
                    valueColor: AlwaysStoppedAnimation(color),
                  ),
                ),
              ),
              SizedBox(width: AppSpacing.sm),
              SizedBox(
                width: 64.w,
                child: Text(
                  '${band.count} (${pct.toStringAsFixed(0)}%)',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Top recurring defects next to lots that drew more than one NCR.
class _Panels extends StatelessWidget {
  const _Panels({
    required this.defects,
    required this.repeats,
    this.onOpenList,
  });

  final List<NcrTopDefect> defects;
  final List<NcrRepeatRef> repeats;
  final VoidCallback? onOpenList;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 760;
        final defectCard = _DefectPanel(defects: defects);
        final repeatCard = _RepeatPanel(repeats: repeats, onOpen: onOpenList);
        if (stacked) {
          return Column(
            children: [
              defectCard,
              const SizedBox(height: AppSpacing.md),
              repeatCard,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: defectCard),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: repeatCard),
          ],
        );
      },
    );
  }
}

class _DefectPanel extends StatelessWidget {
  const _DefectPanel({required this.defects});

  final List<NcrTopDefect> defects;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('أكثر عيوب تكراراً', 'Top recurring defects'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (defects.isEmpty)
            AppEmptyState(
              icon: Icons.category_outlined,
              title: AppText.t('لا بيانات', 'Nothing to rank'),
            )
          else
            for (final defect in defects)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(defect.label),
                subtitle: defect.category.isEmpty
                    ? null
                    : Text(defect.category),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (defect.criticalCount > 0) ...[
                      Icon(
                        Icons.report_gmailerrorred_outlined,
                        size: 16,
                        color: AppColors.pdf,
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Text('${defect.criticalCount}'),
                      const SizedBox(width: AppSpacing.md),
                    ],
                    Text(
                      '${defect.count}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _RepeatPanel extends StatelessWidget {
  const _RepeatPanel({required this.repeats, this.onOpen});

  final List<NcrRepeatRef> repeats;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('مراجع تكررت فيها حالات', 'References with repeat NCRs'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (repeats.isEmpty)
            AppEmptyState(
              icon: Icons.inbox_outlined,
              title: AppText.t('لا تكرار', 'No repeats'),
              subtitle: AppText.t(
                'كل مرجع سجّل حالة عدم مطابقة واحدة على الأكثر',
                'Every reference drew at most one non-conformance',
              ),
            )
          else
            for (final repeat in repeats)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.repeat, size: 20),
                title: Text(
                  repeat.lotNo.isNotEmpty
                      ? repeat.lotNo
                      : repeat.batchNo.isNotEmpty
                      ? repeat.batchNo
                      : repeat.refId,
                ),
                trailing: Text(
                  '${repeat.count}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                onTap: onOpen,
              ),
        ],
      ),
    );
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      color: AppColors.danger.withValues(alpha: 0.08),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: AppColors.danger),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
