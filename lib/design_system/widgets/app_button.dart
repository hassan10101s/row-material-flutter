import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';

enum AppButtonStyle { primary, secondary, accent, danger, ghost, whatsapp, pdf }

class AppButton extends StatelessWidget {
  final String? label;
  final Widget? icon;
  final VoidCallback? onPressed;
  final AppButtonStyle style;
  final bool loading;
  final bool expanded;
  final bool small;

  const AppButton({
    super.key,
    this.label,
    this.icon,
    required this.onPressed,
    this.style = AppButtonStyle.primary,
    this.loading = false,
    this.expanded = false,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    Color bg;
    Color fg;
    switch (style) {
      case AppButtonStyle.primary:
        bg = AppColors.primary;
        fg = Colors.white;
      case AppButtonStyle.accent:
        bg = AppColors.accent;
        fg = Colors.white;
      case AppButtonStyle.danger:
        bg = AppColors.danger;
        fg = Colors.white;
      case AppButtonStyle.secondary:
        bg = AppColors.surfaceSoft;
        fg = AppColors.textStrong;
      case AppButtonStyle.ghost:
        bg = Colors.transparent;
        fg = AppColors.primary;
      case AppButtonStyle.whatsapp:
        bg = const Color(0xFF25D366);
        fg = Colors.white;
      case AppButtonStyle.pdf:
        bg = const Color(0xFFE11D48);
        fg = Colors.white;
    }
    final child = loading
        ? SizedBox(
            width: 18.r,
            height: 18.r,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        : Row(
            mainAxisSize: expanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                icon!,
                SizedBox(width: 8.w),
              ],
              if (label != null) Text(label!),
            ],
          );
    return SizedBox(
      height: (small ? 34 : 42).h,
      width: expanded ? double.infinity : null,
      child: ElevatedButton(
        onPressed: enabled ? onPressed : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          elevation: 0,
          disabledBackgroundColor: bg.withValues(alpha: 0.5),
          disabledForegroundColor: fg.withValues(alpha: 0.9),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular((small ? 8 : 10).r),
          ),
          padding: EdgeInsets.symmetric(horizontal: (expanded ? 16 : 14).w),
        ),
        child: child,
      ),
    );
  }
}