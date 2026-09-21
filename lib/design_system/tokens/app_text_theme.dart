import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'app_colors.dart';
import 'app_font_weights.dart';

/// Built text theme using the Cairo typeface.
class AppTextTheme {
  static const String cairoFontFamily = 'Cairo';

  static TextTheme build() {
    final base = TextTheme(
      displaySmall: TextStyle(fontSize: 34.spMax, fontWeight: AppFontWeights.bold),
      headlineMedium: TextStyle(fontSize: 26.spMax, fontWeight: AppFontWeights.bold),
      headlineSmall: TextStyle(fontSize: 22.spMax, fontWeight: AppFontWeights.bold),
      titleLarge: TextStyle(fontSize: 20.spMax, fontWeight: AppFontWeights.bold),
      titleMedium: TextStyle(fontSize: 17.spMax, fontWeight: AppFontWeights.semiBold),
      titleSmall: TextStyle(fontSize: 15.spMax, fontWeight: AppFontWeights.semiBold),
      bodyLarge: TextStyle(fontSize: 16.spMax, fontWeight: AppFontWeights.normal),
      bodyMedium: TextStyle(fontSize: 14.spMax, fontWeight: AppFontWeights.normal),
      bodySmall: TextStyle(fontSize: 12.spMax, fontWeight: AppFontWeights.normal),
      labelLarge: TextStyle(fontSize: 14.spMax, fontWeight: AppFontWeights.semiBold),
      labelMedium: TextStyle(fontSize: 12.spMax, fontWeight: AppFontWeights.medium),
      labelSmall: TextStyle(fontSize: 11.spMax, fontWeight: AppFontWeights.medium),
    );
    return base.apply(
      fontFamily: cairoFontFamily,
      bodyColor: AppColors.textStrong,
      displayColor: AppColors.textStrong,
    );
  }
}