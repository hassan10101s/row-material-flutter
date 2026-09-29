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
    final radius = BorderRadius.circular(AppRadii.md);
    // The inner Material (transparent) gives children like ListTile /
    // SwitchListTile a Material ancestor above the decoration, so their ink
    // splashes and selected background stay visible.
    final content = Material(
      color: Colors.transparent,
      // Without this the InkWell splash paints a hard rectangle that visibly
      // overflows the rounded corners.
      borderRadius: radius,
      clipBehavior: onTap == null ? Clip.none : Clip.antiAlias,
      child: onTap == null ? child : InkWell(onTap: onTap, child: child),
    );
    return Container(
      padding: padding,
      margin: margin,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: radius,
        border: Border.all(color: AppColors.borderMuted),
        // Reads the shared token, which tracks brightness. The previous inline
        // shadow hardcoded the *light* surfaceDeep navy at 3% and was therefore
        // invisible against the dark surface.
        boxShadow: AppShadows.card(Theme.of(context).brightness),
      ),
      child: content,
    );
  }
}
