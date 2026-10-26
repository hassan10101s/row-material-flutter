import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../design_system/charts/app_charts.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';
import '../../../../design_system/widgets/app_card.dart';

class VolumeQualitySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const VolumeQualitySection({super.key, required this.kpi});
  @override
  Widget build(BuildContext context) {
    final v = kpi.bundle.volume;
    final q = kpi.bundle.quality;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.query_stats,
          color: AppColors.primary,
          title: AppText.t('الفحص والقرارات', 'Checks & decisions'),
          subtitle: AppText.t('الفترة المحددة', 'Selected period'),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 4 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            final cards = <Widget>[
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('قيد الانتظار', 'Pending'),
                  value: '${v.pending}',
                  color: AppColors.warning,
                  icon: Icons.hourglass_empty,
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('متابعات مفتوحة', 'Open follow-ups'),
                  value: '${v.openFollowUps}',
                  color: AppColors.info,
                  icon: Icons.follow_the_signs_outlined,
                  hint: AppText.t(
                    'قبول مشروط بملاحظة',
                    'Conditional with note',
                  ),
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('معدل القبول', 'Acceptance rate'),
                  value: '${q.acceptanceRate}%',
                  color: AppColors.success,
                  icon: Icons.verified_outlined,
                  hint: AppText.t('نهائي + مشروط', 'Approved + conditional'),
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('قبول صارم', 'Strict approval'),
                  value: '${q.strictRate}%',
                  color: AppColors.primary,
                  icon: Icons.check_circle_outline,
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('نسبة كمية مرفوضة', 'Rejected qty %'),
                  value: '${q.rejectedQtyRatio}%',
                  color: AppColors.danger,
                  icon: Icons.scale_outlined,
                  hint:
                      '${q.rejectedQty.toStringAsFixed(1)} / ${q.totalQty.toStringAsFixed(1)}',
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('مشروط / جزئي / كلي', 'Cond / Part / Full'),
                  value: '${q.conditional} / ${q.partial} / ${q.rejected}',
                  color: AppColors.accent,
                  icon: Icons.pie_chart_outline,
                  hint: '${AppText.t('مشروط', 'Cond')}: ${q.conditionalShare}%',
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('مقابل متوسط 7 أيام', 'vs 7-day avg'),
                  value: '${v.today} / ${v.weekAvg}',
                  color: AppColors.primary,
                  icon: Icons.today_outlined,
                  hint:
                      '${v.vsWeekAvg >= 0 ? '+' : ''}${v.vsWeekAvg.toStringAsFixed(1)}',
                ),
              ),
              SizedBox(
                width: tile,
                child: AppSummaryCard(
                  label: AppText.t('انتهاء / منتهي', 'Expiring / expired'),
                  value: '${q.expiryRisk} / ${q.expired}',
                  color: AppColors.danger,
                  icon: Icons.event_busy_outlined,
                  hint: AppText.t('30 يوم / منتهي', '30d / expired'),
                ),
              ),
            ];
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: cards,
            );
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        // Decision donut: approved / conditional / partial / full + legend
        // with shares (data-analyst upgrade: composition, not just counts).
        if (q.total > 0)
          AppCard(
            padding: EdgeInsets.zero,
            enableHover: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  AppDonutChart(
                    height: 200,
                    slices: [
                      AppChartSlice(
                        label: AppText.t('نهائي', 'Approved'),
                        value: q.approved.toDouble(),
                        color: AppColors.success,
                      ),
                      AppChartSlice(
                        label: AppText.t('مشروط', 'Conditional'),
                        value: q.conditional.toDouble(),
                        color: AppColors.info,
                      ),
                      AppChartSlice(
                        label: AppText.t('جزئي', 'Partial'),
                        value: q.partial.toDouble(),
                        color: AppColors.warning,
                      ),
                      AppChartSlice(
                        label: AppText.t('كلي', 'Full'),
                        value: q.rejected.toDouble(),
                        color: AppColors.danger,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      DonutLegend(
                        color: AppColors.success,
                        label:
                            '${AppText.t('نهائي', 'Approved')} ${q.strictRate}%',
                      ),
                      DonutLegend(
                        color: AppColors.info,
                        label:
                            '${AppText.t('مشروط', 'Conditional')} ${q.conditionalShare}%',
                      ),
                      DonutLegend(
                        color: AppColors.warning,
                        label:
                            '${AppText.t('جزئي', 'Partial')} ${q.partialRate}%',
                      ),
                      DonutLegend(
                        color: AppColors.danger,
                        label: '${AppText.t('كلي', 'Full')} ${q.fullRate}%',
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppText.t(
                      'القبول الموسّع (نهائي + مشروط): ${q.acceptanceRate}% • الصارم: ${q.strictRate}%',
                      'Broad acceptance (approved + conditional): ${q.acceptanceRate}% • Strict: ${q.strictRate}%',
                    ),
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11.spMax,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class DonutLegend extends StatelessWidget {
  final Color color;
  final String label;
  const DonutLegend({super.key, required this.color, required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
        ),
      ],
    );
  }
}
