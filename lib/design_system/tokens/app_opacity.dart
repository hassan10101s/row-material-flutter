/// Opacity scale.
///
/// The design system and the feature screens were using 14 different ad-hoc
/// alpha values (0.03, 0.06, 0.08, 0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.35,
/// 0.4, 0.5, 0.9, ...), each typed inline. Naming them makes it obvious when a
/// value is a deliberate emphasis level rather than a one-off, and gives
/// disabled/hover/surface states a single place to be tuned from.
class AppOpacity {
  /// Barely-there tint: card shadow, hairline decoration.
  static const double faint = 0.06;

  /// Resting state for a surface that is present but not interactive.
  static const double subtle = 0.12;

  /// Hover / pressed fill over a colored surface.
  static const double hover = 0.12;

  /// Emphasis: secondary icon, placeholder text.
  static const double muted = 0.5;

  /// Disabled foreground. Pairs with [AppOpacity.disabledSurface] so the
  /// result still clears contrast; a foreground at 90% over a surface at 50%
  /// does not.
  static const double disabled = 0.38;

  /// Background wash for a disabled control.
  static const double disabledSurface = 0.12;

  /// Scrim behind a modal route or the mobile drawer.
  static const double scrim = 0.32;

  /// Outline of a filled badge or chip.
  static const double outline = 0.4;
}
