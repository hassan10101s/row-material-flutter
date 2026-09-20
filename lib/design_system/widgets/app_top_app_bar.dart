import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_font_weights.dart';

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
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: Text(
        title,
        style: const TextStyle(fontWeight: AppFontWeights.bold, fontSize: 18),
      ),
      centerTitle: true,
      leading: leading ??
          (ModalRoute.of(context)?.canPop ?? false
              ? const BackButton()
              : null),
      actions: actions,
      backgroundColor: AppColors.surface,
      foregroundColor: AppColors.textStrong,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: AppColors.surface,
    );
  }
}