import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../../domain/dashboard_analytics.dart' as analytics;

class ExecutiveSummarySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const ExecutiveSummarySection({super.key, required this.kpi});
  @override
  Widget build(BuildContext context) {
    final b = kpi.bundle;
    if (b.quality.total == 0 && b.volume.total == 0) {
      return const SizedBox.shrink();
    }
    final signals = analytics.buildExecutiveSignals(
      trend: b.trend,
      suppliers: b.supplierScores,
      materialPareto: b.materialPareto,
      quality: b.dataQuality,
      totalInspections: b.quality.total,
    );
    final direction = '${signals['direction']}';
    final delta = (signals['deltaPp'] as double?) ?? 0.0;
    final dirColor = direction == 'up'
        ? AppColors.success
        : direction == 'down'
        ? AppColors.danger
        : AppColors.textMuted;
    final dirIcon = direction == 'up'
        ? Icons.trending_up
        : direction == 'down'
        ? Icons.trending_down
        : Icons.trending_flat;
    final dirText = direction == 'up'
        ? AppText.t('أفضل من الشهر السابق', 'Better than last month')
        : direction == 'down'
        ? AppText.t('أقل من الشهر السابق', 'Lower than last month')
        : direction == 'flat'
        ? AppText.t('مثل الشهر السابق', 'Same as last month')
        : AppText.t('لا يوجد اتجاه واضح بعد', 'No clear trend yet');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  color: AppColors.primary,
                  size: 22.r,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppText.t('الوضع باختصار', "What's happening"),
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              AppText.t(
                'من ${b.quality.total} فحص: أُقبل ${b.quality.acceptanceRate}%. $dirText (${delta >= 0 ? '+' : ''}$delta%). '
                    'أكتر رفض جاي من: ${signals['topRiskMaterial']}. '
                    'المورد اللي محتاج متابعة: ${signals['topRiskSupplier']}.',
                'Out of ${b.quality.total} inspections: ${b.quality.acceptanceRate}% accepted. $dirText (${delta >= 0 ? '+' : ''}$delta%). '
                    'Most rejections come from: ${signals['topRiskMaterial']}. '
                    'Supplier to follow up: ${signals['topRiskSupplier']}.',
              ),
              style: TextStyle(fontSize: 13.spMax, height: 1.6),
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SummaryChip(
                  icon: dirIcon,
                  color: dirColor,
                  text: '$dirText ${delta >= 0 ? '+' : ''}$delta%',
                ),
                SummaryChip(
                  icon: Icons.pie_chart_outline,
                  color: AppColors.accent,
                  text: AppText.t(
                    'أكتر رفض: ${signals['topRiskMaterial']} (${signals['concentrationPct']}%)',
                    'Top rejection: ${signals['topRiskMaterial']} (${signals['concentrationPct']}%)',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class SummaryChip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const SummaryChip({super.key, 
    required this.icon,
    required this.color,
    required this.text,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14.r, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5.spMax,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
