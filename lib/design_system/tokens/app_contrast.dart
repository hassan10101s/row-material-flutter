import 'dart:math' as math;

import 'package:flutter/material.dart';

/// WCAG 2.1 relative-contrast utilities.
///
/// The app builds its `ColorScheme` with `ColorScheme.fromSeed`, then overrides
/// `primary` / `secondary` / `surface` / `error` by hand. The `on*` roles
/// that come out of `fromSeed` are derived from the *seed* and therefore do
/// not match the overridden colors, so components that trust `onPrimary` get a
/// wrong foreground. Components that skip `onPrimary` altogether and hardcode
/// `Colors.white` (which `AppButton` did, for all five filled variants) are
/// worse still: white on the dark palette's `#38BDF8` is 2.14:1, well under the
/// 4.5:1 minimum.
///
/// These helpers let the theme *derive* the foreground from whatever
/// background it is actually painting, so the two can never drift apart again.
class AppContrast {
  /// Minimum contrast for normal-size body text (WCAG 2.1 AA).
  static const double aa = 4.5;

  /// Minimum contrast for large text and UI component boundaries
  /// (WCAG 2.1 AA, 18.66px bold / 24px regular and above).
  static const double aaLarge = 3.0;

  /// Relative luminance per WCAG 2.1.
  ///
  /// Input is treated as sRGB and gamma-decoded, matching the spec rather than
  /// the naive "average the channels" shortcut, which overstates contrast for
  /// mid-tone colors.
  static double luminance(Color color) {
    double channel(double component) {
      return component <= 0.03928
          ? component / 12.92
          : math.pow((component + 0.055) / 1.055, 2.4).toDouble();
    }

    return 0.2126 * channel(color.r) +
        0.7152 * channel(color.g) +
        0.0722 * channel(color.b);
  }

  /// Contrast ratio between [a] and [b], from 1.0 to 21.0.
  static double ratio(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    final lighter = math.max(la, lb);
    final darker = math.min(la, lb);
    return (lighter + 0.05) / (darker + 0.05);
  }

  /// Whether [foreground] on [background] meets [level].
  static bool passes(Color foreground, Color background, {double level = aa}) =>
      ratio(foreground, background) >= level;

  /// The readable foreground for [background]: whichever of [light] or [dark]
  /// has more contrast against it.
  ///
  /// Ties resolve to [dark]. In practice this is the only question the theme
  /// needs answered — black and white span the full luminance range, so one of
  /// them always clears 4.5:1.
  static Color on(Color background, {Color? light, Color? dark}) {
    final hi = light ?? Colors.white;
    final lo = dark ?? Colors.black;
    return ratio(hi, background) >= ratio(lo, background) ? hi : lo;
  }
}
