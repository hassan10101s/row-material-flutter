import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';

class TopBreakdownSection extends StatelessWidget {
  final Map<String, dynamic> summary;
  const TopBreakdownSection({super.key, required this.summary});
  @override
  Widget build(BuildContext context) {
    final topMaterials = (summary['topMaterials'] as List?) ?? const [];
    final topSuppliers = (summary['topSuppliers'] as List?) ?? const [];
    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth =
            AppBreakpoints.fitsColumnsIn(
              availableWidth: constraints.maxWidth,
              columns: 2,
              minColumnWidth: 300,
              gap: AppSpacing.md,
            )
            ? (constraints.maxWidth - AppSpacing.md) / 2
            : constraints.maxWidth;

        return Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: [
            // Top Materials Card
            SizedBox(
              width: cardWidth,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.inventory_2_outlined,
                            color: AppColors.primary,
                            size: 20.r,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppText.t('أعلى الخامات فحوصات', 'Top Materials'),
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (topMaterials.isEmpty)
                        Text(
                          AppText.t(
                            'لا توجد فحوصات خامات',
                            'No material inspections',
                          ),
                          style: TextStyle(color: AppColors.textMuted),
                        )
                      else
                        for (final m in topMaterials) ...[
                          TopItemProgress(
                            label: '${m['name']}',
                            count:
                                '${m['total']} ${AppText.t('فحص', 'inspections')}',
                            rate:
                                '${m['rate']}% ${AppText.t('قبول', 'approved')}',
                            value: double.tryParse('${m['rate']}') ?? 0.0,
                            color: AppColors.primary,
                          ),
                          const SizedBox(height: 8),
                        ],
                    ],
                  ),
                ),
              ),
            ),
            // Top Suppliers Card
            SizedBox(
              width: cardWidth,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.local_shipping_outlined,
                            color: AppColors.accent,
                            size: 20.r,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppText.t(
                                'أعلى الموردين فحوصات',
                                'Top Suppliers',
                              ),
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (topSuppliers.isEmpty)
                        Text(
                          AppText.t(
                            'لا توجد فحوصات موردين',
                            'No supplier inspections',
                          ),
                          style: TextStyle(color: AppColors.textMuted),
                        )
                      else
                        for (final s in topSuppliers) ...[
                          TopItemProgress(
                            label: '${s['name']}',
                            count:
                                '${s['total']} ${AppText.t('فحص', 'inspections')}',
                            rate:
                                '${s['approvalRate']}% ${AppText.t('قبول', 'approved')}',
                            value:
                                double.tryParse('${s['approvalRate']}') ?? 0.0,
                            color: AppColors.accent,
                          ),
                          const SizedBox(height: 8),
                        ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class TopItemProgress extends StatefulWidget {
  final String label;
  final String count;
  final String rate;
  final double value;
  final Color color;
  const TopItemProgress({super.key, 
    required this.label,
    required this.count,
    required this.rate,
    required this.value,
    required this.color,
  });

  @override
  State<TopItemProgress> createState() => _TopItemProgressState();
}

class _TopItemProgressState extends State<TopItemProgress> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: SystemMouseCursors.click,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        decoration: BoxDecoration(
          color: _isHovered
              ? widget.color.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.spMax,
                      height: 1.35,
                      color: _isHovered ? widget.color : null,
                    ),
                  ),
                ),
                Text(
                  '${widget.count} (${widget.rate})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
                value: (widget.value / 100).clamp(0.0, 1.0),
                minHeight: 6,
                color: widget.color,
                backgroundColor: AppColors.borderMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Senior-analyst cross-module sections (display-only) ──────────────
// Every section reads DashboardKpisState.bundle; zeros render as "0", null
// rates render as "—" (never NaN). No onTap navigation per requirements.
