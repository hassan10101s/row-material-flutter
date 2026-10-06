import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_card.dart';

/// Metric/stat card: icon chip + big value + label (used for KPIs).
class AppSummaryCard extends StatefulWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String? hint;
  final VoidCallback? onTap;

  const AppSummaryCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.hint,
    this.onTap,
  });

  @override
  State<AppSummaryCard> createState() => _AppSummaryCardState();
}

class _AppSummaryCardState extends State<AppSummaryCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: AppCard(
        onTap: widget.onTap,
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: _isHovered ? 0.22 : 0.12),
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: widget.color.withValues(alpha: _isHovered ? 0.45 : 0.0),
                ),
              ),
              child: AnimatedScale(
                scale: _isHovered ? 1.08 : 1.0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Icon(widget.icon, color: widget.color, size: 24.r),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.value,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20.spMax,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      color: widget.color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12.spMax,
                    ),
                  ),
                  if (widget.hint != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.hint!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 11.spMax,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}