import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../cubit/dashboard_kpis_state.dart';
import '../widgets/dashboard_section_title.dart';

class InventorySection extends StatelessWidget {
  final DashboardKpisState kpi;
  const InventorySection({super.key, required this.kpi});
  @override
  Widget build(BuildContext context) {
    final inv = kpi.bundle.inventory;
    // Plan §6 cleanup: hide when always empty.
    if (inv.skus == 0) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DashboardSectionTitle(
          icon: Icons.inventory_2_outlined,
          color: AppColors.info,
          title: AppText.t('المخزون', 'Inventory'),
          subtitle: AppText.t('لقطة حالية', 'Snapshot'),
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
                    label: AppText.t('أصناف', 'Items'),
                    value: '${inv.skus}',
                    color: AppColors.info,
                    icon: Icons.inventory_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('منخفض', 'Low'),
                    value: '${inv.low}',
                    color: AppColors.warning,
                    icon: Icons.trending_down,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('فارغ', 'Empty'),
                    value: '${inv.empty}',
                    color: AppColors.danger,
                    icon: Icons.remove_shopping_cart_outlined,
                  ),
                ),
                SizedBox(
                  width: tile,
                  child: AppSummaryCard(
                    label: AppText.t('سليم', 'OK'),
                    value: '${inv.ok}',
                    color: AppColors.success,
                    icon: Icons.check_circle_outline,
                  ),
                ),
              ],
            );
          },
        ),
        if (inv.lowItems.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final it in inv.lowItems)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${it['name']}',
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.spMax,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${it['current_qty']}/${it['min_qty']} ${it['unit'] ?? ''}',
                            style: TextStyle(
                              color: AppColors.danger,
                              fontSize: 12.spMax,
                              fontWeight: FontWeight.bold,
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
