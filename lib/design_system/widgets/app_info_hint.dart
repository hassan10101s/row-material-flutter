import 'package:flutter/material.dart';
import './app_tooltip.dart';

import 'app_adaptive.dart';
import '../tokens/app_colors.dart';
import 'app_info_button.dart';

/// The single entry point for small helper info across both form factors:
///
/// * Desktop: a hover [Tooltip] (`AppInfoButton`'s bubble idiom) — the pointer
///   is always available, so the affordance can stay out of the layout and
///   the info never steals a tap.
/// * Phone: an explicitly visible, tappable button (`AppInfoButton`) that
///   opens the info on press — phones have no hover, so the affordance must
///   be clear and the reveal be a tap, never a long-press guess.
///
/// [onTap] is a desktop-only extra (e.g. also navigating to a filtered list
/// when clicking the info trigger); on a phone the tap is reserved for
/// showing the info itself.
class AppInfoHint extends StatelessWidget {
  const AppInfoHint({
    super.key,
    required this.message,
    this.label,
    this.icon,
    this.accent,
    this.onTap,
    this.waitDuration = const Duration(milliseconds: 350),
  });

  /// The info text. Shown on hover (desktop) or on press (phone).
  final String message;

  /// Short accessibility/tooltip label for the trigger itself
  /// (e.g. "تحليل الخامة"); falls back to [message] on phones.
  final String? label;

  final IconData? icon;
  final Color? accent;

  /// Optional desktop action performed with a click on the trigger; ignored
  /// on phones where the tap reveals the info instead.
  final void Function()? onTap;

  final Duration waitDuration;

  @override
  Widget build(BuildContext context) {
    if (appUsesDesktopChrome(context)) {
      return AppTooltip(
        message: message,
        waitDuration: waitDuration,
        child: IconButton(
          tooltip: label,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          onPressed: onTap,
          icon: Icon(
            icon ?? Icons.help_outline,
            size: 18,
            color: accent ?? AppColors.textMuted,
          ),
        ),
      );
    }
    return AppInfoButton(
      message: message,
      label: label ?? message,
      icon: icon,
      accent: accent,
    );
  }
}
