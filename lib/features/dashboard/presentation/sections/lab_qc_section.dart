import 'package:flutter/material.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';

class LabQcSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const LabQcSection({super.key, required this.kpi});
  @override
  Widget build(BuildContext context) {
    final lab = kpi.bundle.lab;
    final qc = kpi.bundle.qc;
    // Plan §6 cleanup: hide when always empty.
    if (lab.totalTests == 0 && qc.total == 0) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.biotech_outlined,
          color: AppColors.success,
          title: AppText.t('المعمل وفحوصات الجودة', 'Lab & QC Checks'),
          subtitle: AppText.t('الفترة المحددة', 'Selected period'),
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
                    label: AppText.t('اختبارات المعمل', 'Lab tests'),
                    value: '${lab.totalTests}',
                    color: AppColors.success,
                    icon: Icons.science_outlined,
                    hint:
                        '${AppText.t('مقيّم', 'Evaluated')}: ${lab.evaluated}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('ناجح / راسب QC', 'QC pass / fail'),
                    value: '${qc.pass} / ${qc.fail}',
                    color: AppColors.primary,
                    icon: Icons.fact_check_outlined,
                    hint: '${AppText.t('مشروط', 'Cond')}: ${qc.conditional}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('متوسط الدرجة', 'Avg score'),
                    value: '${qc.avgScore}%',
                    color: AppColors.accent,
                    icon: Icons.score_outlined,
                    hint: '${AppText.t('إجمالي', 'Total')}: ${qc.total}',
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('فحص ساقط', 'Failed checks'),
                    value: '${qc.ncRate}%',
                    color: AppColors.danger,
                    icon: Icons.warning_amber_outlined,
                    hint: AppText.t(
                      'خطر:${qc.critical} كبير:${qc.major} صغير:${qc.minor}',
                      'Critical:${qc.critical} Major:${qc.major} Minor:${qc.minor}',
                    ),
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
