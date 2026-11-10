import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Shared surface for a horizontally scrollable row of related controls.
class AppControlStrip extends StatelessWidget {
  const AppControlStrip({
    super.key,
    required this.children,
    this.height = 48,
    this.spacing = AppSpacing.sm,
  });

  final List<Widget> children;
  final double height;
  final double spacing;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    decoration: BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadii.md),
      border: Border.all(color: AppColors.borderMuted),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(AppSpacing.xs),
      child: Row(
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0) SizedBox(width: spacing),
            children[index],
          ],
        ],
      ),
    ),
  );
}
