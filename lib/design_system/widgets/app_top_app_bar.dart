import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_font_weights.dart';
import 'app_adaptive.dart';

class AppTopAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final List<Widget> actions;
  final Widget? leading;

  const AppTopAppBar({
    super.key,
    required this.title,
    this.actions = const [],
    this.leading,
  });

  @override
  Size get preferredSize => Size.fromHeight(appNavigationToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final compact = preferredSize.height < kToolbarHeight;
    return AppBar(
      toolbarHeight: preferredSize.height,
      leadingWidth: compact ? 48 : null,
      titleSpacing: compact ? 8 : null,
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: AppFontWeights.bold,
          fontSize: compact ? 18 : 18.spMax,
        ),
      ),
      centerTitle: !compact,
      leading:
          leading ??
          (ModalRoute.of(context)?.canPop ?? false ? const BackButton() : null),
      actions: actions,
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.textStrong,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: AppColors.surface,
      shape: Border(bottom: BorderSide(color: AppColors.borderMuted)),
    );
  }
}
