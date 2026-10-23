import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_lab/core/l10n/app_localizations_x.dart';

import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../widgets/decision_badge.dart';

class DecisionsOverviewCard extends StatelessWidget {
  final Map<String, dynamic> summary;
  const DecisionsOverviewCard({super.key, required this.summary});
  @override
  Widget build(BuildContext context) {
    final totals = summary['totals'] as Map<String, dynamic>? ?? const {};
    final total = totals['total'] ?? 0;
    final approvalRate = '${totals['approvalRate'] ?? '0.0'}';
    final rejectionRate = '${totals['rejectionRate'] ?? '0.0'}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.pie_chart_outline,
                  color: AppColors.primary,
                  size: 22.r,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.period_decisions_title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${context.l10n.rate_approval_rate}$approvalRate%',
                    style: TextStyle(
                      fontSize: 12.spMax,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                DecisionBadge(
                  context.l10n.decision_approved,
                  '${totals['approved'] ?? 0}',
                  AppColors.success,
                ),
                DecisionBadge(
                  context.l10n.decision_conditional,
                  '${totals['conditional'] ?? 0}',
                  AppColors.info,
                ),
                DecisionBadge(
                  context.l10n.decision_partial,
                  '${totals['partial'] ?? 0}',
                  AppColors.partial,
                ),
                DecisionBadge(
                  context.l10n.decision_rejected,
                  '${totals['rejected'] ?? 0}',
                  AppColors.danger,
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: double.tryParse(approvalRate) != null
                    ? double.parse(approvalRate) / 100
                    : 0,
                minHeight: 10,
                color: AppColors.success,
                backgroundColor: AppColors.borderMuted,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    '${context.l10n.total_in_period}$total',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.spMax,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '${context.l10n.rejection_rate_general}$rejectionRate%',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: AppColors.danger,
                      fontSize: 12.spMax,
                      fontWeight: FontWeight.bold,
                    ),
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
