import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';

class ForecastStabilitySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const ForecastStabilitySection({super.key, required this.kpi});
  @override
  Widget build(BuildContext context) {
    final b = kpi.bundle;
    if (b.forecast.isEmpty) return const SizedBox.shrink();
    final hasAny = b.forecast.any((f) => f.hasData);
    if (!hasAny) return const SizedBox.shrink();
    final next = b.forecast.isEmpty ? null : b.forecast.last.forecast;
    final st = b.stability;
    final volColor = st.volatility == 'low'
        ? AppColors.success
        : st.volatility == 'medium'
        ? AppColors.warning
        : st.volatility == 'high'
        ? AppColors.danger
        : AppColors.textMuted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.auto_graph_outlined,
          color: AppColors.info,
          title: AppText.t('توقع الشهر الجاي', 'Next month outlook'),
          subtitle: AppText.t(
            'على حسب آخر 3 شهور',
            'Based on the last 3 months',
          ),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final cols = c.maxWidth >= AppBreakpoints.medium ? 2 : 2;
            final tile = (c.maxWidth - AppSpacing.md * (cols - 1)) / cols;
            final outlookOk = st.volatility == 'low';
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('القبول المتوقع', 'Expected acceptance'),
                    value: next == null ? '—' : '$next%',
                    color: AppColors.info,
                    icon: Icons.timeline_outlined,
                    hint: AppText.t('توقع تقريبي', 'Rough estimate'),
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('الوضع', 'Trend status'),
                    value: outlookOk
                        ? AppText.t('مستقر', 'Steady')
                        : st.volatility == 'unknown'
                        ? AppText.t('لسه بدري', 'Too early')
                        : AppText.t('متغير', 'Changing'),
                    color: outlookOk ? AppColors.success : AppColors.warning,
                    icon: Icons.waves_outlined,
                    hint: AppText.t('آخر شهور', 'Recent months'),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lightbulb_outline, color: volColor, size: 20.r),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    st.volatility == 'high'
                        ? AppText.t(
                            'النسب طالعة نازلة — استنى شهر كمان قبل ما تحكم.',
                            'Numbers are going up and down — wait one more month before judging.',
                          )
                        : st.volatility == 'medium'
                        ? AppText.t(
                            'في تغير بسيط — تابع الشهرين الجايين.',
                            'Slight change — keep watching the next two months.',
                          )
                        : st.volatility == 'low'
                        ? AppText.t(
                            'الدنيا مستقرة — ركز على المورد اللي عنده رفض كتير.',
                            'Things are steady — focus on the supplier with most rejections.',
                          )
                        : AppText.t(
                            'البيانات لسه قليلة — استنى شهرين قبل ما تستنتج.',
                            'Not enough data yet — wait two months before concluding.',
                          ),
                    style: TextStyle(fontSize: 12.5.spMax, height: 1.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
