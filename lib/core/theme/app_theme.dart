import 'package:flutter/material.dart';

import '../../design_system/tokens/app_palette.dart';
import '../../design_system/tokens/app_text_theme.dart';

/// App themes (light + dark) built from the shared design tokens and the
/// Cairo typeface. Mirrors the Vue `styles.css` tokens.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final palette = brightness == Brightness.light ? AppPalette.light : AppPalette.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: palette.primary,
      brightness: brightness,
      primary: palette.primary,
      secondary: palette.accent,
      surface: palette.surface,
      error: palette.danger,
    );
    final base = ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
      fontFamily: AppTextTheme.cairoFontFamily,
      textTheme: AppTextTheme.build(),
      dividerTheme: DividerThemeData(
        color: palette.borderMuted,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: palette.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: palette.borderMuted),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.surface,
        foregroundColor: palette.textStrong,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: palette.surface,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: palette.primary, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.primary,
          side: BorderSide(color: palette.primary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: palette.surfaceDeep,
        contentTextStyle: TextStyle(color: palette.textStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        titleTextStyle: TextStyle(
          color: palette.textStrong,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: palette.textMuted,
        textColor: palette.textStrong,
      ),
      dataTableTheme: DataTableThemeData(
        headingTextStyle: TextStyle(
          color: palette.textMuted,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        dataTextStyle: TextStyle(
          color: palette.textStrong,
          fontSize: 13.5,
        ),
      ),
    );
    return base;
  }
}