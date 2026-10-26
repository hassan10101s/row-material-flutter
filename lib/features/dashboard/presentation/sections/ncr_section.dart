import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../../../../router/app_router.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';

class NcrSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const NcrSection({super.key, required this.kpi});
  String _pct(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}%';
  String _days(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}d';
  @override
  Widget build(BuildContext context) {
    final n = kpi.bundle.ncr;
    // Plan §6 cleanup: hide when always empty.
    if (n.total == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.report_problem_outlined,
          color: AppColors.danger,
          title: AppText.t('المشاكل والحلول', 'Issues & fixes'),
          subtitle: AppText.t('كل الفترات', 'All time'),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('مفتوح', 'Open'),
                    value: '${n.open}',
                    color: AppColors.warning,
                    icon: Icons.folder_open_outlined,
                    hint: '${AppText.t('إجمالي', 'Total')}: ${n.total}',
                    onTap: () =>
                        context.go('${AppRoutes.qcNcrList}?status=Open'),
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متأخر', 'Overdue'),
                    value: '${n.overdue}',
                    color: AppColors.danger,
                    icon: Icons.schedule_outlined,
                    hint: '${n.overduePct.toStringAsFixed(1)}%',
                    onTap: () => context.go('${AppRoutes.qcNcrList}?overdue=1'),
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('حرج', 'Critical'),
                    value: '${n.critical}',
                    color: AppColors.danger,
                    icon: Icons.priority_high,
                    hint: AppText.t(
                      'كبير:${n.major} صغير:${n.minor}',
                      'Major:${n.major} Minor:${n.minor}',
                    ),
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('أُقفل في موعده', 'Closed on time'),
                    value: _pct(n.onTimePct),
                    color: AppColors.success,
                    icon: Icons.event_available_outlined,
                    hint: '${n.closedOnTime}/${n.closed}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متوسط القفل', 'Avg days to close'),
                    value: _days(n.mttcDays),
                    color: AppColors.primary,
                    icon: Icons.timelapse_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متوسط التحقق', 'Avg days to verify'),
                    value: _days(n.mttvDays),
                    color: AppColors.accent,
                    icon: Icons.verified_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('لديه خطة حل', 'With fix plan'),
                    value: '${n.capaCoveragePct.toStringAsFixed(1)}%',
                    color: AppColors.info,
                    icon: Icons.link_outlined,
                    hint: '${n.capaLinked}/${n.total}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('حل متأخر', 'Fix overdue'),
                    value: '${n.capaOverdue}',
                    color: AppColors.danger,
                    icon: Icons.alarm_outlined,
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}
