import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';

class SopGoalsSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const SopGoalsSection({super.key, required this.kpi});
  @override
  Widget build(BuildContext context) {
    final s = kpi.bundle.sopGoals;
    // Plan §6 cleanup: hide when always empty.
    if (s.sopTotal == 0 && s.goalTotal == 0) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.menu_book_outlined,
          color: AppColors.accent,
          title: AppText.t('الإجراءات والأهداف', 'Procedures & goals'),
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
                    label: AppText.t('إجراء معتمد', 'Approved procedure'),
                    value: '${s.sopPublished}',
                    color: AppColors.primary,
                    icon: Icons.description_outlined,
                    hint: '${AppText.t('إجمالي', 'Total')}: ${s.sopTotal}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('منتهي / قريب', 'Expired / soon'),
                    value: '${s.sopExpired} / ${s.sopExpiring}',
                    color: AppColors.danger,
                    icon: Icons.event_busy_outlined,
                    hint: '${AppText.t('بانتظار', 'Pending')}: ${s.sopPending}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('أهداف نشطة', 'Active goals'),
                    value: '${s.goalActive}',
                    color: AppColors.accent,
                    icon: Icons.flag_outlined,
                    hint: '${AppText.t('إجمالي', 'Total')}: ${s.goalTotal}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متأخر / مكتمل', 'Overdue / done'),
                    value: '${s.goalOverdue} / ${s.goalCompleted}',
                    color: AppColors.warning,
                    icon: Icons.task_alt_outlined,
                    hint:
                        '${AppText.t('تقدم', 'Progress')}: ${s.goalAvgProgress}% · ${AppText.t('إجراءات', 'Actions')}: ${s.goalOverdueActions}',
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
