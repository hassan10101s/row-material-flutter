import 'package:flutter/material.dart';

/// Spacing scale.
class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  /// Standard page gutter.
  static const double page = 24;
  /// 32. The previous scale had both `xxl = 24` (a duplicate of [page] with
  /// zero call sites) and `xxxl = 32`; the duplicate step is gone.
  static const double xxxl = 32;
}

class AppRadii {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  /// Fully rounded (pills, avatars, status badges).
  static const double pill = 999;
}

/// Elevation.
///
/// Shadows take a foreground tint rather than a baked-in navy. The previous
/// `AppShadows.card` hardcoded the light `surfaceDeep` (#071528), which made it
/// invisible against the dark surface — and `AppCard` ignored the token
/// entirely, re-declaring a *different* shadow inline (0xFF vs 0x0A alpha,
/// offset 3 vs 4). One definition, used by every elevated surface.
class AppShadows {
  /// Standard card / dialog shadow. Pass the brightness so the tint tracks
  /// the mode.
  static List<BoxShadow> card(Brightness brightness) {
    final tint = brightness == Brightness.dark
        ? const Color(0xFF000000)
        : const Color(0xFF071528);
    return [
      BoxShadow(
        color: tint.withValues(alpha: 0.45),
        blurRadius: 12,
        offset: const Offset(0, 3),
      ),
    ];
  }

  /// Heavier lift for modal surfaces and the transient feedback banner.
  static List<BoxShadow> elevated(Brightness brightness) {
    final tint = brightness == Brightness.dark
        ? const Color(0xFF000000)
        : const Color(0xFF071528);
    return [
      BoxShadow(
        color: tint.withValues(alpha: 0.55),
        blurRadius: 24,
        offset: const Offset(0, 8),
      ),
    ];
  }
}
