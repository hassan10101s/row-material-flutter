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
  final bool compact;

  const AppSummaryCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.hint,
    this.onTap,
    this.compact = false,
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
    if (widget.compact) {
      return Semantics(
        label: '${widget.label}: ${widget.value}',
        button: widget.onTap != null,
        child: AppCard(
          onTap: widget.onTap,
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(widget.icon, size: 20, color: widget.color),
              const SizedBox(height: AppSpacing.sm),
              Text(
                widget.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.xs),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  widget.value,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final isInteractive = widget.onTap != null;
    // Screen readers announce "label: value" as one unit instead of
    // traversing the number before the caption it belongs to.
    return Semantics(
      label: '${widget.label}: ${widget.value}',
      button: isInteractive,
      child: MouseRegion(
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
                    color: widget.color.withValues(
                      alpha: _isHovered ? 0.4 : 0.16,
                    ),
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
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Long values (grouped thousands) shrink instead of
                    // clipping: a clipped number reads as a wrong number.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        widget.value,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 20.spMax,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          color: widget.color,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    // Labels wrap to two lines on narrow tiles (400dp grid)
                    // instead of cutting Arabic words mid-read.
                    Text(
                      widget.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12.spMax,
                        height: 1.35,
                      ),
                    ),
                    if (widget.hint != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.hint!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 11.spMax,
                          fontWeight: FontWeight.w400,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
