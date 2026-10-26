import '../../../../design_system/widgets/app_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';

class DashboardResultLine extends StatelessWidget {
  final Map<String, dynamic>? summary;

  /// When set, a "clear filters" affordance accompanies the no-matches
  /// message (count == 0 AND active filters). Wired by the screen to the
  /// cubit so the widget stays navigation-free.
  final VoidCallback? onClearFilters;

  /// Whether any filter is active — gates the no-matches CTA.
  final bool filtersActive;
  const DashboardResultLine({
    super.key,
    required this.summary,
    this.onClearFilters,
    this.filtersActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final data = summary;
    if (data == null) return const SizedBox.shrink();
    final count = data['filtered_count'];
    final latest = data['latest'] as Map<String, dynamic>?;
    final latestLabel = '${latest?['label'] ?? ''}'.trim();
    final latestDate = '${latest?['date'] ?? ''}'.trim();
    final empty = count == 0 || count == '0';
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          if (empty && filtersActive) ...[
            Icon(Icons.search_off, size: 18.r, color: AppColors.warning),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                AppText.t(
                  'لا تطابقات مع الفلاتر الحالية',
                  'No matches with the current filters',
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.warning,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.spMax,
                ),
              ),
            ),
            AppButton(
              onPressed: onClearFilters,
              label: AppText.t('مسح الفلاتر', 'Clear filters'),
              style: AppButtonStyle.ghost,
              small: true,
            ),
          ] else ...[
            Icon(
              Icons.filter_alt_outlined,
              size: 15.r,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                latestLabel.isEmpty
                    ? AppText.t(
                        '$count فحص في الفترة',
                        '$count inspections in period',
                      )
                    : AppText.t(
                        '$count فحص • الأحدث: $latestLabel ($latestDate)',
                        '$count inspections • Latest: $latestLabel ($latestDate)',
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12.spMax,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
