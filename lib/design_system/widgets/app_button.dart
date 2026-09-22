import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';

enum AppButtonStyle { primary, secondary, accent, danger, ghost, whatsapp, pdf }

class AppButton extends StatefulWidget {
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
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    Color bg;
    Color fg;
    switch (widget.style) {
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
        bg = AppColors.whatsapp;
        fg = Colors.white;
      case AppButtonStyle.pdf:
        bg = AppColors.pdf;
        fg = Colors.white;
    }
    final child = widget.loading
        ? SizedBox(
            width: 18.r,
            height: 18.r,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          )
        : Row(
            mainAxisSize: widget.expanded ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                widget.icon!,
                SizedBox(width: 8.w),
              ],
              if (widget.label != null) Text(widget.label!),
            ],
          );
    return MouseRegion(
      onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
      onExit: (_) => setState(() => _hovered = false),
      cursor:
          (enabled && _hovered) ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: AnimatedScale(
        scale: enabled && _hovered ? 1.02 : 1,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: SizedBox(
          height: (widget.small ? 34 : 42).h,
          width: widget.expanded ? double.infinity : null,
          child: ElevatedButton(
            onPressed: enabled ? widget.onPressed : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: bg,
              foregroundColor: fg,
              elevation: 0,
              overlayColor: !enabled
                  ? null
                  : widget.style == AppButtonStyle.ghost
                      ? AppColors.primary.withValues(alpha: _hovered ? 0.1 : 0)
                      : Colors.white.withValues(alpha: _hovered ? 0.12 : 0),
              disabledBackgroundColor: bg.withValues(alpha: 0.5),
              disabledForegroundColor: fg.withValues(alpha: 0.9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular((widget.small ? 8 : 10).r),
              ),
              padding: EdgeInsets.symmetric(
                  horizontal: (widget.expanded ? 16 : 14).w),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}