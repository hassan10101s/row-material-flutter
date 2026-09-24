import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color? color;
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.margin,
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The inner Material (transparent) gives children like ListTile /
    // SwitchListTile a Material ancestor above the decoration, so their ink
    // splashes and selected background stay visible.
    final content = Material(
      color: Colors.transparent,
      child: onTap == null ? child : InkWell(onTap: onTap, child: child),
    );
    return Container(
      padding: padding,
      margin: margin,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.borderMuted),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF071528).withValues(alpha: 0.03),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: content,
    );
  }
}