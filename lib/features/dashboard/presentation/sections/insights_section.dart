import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';

class InsightsAndRecommendationsSection extends StatelessWidget {
  final Map<String, dynamic> summary;
  const InsightsAndRecommendationsSection({super.key, required this.summary});
  @override
  Widget build(BuildContext context) {
    final recommendations = (summary['recommendations'] as List?) ?? const [];
    final insightCards = (summary['insightCards'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (recommendations.isNotEmpty) ...[
          Text(
            AppText.t('التوصيات الإدارية', 'Recommendations'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final rec in recommendations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.tips_and_updates,
                            size: 18.r,
                            color: AppColors.warning,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '$rec',
                              style: TextStyle(fontSize: 13.5.spMax),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        if (insightCards.isNotEmpty) ...[
          Text(
            AppText.t('التحليلات والتنبيهات', 'Insights'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final tile =
                  AppBreakpoints.fitsColumnsIn(
                    availableWidth: constraints.maxWidth,
                    columns: insightCards.length,
                    minColumnWidth: 280,
                    gap: AppSpacing.md,
                  )
                  ? (constraints.maxWidth -
                            AppSpacing.md * (insightCards.length - 1)) /
                        insightCards.length
                  : constraints.maxWidth;
              return Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.md,
                children: [
                  for (final c in insightCards)
                    SizedBox(
                      width: tile,
                      child: InsightCard(map: c as Map<String, dynamic>),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}

class InsightCard extends StatelessWidget {
  final Map<String, dynamic> map;
  const InsightCard({super.key, required this.map});
  @override
  Widget build(BuildContext context) {
    final tone = '${map['tone']}';
    final color = switch (tone) {
      'success' => AppColors.success,
      'danger' => AppColors.danger,
      _ => AppColors.warning,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lightbulb_outline, color: color, size: 20.r),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${map['title']}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: color,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${map['description']}',
              style: TextStyle(
                fontSize: 12.5.spMax,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
