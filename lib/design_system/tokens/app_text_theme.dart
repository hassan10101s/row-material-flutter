import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_font_weights.dart';

/// Built text theme using the Cairo typeface.
class AppTextTheme {
  static const String cairoFontFamily = 'Cairo';

  static TextTheme build() {
    final base = const TextTheme(
      displaySmall: TextStyle(fontSize: 34, fontWeight: AppFontWeights.bold),
      headlineMedium: TextStyle(fontSize: 26, fontWeight: AppFontWeights.bold),
      headlineSmall: TextStyle(fontSize: 22, fontWeight: AppFontWeights.bold),
      titleLarge: TextStyle(fontSize: 20, fontWeight: AppFontWeights.bold),
      titleMedium: TextStyle(fontSize: 17, fontWeight: AppFontWeights.semiBold),
      titleSmall: TextStyle(fontSize: 15, fontWeight: AppFontWeights.semiBold),
      bodyLarge: TextStyle(fontSize: 16, fontWeight: AppFontWeights.normal),
      bodyMedium: TextStyle(fontSize: 14, fontWeight: AppFontWeights.normal),
      bodySmall: TextStyle(fontSize: 12, fontWeight: AppFontWeights.normal),
      labelLarge: TextStyle(fontSize: 14, fontWeight: AppFontWeights.semiBold),
      labelMedium: TextStyle(fontSize: 12, fontWeight: AppFontWeights.medium),
      labelSmall: TextStyle(fontSize: 11, fontWeight: AppFontWeights.medium),
    );
    return base.apply(
      fontFamily: cairoFontFamily,
      bodyColor: AppColors.textStrong,
      displayColor: AppColors.textStrong,
    );
  }
}