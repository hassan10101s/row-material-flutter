import 'package:flutter/material.dart';
import 'package:material_lab/core/l10n/app_localizations_x.dart';

import '../../../../design_system/charts/app_chart_card.dart';
import '../../../../design_system/charts/app_charts.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../core/constants/app_strings.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';

class TrendChartSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const TrendChartSection({super.key, required this.kpi});
  @override
  Widget build(BuildContext context) {
    final trend = kpi.bundle.trend;
    final forecast = kpi.bundle.forecast;
    final hasData = trend.any((t) => t.total > 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.show_chart,
          color: AppColors.accent,
          title: AppText.t(
            'آخر 6 شهور: الفحص والقبول',
            'Last 6 months: checks & acceptance',
          ),
          subtitle: AppText.t(
            'الأعمدة = عدد الفحوص • الخط = نسبة القبول',
            'Bars = number of checks • Line = acceptance %',
          ),
        ),
        AppChartCard(
          title: AppText.t('حجم الفحص الشهري', 'Monthly check volume'),
          legend: [
            AppChartLegendEntry(
              color: AppColors.primary,
              label: AppText.t('الحجم', 'Volume'),
            ),
          ],
          child: !hasData
              ? AppChartEmpty(
                  message: context.l10n.monthly_trend_empty, height: 180)
              : AppCountBarChart(
                  height: 220,
                  unit: AppText.t('فحص', 'inspections'),
                  points: [
                    for (final t in trend)
                      AppChartPoint(
                        label: t.label,
                        value: t.total.toDouble(),
                        tooltip: '${AppText.t('القبول', 'approval')}: ${t.approvalRate}%',
                      ),
                  ],
                ),
        ),
        if (hasData)
          AppChartCard(
            title: AppText.t('نسبة القبول', 'Acceptance rate'),
            legend: [
              AppChartLegendEntry(
                color: AppColors.success,
                label: AppText.t('القبول %', 'Approval %'),
              ),
              AppChartLegendEntry(
                color: AppColors.info,
                label: AppText.t('متوسط آخر شهور', 'Recent average'),
                dashed: true,
              ),
            ],
            child: AppPercentLineChart(
              points: [
                for (final t in trend)
                  AppChartPoint(label: t.label, value: t.approvalRate),
              ],
              movingAvg: [
                for (final f in forecast) f.movingAvg,
              ],
            ),
          ),
      ],
    );
  }
}
