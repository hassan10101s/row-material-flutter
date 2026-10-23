import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/decision_badge.dart';

class QcQuickCard extends StatelessWidget {
  final DashboardKpisState kpi;
  const QcQuickCard({super.key, required this.kpi});

  @override
  Widget build(BuildContext context) {
    final qc = kpi.bundle.qc;
    final total = qc.total;
    final acceptRate = total == 0 ? 0.0 : (qc.pass / total * 100);
    final rejectRate = total == 0 ? 0.0 : (qc.fail / total * 100);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.verified_outlined,
                  color: AppColors.success,
                  size: 22.r,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppText.t('جودة الفحوصات', 'Inspection quality'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '${AppText.t('قبول', 'Accept')}: ${acceptRate.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 12.spMax,
                      fontWeight: FontWeight.bold,
                      color: AppColors.success,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            if (total == 0)
              Text(
                AppText.t(
                  'لا توجد فحوصات جودة في هذه الفترة',
                  'No quality checks in this period',
                ),
                style: TextStyle(color: AppColors.textMuted),
              )
            else ...[
              Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.sm,
                children: [
                  DecisionBadge(
                    AppText.t('مطابق', 'Pass'),
                    '${qc.pass}',
                    AppColors.success,
                  ),
                  DecisionBadge(
                    AppText.t('مشروط', 'Conditional'),
                    '${qc.conditional}',
                    AppColors.info,
                  ),
                  DecisionBadge(
                    AppText.t('غير مطابق', 'Fail'),
                    '${qc.fail}',
                    AppColors.danger,
                  ),
                  DecisionBadge(
                    AppText.t('منتظر', 'Pending'),
                    '${qc.pending}',
                    AppColors.textMuted,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: (acceptRate / 100).clamp(0.0, 1.0),
                  minHeight: 10,
                  color: AppColors.success,
                  backgroundColor: AppColors.borderMuted,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(
                      '${AppText.t('الإجمالي', 'Total')}: $total',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.spMax,
                      ),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      '${AppText.t('رفض', 'Reject')}: ${rejectRate.toStringAsFixed(1)}%',
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
          ],
        ),
      ),
    );
  }
}

/// Plan §6 — بطاقة المهام اليومية: القوائم الدورية المنشورة مقابل
/// ما بدأ منها اليوم (مثال: "3 من 5 مهام يومية منجزة").
