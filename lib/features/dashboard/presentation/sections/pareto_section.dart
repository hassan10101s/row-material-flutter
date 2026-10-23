import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';
import '../../domain/dashboard_kpis.dart';

class ParetoSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const ParetoSection({super.key, required this.kpi});
  @override
  Widget build(BuildContext context) {
    final mat = kpi.bundle.materialPareto;
    final sup = kpi.bundle.supplierPareto;
    if (mat.isEmpty && sup.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.bar_chart_outlined,
          color: AppColors.warning,
          title: AppText.t('الرفض جاي منين؟', 'Where do rejections come from?'),
          subtitle: AppText.t(
            'ركز على أول 3 أسباب',
            'Focus on the top 3 first',
          ),
        ),
        LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= AppBreakpoints.medium
                ? (c.maxWidth - AppSpacing.md) / 2
                : c.maxWidth;
            return Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.md,
              children: [
                if (mat.isNotEmpty)
                  SizedBox(
                    width: wide,
                    child: ParetoCard(
                      title: AppText.t(
                        'الرفض حسب الخامة',
                        'Rejections by material',
                      ),
                      entries: mat,
                    ),
                  ),
                if (sup.isNotEmpty)
                  SizedBox(
                    width: wide,
                    child: ParetoCard(
                      title: AppText.t(
                        'الرفض حسب المورّد',
                        'Rejections by supplier',
                      ),
                      entries: sup,
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

class ParetoCard extends StatelessWidget {
  final String title;
  final List<ParetoEntry> entries;
  const ParetoCard({super.key, required this.title, required this.entries});
  @override
  Widget build(BuildContext context) {
    final maxCount = entries.fold<int>(0, (m, e) => e.count > m ? e.count : m);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              AppText.t(
                'ابدأ من فوق — أول سبب هو الأهم.',
                'Start from the top — the first cause matters most.',
              ),
              style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (var i = 0; i < entries.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(
                          width: 20,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontSize: 11.spMax,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            entries[i].label,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5.spMax,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '${entries[i].count} ${AppText.t('رفض', 'rejected')} (${entries[i].pct}%)',
                          style: TextStyle(
                            fontSize: 11.5.spMax,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: maxCount == 0 ? 0 : entries[i].count / maxCount,
                        minHeight: 7,
                        color: i < 3 ? AppColors.danger : AppColors.warning,
                        backgroundColor: AppColors.borderMuted,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
