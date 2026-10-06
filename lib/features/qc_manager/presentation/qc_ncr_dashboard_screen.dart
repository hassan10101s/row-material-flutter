import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/ncr_kpis.dart';
import 'cubit/qc_ncr_cubit.dart';

/// NCR dashboard (plan V6_ENHANCED §22.6).
///
/// Four cards - Open / Overdue / Critical / On-Time% - over the currently
/// filtered population, then the aging bands and the recurring-defect panels.
/// Everything here is a pure function of [QcNcrState], so the cards and the
/// table underneath them can never describe different populations.
class QcNcrDashboardScreen extends StatelessWidget {
  const QcNcrDashboardScreen({super.key, this.cubit, this.onOpenList});

  /// Optional so the same widget works under a `BlocProvider` (the router,
  /// which then owns and closes the cubit) and standalone (tests and previews,
  /// which own it themselves). When omitted it is read from the tree.
  final QcNcrCubit? cubit;

  /// Pushes the table view. Optional so the dashboard is usable standalone.
  final VoidCallback? onOpenList;

  @override
  Widget build(BuildContext context) {
    final cubit = this.cubit ?? context.read<QcNcrCubit>();
    return BlocBuilder<QcNcrCubit, QcNcrState>(
      bloc: cubit,
      builder: (context, state) {
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
          body: state.loading && state.kpis.total == 0
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: cubit.load,
                  child: ListView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    children: [
                      _FilterSummary(state: state, cubit: cubit),
                      const SizedBox(height: AppSpacing.md),
                      _KpiRow(kpis: state.kpis),
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
                ),
        );
      },
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
          TextButton(
            onPressed: cubitClear(context),
            child: Text(AppText.t('مسح', 'Clear')),
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
