import 'package:flutter/material.dart';

/// Spacing scale.
class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  /// Standard page gutter (desktop). Phones use [pageMobile].
  static const double page = 24;
  /// Phone page gutter (pernit-style 16.w padding).
  static const double pageMobile = 16;
  /// Primary mobile CTA height (pernit `PernitButton`: 52.h full-width).
  static const double mobileCtaHeight = 52;
  /// Minimum touch target (pernit clamps to 48; desktop keeps 34 via LayoutSpec).
  static const double minTouchMobile = 48;
  /// Bottom-sheet handle + content padding mirror of pernit sheet recipe.
  static const double sheetRadius = 16;
  /// 32. The previous scale had both `xxl = 24` (a duplicate of [page] with
  /// zero call sites) and `xxxl = 32`; the duplicate step is gone.
  static const double xxxl = 32;

  /// Widest content column on desktop. Wide pages (dashboard, reports, QC)
  /// center inside this so a 1080p window does not stretch cards and tables
  /// edge to edge.
  static const double pageMaxWidth = 1200;

  /// Gap between content sections (hero → actions → KPIs → tables).
  static const double sectionGap = 20;

  /// Card inner padding for data-dense surfaces.
  static const double cardPadding = 16;
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
  /// the mode. Soft modern lift: barely-there on light, deeper on dark.
  static List<BoxShadow> card(Brightness brightness) {
    final tint = brightness == Brightness.dark
        ? const Color(0xFF000000)
        : const Color(0xFF0F172A);
    return [
      BoxShadow(
        color: tint.withValues(alpha: brightness == Brightness.dark ? 0.35 : 0.06),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
      BoxShadow(
        color: tint.withValues(alpha: brightness == Brightness.dark ? 0.18 : 0.03),
        blurRadius: 4,
        offset: const Offset(0, 1),
      ),
    ];
  }

  /// Heavier lift for modal surfaces and the transient feedback banner.
  static List<BoxShadow> elevated(Brightness brightness) {
    final tint = brightness == Brightness.dark
        ? const Color(0xFF000000)
        : const Color(0xFF0F172A);
    return [
      BoxShadow(
        color: tint.withValues(alpha: brightness == Brightness.dark ? 0.5 : 0.12),
        blurRadius: 28,
        offset: const Offset(0, 10),
      ),
      BoxShadow(
        color: tint.withValues(alpha: brightness == Brightness.dark ? 0.25 : 0.05),
        blurRadius: 8,
        offset: const Offset(0, 2),
      ),
    ];
  }
}
