import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_motion.dart';

class AppCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enableHover;

  /// Quietest shadow tier for dense scrollable lists (mobile registers).
  /// Hover lift is unaffected; defaults to the standard [AppShadows.card].
  final bool flat;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin,
    this.color,
    this.onTap,
    this.onLongPress,
    this.enableHover = true,
    this.flat = false,
  });

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _isHovered = false;

  void _setHovered(bool value) {
    if (!mounted || _isHovered == value) return;
    setState(() => _isHovered = value);
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadii.md);
    final isInteractive = widget.onTap != null || widget.onLongPress != null;
    final activeHover = widget.enableHover && isInteractive;
    final paddedChild = Padding(padding: widget.padding, child: widget.child);

    final content = Material(
      color: Colors.transparent,
      borderRadius: radius,
      clipBehavior: isInteractive ? Clip.antiAlias : Clip.none,
      child: isInteractive
          ? InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress,
              borderRadius: radius,
              mouseCursor: SystemMouseCursors.click,
              child: paddedChild,
            )
          : paddedChild,
    );

    return MouseRegion(
      onEnter: activeHover ? (_) => _setHovered(true) : null,
      onExit: activeHover ? (_) => _setHovered(false) : null,
      cursor: isInteractive ? SystemMouseCursors.click : MouseCursor.defer,
      child: AnimatedContainer(
        duration: AppMotion.of(context, AppMotion.fast),
        curve: Curves.easeOutCubic,
        margin: widget.margin,
        transform: Matrix4.translationValues(
          0,
          _isHovered && activeHover && isInteractive ? -1 : 0,
          0,
        ),
        decoration: BoxDecoration(
          color: widget.color ?? AppColors.surface,
          borderRadius: radius,
          border: Border.all(
            color: _isHovered && activeHover
                ? AppColors.primary.withValues(alpha: 0.4)
                : AppColors.borderMuted,
            width: _isHovered && activeHover ? 1.2 : 1.0,
          ),
          boxShadow: _isHovered && activeHover
              ? AppShadows.elevated(Theme.of(context).brightness)
              : widget.flat
              ? AppShadows.flat(Theme.of(context).brightness)
              : AppShadows.card(Theme.of(context).brightness),
        ),
        child: content,
      ),
    );
  }
}
