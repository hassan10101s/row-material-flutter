import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../design_system/animations/app_animations.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../cubit/daily_tasks_cubit.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../sections/daily_tasks_card.dart';
import '../sections/decisions_overview_card.dart';
import '../sections/qc_quick_card.dart';

/// Bento command-center band: QC quick card, daily tasks and the decisions
/// overview share one responsive group (3-up on desktop, 2-up with a
/// full-width decisions card on medium, stacked on compact). Cards stretch
/// to equal heights on row layouts so the band reads as a single tile group.
class DashboardBentoBand extends StatelessWidget {
  final DashboardKpisState kpi;
  final Map<String, dynamic> summary;

  const DashboardBentoBand({
    super.key,
    required this.kpi,
    required this.summary,
  });

  @override
  Widget build(BuildContext context) {
    // The daily-tasks card hides itself when there are no published periodic
    // lists — but inside `Expanded` a hidden child still claims its share of
    // the desktop row, leaving a big hole between QC and decisions. Drop it
    // from the layout entirely instead (plan §6 cleanup).
    final showDaily = context.watch<DailyTasksCubit>().state.hasTasks;
    final qc = AppEntrance(
      delay: const Duration(milliseconds: 40),
      child: RepaintBoundary(child: QcQuickCard(kpi: kpi)),
    );
    final daily = AppEntrance(
      delay: const Duration(milliseconds: 80),
      child: RepaintBoundary(child: const DailyTasksCard()),
    );
    final decisions = AppEntrance(
      delay: const Duration(milliseconds: 120),
      child: RepaintBoundary(child: DecisionsOverviewCard(summary: summary)),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (width >= AppBreakpoints.expanded) {
          if (showDaily) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: AppSpacing.md,
                children: [
                  Expanded(child: qc),
                  Expanded(child: daily),
                  Expanded(child: decisions),
                ],
              ),
            );
          }
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: AppSpacing.md,
              children: [
                Expanded(child: qc),
                Expanded(child: decisions),
              ],
            ),
          );
        }
        if (width >= AppBreakpoints.medium) {
          if (showDaily) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: AppSpacing.md,
                    children: [
                      Expanded(child: qc),
                      Expanded(child: daily),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                decisions,
              ],
            );
          }
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: AppSpacing.md,
              children: [
                Expanded(child: qc),
                Expanded(child: decisions),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            qc,
            if (showDaily) ...[const SizedBox(height: AppSpacing.md), daily],
            const SizedBox(height: AppSpacing.md),
            decisions,
          ],
        );
      },
    );
  }
}
