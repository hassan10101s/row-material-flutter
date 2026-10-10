import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'app_font_weights.dart';

/// Built text theme using the Cairo typeface.
class AppTextTheme {
  static const String cairoFontFamily = 'Cairo';

  /// [color] is the strong body-text color *for the brightness being built*.
  ///
  /// It is a parameter rather than a read of `AppColors.textStrong` because
  /// `AppTheme` builds both themes in the same pass, while `AppColors` resolves
  /// against one mutable static: reading it here gave the dark theme the light
  /// theme's (dark) text color.
  static TextTheme build(Color color) {
    final base = TextTheme(
      displaySmall: TextStyle(
        fontSize: 34.spMax,
        fontWeight: AppFontWeights.bold,
      ),
      headlineMedium: TextStyle(
        fontSize: 26.spMax,
        fontWeight: AppFontWeights.bold,
      ),
      headlineSmall: TextStyle(
        fontSize: 22.spMax,
        fontWeight: AppFontWeights.bold,
      ),
      titleLarge: TextStyle(
        fontSize: 20.spMax,
        fontWeight: AppFontWeights.bold,
      ),
      titleMedium: TextStyle(
        fontSize: 17.spMax,
        fontWeight: AppFontWeights.semiBold,
      ),
      titleSmall: TextStyle(
        fontSize: 15.spMax,
        fontWeight: AppFontWeights.semiBold,
      ),
      bodyLarge: TextStyle(
        fontSize: 16.spMax,
        fontWeight: AppFontWeights.normal,
      ),
      bodyMedium: TextStyle(
        fontSize: 14.spMax,
        fontWeight: AppFontWeights.normal,
      ),
      bodySmall: TextStyle(
        fontSize: 12.spMax,
        fontWeight: AppFontWeights.normal,
      ),
      labelLarge: TextStyle(
        fontSize: 14.spMax,
        fontWeight: AppFontWeights.semiBold,
      ),
      labelMedium: TextStyle(
        fontSize: 12.spMax,
        fontWeight: AppFontWeights.medium,
      ),
      labelSmall: TextStyle(
        fontSize: 11.spMax,
        fontWeight: AppFontWeights.medium,
      ),
    );
    return base.apply(
      fontFamily: cairoFontFamily,
      bodyColor: color,
      displayColor: color,
    );
  }

  /// Smallest text scale the app honours.
  ///
  /// Allowing a little shrink below 1.0 keeps the dense reference and lab
  /// tables usable on a small window; it does not put anyone at a disadvantage,
  /// because no one is forced to use it.
  static const double minTextScaleFactor = 0.9;

  /// Largest text scale the app honours.
  ///
  /// This is the value that actually protects the layout. `AppField`,
  /// `AppStatusBadge` and the `DataTable` header/footer rows are sized from
  /// their text, and several screens have a fixed-height row slot, so an
  /// unbounded 2x scale overflowed them with `RenderFlex` /
  /// `RenderParagraph` errors. The cap trades some of the platform's top-end
  /// range for layouts that stay intact — which is why the flexible-widget half
  /// of this change matters more than the cap itself.
  static const double maxTextScaleFactor = 1.3;

  /// The app-wide text scale, capped to the range above.
  ///
  /// Applied in two places, and both are load-bearing:
  ///
  ///  * Below `ScreenUtilInit`, so the `sp`-derived sizes in [build] scale by
  ///    the same clamped factor the rest of the text does. `ScreenUtil.init`
  ///    latches its text scale during `initState`, so clamping only inside
  ///    `MaterialApp` would leave the theme scaling at the raw system value
  ///    while the body text used the capped one.
  ///  * In `MaterialApp.builder`, because `MaterialApp` builds its own
  ///    `MediaQuery` from the view rather than inheriting the ambient one, so a
  ///    clamp placed above it would be discarded.
  static TextScaler clampScaler(BuildContext context) =>
      clamp(MediaQuery.textScalerOf(context));

  /// The cap itself, as a pure function of the incoming scale.
  ///
  /// Split from [clampScaler] so the bounds are testable without pumping a
  /// widget tree to obtain a `BuildContext`.
  static TextScaler clamp(TextScaler scaler) => scaler.clamp(
        minScaleFactor: minTextScaleFactor,
        maxScaleFactor: maxTextScaleFactor,
      );

  /// Pernit-style clamped font size: `size.sp` bounded to `[min, max]`.
  ///
  /// Use for mobile-first text that must stay readable on a 360dp phone
  /// without exploding on a wide desktop window. Desktop call sites keep
  /// using `.spMax`; mobile cards/wizards prefer this helper.
  static double clamped(double size, double min, double max) {
    final scaled = size.sp;
    return scaled.clamp(min, max).toDouble();
  }
}
