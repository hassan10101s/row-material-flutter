import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

class AppCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final VoidCallback? onTap;
  final bool enableHover;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin,
    this.color,
    this.onTap,
    this.enableHover = true,
  });

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.md);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isInteractive = widget.onTap != null;

    final content = Material(
      color: Colors.transparent,
      borderRadius: radius,
      clipBehavior: isInteractive ? Clip.antiAlias : Clip.none,
      child: isInteractive
          ? InkWell(
              onTap: widget.onTap,
              borderRadius: radius,
              mouseCursor: SystemMouseCursors.click,
              child: widget.child,
            )
          : widget.child,
    );

    return MouseRegion(
      onEnter: widget.enableHover ? (_) => setState(() => _isHovered = true) : null,
      onExit: widget.enableHover ? (_) => setState(() => _isHovered = false) : null,
      cursor: isInteractive ? SystemMouseCursors.click : MouseCursor.defer,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        transform: _isHovered && widget.enableHover
            ? (Matrix4.identity()..translate(0.0, -2.0))
            : Matrix4.identity(),
        padding: widget.padding,
        margin: widget.margin,
        decoration: BoxDecoration(
          color: widget.color ?? AppColors.surface,
          borderRadius: radius,
          border: Border.all(
            color: _isHovered && widget.enableHover
                ? AppColors.primary.withValues(alpha: 0.35)
                : AppColors.borderMuted,
            width: _isHovered && widget.enableHover ? 1.2 : 1.0,
          ),
          boxShadow: _isHovered && widget.enableHover
              ? [
                  BoxShadow(
                    color: (isDark ? Colors.black : AppColors.primary)
                        .withValues(alpha: isDark ? 0.35 : 0.10),
                    blurRadius: 14,
                    offset: const Offset(0, 6),
                  ),
                ]
              : AppShadows.card(Theme.of(context).brightness),
        ),
        child: content,
      ),
    );
  }
}

