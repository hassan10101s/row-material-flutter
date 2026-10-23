import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';

class AgingDefectsSection extends StatelessWidget {
  final DashboardKpisState kpi;
  const AgingDefectsSection({super.key, required this.kpi});
  static const _labels = ['0-7', '8-14', '15-30', '31-60', '>60'];
  @override
  Widget build(BuildContext context) {
    final n = kpi.bundle.ncr;
    final maxAging = n.aging.fold<int>(0, (a, b) => a > b ? a : b);
    final maxDefect = n.topDefects.fold<int>(
      0,
      (a, d) => (d['count'] as int? ?? 0) > a ? (d['count'] as int? ?? 0) : a,
    );
    if (n.total == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.hourglass_bottom_outlined,
          color: AppColors.warning,
          title: AppText.t('المشاكل المفتوحة حسب قدمها', 'Open issues by age'),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                for (var i = 0; i < _labels.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 52,
                          child: Text(
                            _labels[i],
                            style: TextStyle(
                              fontSize: 12.spMax,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: maxAging == 0 ? 0 : n.aging[i] / maxAging,
                              minHeight: 8,
                              color: AppColors.warning,
                              backgroundColor: AppColors.borderMuted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 32,
                          child: Text(
                            '${n.aging[i]}',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 12.spMax,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (n.topDefects.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppText.t('أعلى العيوب', 'Top defects'),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (final d in n.topDefects)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${d['label']}',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12.5.spMax),
                                ),
                              ),
                              Text(
                                '${d['count']}',
                                style: TextStyle(
                                  fontSize: 12.spMax,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.danger,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: maxDefect == 0
                                  ? 0
                                  : ((d['count'] as int? ?? 0) / maxDefect),
                              minHeight: 6,
                              color: AppColors.danger,
                              backgroundColor: AppColors.borderMuted,
                            ),
                          ),
                        ],
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

// ── Data-scientist layer: executive summary + scorecards + Pareto +
// forecast/stability + data quality (all display-only, bilingual) ─────
