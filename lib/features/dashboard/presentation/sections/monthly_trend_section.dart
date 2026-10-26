import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_lab/core/l10n/app_localizations_x.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';

class MonthlyTrendSection extends StatelessWidget {
  final Map<String, dynamic> summary;
  const MonthlyTrendSection({super.key, required this.summary});
  @override
  Widget build(BuildContext context) {
    final monthlyTrend = (summary['monthlyTrend'] as List?) ?? const [];
    final comparison =
        summary['comparison'] as Map<String, dynamic>? ?? const {};
    final deltaLabel = '${comparison['label'] ?? ''}';
    final sign = '${comparison['approvalDeltaSign'] ?? ''}';
    return AppCard(
      padding: EdgeInsets.zero,
      enableHover: false,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.show_chart, color: AppColors.accent, size: 22.r),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.monthly_trend_title,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                if (deltaLabel.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color:
                          (sign == '+' ? AppColors.success : AppColors.danger)
                              .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      deltaLabel,
                      style: TextStyle(
                        fontSize: 12.spMax,
                        fontWeight: FontWeight.bold,
                        color: sign == '+'
                            ? AppColors.success
                            : AppColors.danger,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            if (monthlyTrend.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: Text(
                    context.l10n.monthly_trend_empty,
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              )
            else
              Column(
                children: [
                  for (final item in monthlyTrend)
                    MonthlyTrendRow(item: item as Map<String, dynamic>),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class MonthlyTrendRow extends StatefulWidget {
  final Map<String, dynamic> item;
  const MonthlyTrendRow({super.key, required this.item});

  @override
  State<MonthlyTrendRow> createState() => _MonthlyTrendRowState();
}

class _MonthlyTrendRowState extends State<MonthlyTrendRow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final label = '${widget.item['label'] ?? ''}';
    final total = widget.item['total'] ?? 0;
    final rate = '${widget.item['approvalRate'] ?? '0.0'}';
    final approvedPct =
        double.tryParse('${widget.item['approvedWidth'] ?? 0}') ?? 0.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: _isHovered
              ? AppColors.primary.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.spMax,
                      color: _isHovered ? AppColors.primary : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '$total ${AppText.t('فحص', 'inspections')} — ${AppText.t('قبول', 'approved')}: $rate%',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12.spMax,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (approvedPct / 100).clamp(0.0, 1.0),
                minHeight: 8,
                color: AppColors.primary,
                backgroundColor: AppColors.borderMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
