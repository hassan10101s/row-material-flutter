import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';

class DataQualitySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const DataQualitySection({super.key, required this.kpi});
  @override
  Widget build(BuildContext context) {
    final q = kpi.bundle.dataQuality;
    if (q.total == 0) return const SizedBox.shrink();
    final okColor = q.completenessPct >= 80
        ? AppColors.success
        : q.completenessPct >= 60
        ? AppColors.warning
        : AppColors.danger;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.verified_outlined,
          color: AppColors.success,
          title: AppText.t(
            'بيانات ناقصة محتاجة تكملة',
            'Missing info to complete',
          ),
          subtitle: AppText.t(
            'كملها حتى تصبح النسب صحيحة',
            'Complete it so rates stay correct',
          ),
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
                    label: AppText.t('كامل', 'Complete'),
                    value: '${q.completenessPct}%',
                    color: okColor,
                    icon: Icons.checklist_outlined,
                    hint: AppText.t('من الفحوصات', 'of inspections'),
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('قرارات معلقة', 'Pending'),
                    value: '${q.pending}',
                    color: q.pendingPct > 10
                        ? AppColors.danger
                        : AppColors.warning,
                    icon: Icons.hourglass_empty,
                    hint: '${q.pendingPct}%',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('بدون مورّد', 'Missing supplier'),
                    value: '${q.missingSupplier}',
                    color: AppColors.warning,
                    icon: Icons.local_shipping_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('بدون صلاحية', 'Missing expiry'),
                    value: '${q.missingExpiry}',
                    color: AppColors.warning,
                    icon: Icons.event_busy_outlined,
                  ),
                ),
              ],
            );
          },
        ),
        if (q.completenessPct < 80 || q.pendingPct > 10) ...[
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    color: AppColors.warning,
                    size: 20.r,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      AppText.t(
                        'في بيانات ناقصة (${q.pending} معلق) — أكمل المورد وتاريخ الصلاحية لتحكم بدقة.',
                        'Some info is missing (${q.pending} pending) — fill supplier and expiry date to judge fairly.',
                      ),
                      style: TextStyle(fontSize: 12.5.spMax, height: 1.6),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
