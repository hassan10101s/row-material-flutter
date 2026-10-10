import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../design_system/tokens/app_contrast.dart';
import '../../design_system/tokens/app_font_weights.dart';
import '../../design_system/tokens/app_opacity.dart';
import '../../design_system/tokens/app_palette.dart';
import '../../design_system/tokens/app_spacing.dart';
import '../../design_system/tokens/app_text_theme.dart';

/// App themes (light + dark) built from the shared design tokens and the
/// Cairo typeface.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final palette = AppPalette.of(brightness);
    final scheme = _colorScheme(palette, brightness);

    return ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
      fontFamily: AppTextTheme.cairoFontFamily,
      // 'sans-serif' is a CSS generic family name and resolves to nothing on
      // Windows; it was a no-op entry. Segoe UI is the real fallback for
      // glyphs Cairo does not cover.
      fontFamilyFallback: const ['Segoe UI'],
      textTheme: AppTextTheme.build(palette.textStrong),
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
          borderRadius: BorderRadius.circular(AppRadii.md.r),
          side: BorderSide(color: palette.borderMuted),
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: palette.surface,
        foregroundColor: palette.textStrong,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: palette.textStrong,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 18.spMax,
          fontWeight: AppFontWeights.bold,
        ),
      ),
      inputDecorationTheme: _inputDecoration(palette),
      filledButtonTheme: _filledButton(palette),
      outlinedButtonTheme: _outlinedButton(palette),
      textButtonTheme: _textButton(palette),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg.r),
        ),
        titleTextStyle: TextStyle(
          color: palette.textStrong,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 18.spMax,
          fontWeight: AppFontWeights.bold,
        ),
        contentTextStyle: TextStyle(
          color: palette.textStrong,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 14.spMax,
          height: 1.5,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: palette.textMuted,
        textColor: palette.textStrong,
      ),
      dataTableTheme: _dataTable(palette),

      // --- Component themes -------------------------------------------------
      // These were all falling through to Material 3 defaults derived from the
      // cyan seed, so Tooltip, Chip, Switch, DropdownButton, PopupMenuButton and
      // the progress indicators did not read as part of this palette. The app
      // renders 24 DropdownButtons, 9 chips, 5 popup menus, 17 progress
      // indicators and 3 tooltips, so theming them here improves every screen
      // at once without touching a single feature file.

      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        textStyle: TextStyle(
          color: scheme.onInverseSurface,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 12.spMax,
        ),
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: palette.surfaceSoft,
        selectedColor: palette.primary.withValues(alpha: AppOpacity.subtle),
        side: BorderSide(color: palette.border),
        labelStyle: TextStyle(
          color: palette.textStrong,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 12.spMax,
          fontWeight: AppFontWeights.medium,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : palette.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.primary
              : palette.surfaceSoft,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : palette.border,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.primary,
        linearTrackColor: palette.surfaceSoft,
        circularTrackColor: palette.surfaceSoft,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(color: palette.borderMuted),
        ),
        textStyle: TextStyle(
          color: palette.textStrong,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 14.spMax,
        ),
      ),
      // The app uses `DropdownButtonFormField` 20 times; its field styling comes
      // from `inputDecorationTheme` above.
      menuTheme: const MenuThemeData(),
      // The pre-M3 `DropdownButton` family. `dropdownTheme` /
      // `dropdownButtonTheme` were removed from ThemeData in this Flutter, so
      // dropdowns inherit from `inputDecorationTheme` and `menuTheme` instead.
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          palette.textMuted.withValues(alpha: AppOpacity.muted),
        ),
        radius: const Radius.circular(AppRadii.pill),
        thickness: const WidgetStatePropertyAll(8),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: palette.textMuted,
        collapsedIconColor: palette.textMuted,
        textColor: palette.textStrong,
        collapsedTextColor: palette.textStrong,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: palette.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
      ),
      iconTheme: IconThemeData(color: palette.textMuted, size: 22.r),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: palette.primary.withValues(alpha: 0.14),
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: AppTextTheme.cairoFontFamily,
            fontSize: 12.spMax,
            fontWeight: states.contains(WidgetState.selected)
                ? AppFontWeights.semiBold
                : AppFontWeights.medium,
            color: states.contains(WidgetState.selected)
                ? palette.primary
                : palette.textMuted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22.r,
            color: states.contains(WidgetState.selected)
                ? palette.primary
                : palette.textMuted,
          ),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadiusDirectional.horizontal(
            start: Radius.zero,
            end: Radius.circular(AppRadii.lg),
          ),
        ),
        width: 320,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadii.lg.r),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.surfaceDeep,
        contentTextStyle: TextStyle(
          color: Colors.white,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 13.spMax,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        behavior: SnackBarBehavior.floating,
      ),

      // Interaction feedback. Without these the defaults come from the seed
      // palette and do not match the surfaces they paint over.
      hoverColor: palette.primary.withValues(alpha: AppOpacity.hover),
      focusColor: palette.primary.withValues(alpha: AppOpacity.hover),
      splashColor: palette.primary.withValues(alpha: AppOpacity.subtle),
      highlightColor: palette.primary.withValues(alpha: AppOpacity.faint),
    );
  }

  /// The Material color roles, with every `on*` pair derived from the color it
  /// actually paints on.
  ///
  /// `ColorScheme.fromSeed` overrides are applied last, so any role that is
  /// overridden here would otherwise leave its counterpart `on*` role still
  /// describing the *seed*-derived color. Deriving the foreground with
  /// [AppContrast.on] means white text can no longer land on the dark
  /// palette's light blue primary.
  static ColorScheme _colorScheme(AppPalette palette, Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: palette.primary,
      brightness: brightness,
    );

    return base.copyWith(
      primary: palette.primary,
      onPrimary: AppContrast.on(palette.primary),
      primaryContainer: palette.primary.withValues(alpha: 0.12),
      onPrimaryContainer: palette.textStrong,
      secondary: palette.accent,
      onSecondary: AppContrast.on(palette.accent),
      tertiary: palette.info,
      onTertiary: AppContrast.on(palette.info),
      error: palette.danger,
      onError: AppContrast.on(palette.danger),
      surface: palette.surface,
      onSurface: palette.textStrong,
      // Success/warning/partial are not ColorScheme roles, so widgets that
      // need a readable foreground for them use AppContrast.on directly.
      outline: palette.border,
      outlineVariant: palette.borderMuted,
    );
  }

  /// Every border state. Previously only `enabledBorder` and `focusedBorder`
  /// were set, so a bare `TextField` in an error state drew the framework's
  /// default Material 3 red instead of `AppColors.danger` — a different field
  /// style from the one `AppField` renders.
  static InputDecorationTheme _inputDecoration(AppPalette palette) {
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.sm.r),
          borderSide: BorderSide(color: color, width: width),
        );

    return InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: palette.surface,
      contentPadding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
      enabledBorder: border(palette.border),
      focusedBorder: border(palette.primary, 1.6),
      errorBorder: border(palette.danger),
      focusedErrorBorder: border(palette.danger, 1.6),
      disabledBorder: border(palette.borderMuted),
      errorStyle: TextStyle(
        color: palette.danger,
        fontFamily: AppTextTheme.cairoFontFamily,
        fontSize: 12.spMax,
      ),
      labelStyle: TextStyle(
        color: palette.textMuted,
        fontFamily: AppTextTheme.cairoFontFamily,
        fontSize: 13.spMax,
      ),
      hintStyle: TextStyle(
        color: palette.textMuted,
        fontFamily: AppTextTheme.cairoFontFamily,
        fontSize: 14.spMax,
      ),
      helperStyle: TextStyle(
        color: palette.textMuted,
        fontFamily: AppTextTheme.cairoFontFamily,
        fontSize: 11.spMax,
      ),
      prefixIconColor: palette.textMuted,
      suffixIconColor: palette.textMuted,
    );
  }

  static FilledButtonThemeData _filledButton(AppPalette palette) =>
      FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.primary,
          // Derived, not hardcoded: white on the dark palette's #38BDF8 is
          // 2.14:1, which is unreadable.
          foregroundColor: AppContrast.on(palette.primary),
          disabledBackgroundColor:
              palette.textStrong.withValues(alpha: AppOpacity.disabledSurface),
          disabledForegroundColor:
              palette.textStrong.withValues(alpha: AppOpacity.disabled),
          minimumSize: Size(0, 42.h),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md.r),
          ),
          textStyle: TextStyle(
            fontFamily: AppTextTheme.cairoFontFamily,
            fontSize: 14.spMax,
            fontWeight: AppFontWeights.semiBold,
          ),
        ),
      );

  static OutlinedButtonThemeData _outlinedButton(AppPalette palette) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.primary,
          side: BorderSide(color: palette.primary),
          minimumSize: Size(0, 42.h),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md.r),
          ),
          textStyle: TextStyle(
            fontFamily: AppTextTheme.cairoFontFamily,
            fontSize: 14.spMax,
            fontWeight: AppFontWeights.semiBold,
          ),
        ),
      );

  static TextButtonThemeData _textButton(AppPalette palette) =>
      TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.primary,
          minimumSize: Size(0, 42.h),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md.r),
          ),
          textStyle: TextStyle(
            fontFamily: AppTextTheme.cairoFontFamily,
            fontSize: 14.spMax,
            fontWeight: AppFontWeights.semiBold,
          ),
        ),
      );

  /// DataTable is used directly by 7 screens.
  ///
  /// These are raw `TextStyle`s assigned to DataTable roles rather than
  /// `TextTheme` entries, so they do not inherit the Cairo family from
  /// `ThemeData.fontFamily` — before the family was named here, all 7 tables
  /// rendered in the engine default font.
  static DataTableThemeData _dataTable(AppPalette palette) => DataTableThemeData(
        headingTextStyle: TextStyle(
          color: palette.textMuted,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 13.spMax,
          fontWeight: AppFontWeights.semiBold,
        ),
        dataTextStyle: TextStyle(
          color: palette.textStrong,
          fontFamily: AppTextTheme.cairoFontFamily,
          fontSize: 13.5.spMax,
          // Without tabular figures, numeric columns shimmer as digits change.
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        headingRowColor: WidgetStatePropertyAll(palette.surfaceSoft),
      );
}
