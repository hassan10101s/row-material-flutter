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

  void _setHovered(bool value) {
    if (!mounted || _isHovered == value) return;
    setState(() => _isHovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final isInteractive = widget.onTap != null;
    return MouseRegion(
      onEnter: isInteractive ? (_) => _setHovered(true) : null,
      onExit: isInteractive ? (_) => _setHovered(false) : null,
      cursor: isInteractive ? SystemMouseCursors.click : MouseCursor.defer,
      child: AppCard(
        enableHover: false,
        onTap: widget.onTap,
        padding: EdgeInsets.all(14.r),
        child: Row(
          children: [
            Container(
              width: 46.r,
              height: 46.r,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topRight,
                  end: Alignment.bottomLeft,
                  colors: [
                    widget.color.withValues(alpha: _isHovered ? 0.28 : 0.18),
                    widget.color.withValues(alpha: _isHovered ? 0.14 : 0.08),
                  ],
                ),
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(
                  color: widget.color.withValues(alpha: _isHovered ? 0.4 : 0.16),
                ),
              ),
              child: AnimatedScale(
                scale: _isHovered ? 1.1 : 1.0,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                child: Icon(widget.icon, color: widget.color, size: 22.r),
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