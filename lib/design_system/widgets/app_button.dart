import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_contrast.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_motion.dart';
import '../tokens/app_opacity.dart';
import '../tokens/app_spacing.dart';

enum AppButtonStyle { primary, secondary, accent, danger, ghost, whatsapp, pdf }

/// The app's button.
///
/// Built on the real Material button classes ([FilledButton] / [TextButton])
/// rather than an `ElevatedButton` with every property overridden by hand.
/// That choice matters: the native classes bring keyboard focus, activation
/// (Enter / Space), and a focus-highlight ring, none of which the previous
/// mouse-only `MouseRegion` + `AnimatedScale` version provided.
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

  /// Background for the filled and tonal styles. `null` for [ghost].
  Color? _backgroundFor(AppButtonStyle style) {
    switch (style) {
      case AppButtonStyle.primary:
        return AppColors.primary;
      case AppButtonStyle.accent:
        return AppColors.accent;
      case AppButtonStyle.danger:
        return AppColors.danger;
      case AppButtonStyle.secondary:
        return AppColors.surfaceSoft;
      case AppButtonStyle.whatsapp:
        return AppColors.whatsapp;
      case AppButtonStyle.pdf:
        return AppColors.pdf;
      case AppButtonStyle.ghost:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.loading;
    final background = _backgroundFor(widget.style);
    final ghost = widget.style == AppButtonStyle.ghost;

    // The foreground is *derived from the background it paints on* rather than
    // hardcoded to white. White on the dark palette's primary (#38BDF8) is
    // 2.14:1, which fails WCAG AA; on the light palette's (#0284C7) it is
    // 4.09:1, which also fails. `AppContrast.on` picks whichever of
    // black/white actually clears 4.5:1, so this cannot drift again.
    final foreground = ghost
        ? AppColors.primary
        : AppContrast.on(background ?? AppColors.surfaceSoft);

    // A disabled foreground at 90% over a 50% background is a guaranteed
    // contrast failure. Anchor both to the surface tokens instead.
    final disabledBackground = ghost
        ? Colors.transparent
        : AppColors.textStrong.withValues(alpha: AppOpacity.disabledSurface);
    final disabledForeground = ghost
        ? AppColors.primary.withValues(alpha: AppOpacity.disabled)
        : AppColors.textMuted.withValues(alpha: AppOpacity.disabled + 0.25);

    final radius = BorderRadius.circular(
      widget.small ? AppRadii.sm : AppRadii.md,
    );
    // A minimum height rather than a fixed one, so a user with a large OS text
    // scale does not clip the label.
    final minHeight = widget.small ? 34.h : 42.h;

    final shape = RoundedRectangleBorder(borderRadius: radius);

    final content = _content(foreground);

    final button = ghost
        ? TextButton(
            onPressed: enabled ? widget.onPressed : null,
            style: ButtonStyle(
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? disabledForeground
                    : foreground,
              ),
              minimumSize: WidgetStatePropertyAll(Size(0, minHeight)),
              shape: WidgetStatePropertyAll(shape),
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: (widget.expanded ? 16 : 14).w),
              ),
              overlayColor: WidgetStatePropertyAll(
                AppColors.primary.withValues(alpha: AppOpacity.hover),
              ),
              textStyle: WidgetStatePropertyAll(_labelStyle(foreground)),
            ),
            child: content,
          )
        : FilledButton(
            onPressed: enabled ? widget.onPressed : null,
            style: ButtonStyle(
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? disabledBackground
                    : background,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.disabled)
                    ? disabledForeground
                    : foreground,
              ),
              minimumSize: WidgetStatePropertyAll(Size(0, minHeight)),
              shape: WidgetStatePropertyAll(shape),
              padding: WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: (widget.expanded ? 16 : 14).w),
              ),
              // The hover fill used to be a manual white alpha swap, which
              // disappears on light backgrounds. Overlay follows the palette.
              overlayColor: WidgetStatePropertyAll(
                foreground.withValues(alpha: AppOpacity.hover),
              ),
              textStyle: WidgetStatePropertyAll(_labelStyle(foreground)),
            ),
            child: content,
          );

    final semanticLabel = widget.label ??
        (widget.icon is Icon ? (widget.icon! as Icon).semanticLabel : null);

    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel,
      child: MouseRegion(
        // Both handlers are gated on `enabled`. Previously `onExit` was
        // unconditional, so if `onPressed` became null (or the widget
        // unmounted) while the pointer was inside, it called `setState` on a
        // disposed State.
        onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
        onExit: enabled ? (_) => setState(() => _hovered = false) : null,
        cursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: AnimatedScale(
          scale: enabled && _hovered ? 1.02 : 1,
          duration: AppMotion.of(context, AppMotion.fast),
          curve: Curves.easeOut,
          child: widget.expanded
              ? SizedBox(width: double.infinity, child: button)
              : button,
        ),
      ),
    );
  }

  TextStyle _labelStyle(Color foreground) => TextStyle(
        color: foreground,
        fontSize: widget.small ? 12.spMax : 14.spMax,
        fontWeight: FontWeight.w600,
      );

  /// The label and icon stay in place while [AppButton.loading] is true.
  ///
  /// The previous version replaced the entire child with a bare 18px spinner,
  /// so a button labelled "Save" became an anonymous circle and the tap target
  /// shrank to 18px. A screen reader also had no way to know the control was
  /// busy.
  Widget _content(Color foreground) {
    final spinner = SizedBox(
      width: 14.r,
      height: 14.r,
      child: CircularProgressIndicator(strokeWidth: 2, color: foreground),
    );

    return Row(
      mainAxisSize: widget.expanded ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.loading) ...[
          spinner,
          if (widget.icon != null || widget.label != null)
            SizedBox(width: 8.w),
        ] else if (widget.icon != null) ...[
          widget.icon!,
          SizedBox(width: 8.w),
        ],
        if (widget.label != null)
          // Flexible so a long translation (or a wide fallback font) wraps
          // inside the button instead of overflowing the Row.
          Flexible(
            child: Text(
              widget.label!,
              textAlign: TextAlign.center,
              softWrap: true,
            ),
          ),
      ],
    );
  }
}
