import 'package:flutter/material.dart';

/// Semantic color tokens (light + dark) mirroring the CSS design tokens.
class AppColors {
  static Brightness brightness = Brightness.light;

  // Light palette
  static const Color lightBackground = Color(0xFFF3F6FB);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceSoft = Color(0xFFF1F5FB);
  static const Color lightSurfaceDeep = Color(0xFF071528);

  static const Color lightPrimary = Color(0xFF0284C7);
  static const Color lightPrimaryDeep = Color(0xFF015A8A);
  static const Color lightAccent = Color(0xFF6366F1);
  static const Color lightSuccess = Color(0xFF10B981);
  static const Color lightWarning = Color(0xFFF59E0B);
  static const Color lightPartial = Color(0xFFF97316);
  static const Color lightDanger = Color(0xFFEF4444);
  static const Color lightInfo = Color(0xFF3B82F6);
  static const Color lightTextStrong = Color(0xFF0F172A);
  static const Color lightTextMuted = Color(0xFF64748B);
  static const Color lightBorder = Color(0xFFD9E1EC);
  static const Color lightBorderMuted = Color(0xFFE8ECF1);

  // Dark palette
  static const Color darkBackground = Color(0xFF0F172A);
  static const Color darkSurface = Color(0xFF1E293B);
  static const Color darkSurfaceSoft = Color(0xFF1B2537);
  static const Color darkSurfaceDeep = Color(0xFF0D1424);
  static const Color darkPrimary = Color(0xFF38BDF8);
  static const Color darkPrimaryDeep = Color(0xFF0EA5E9);
  static const Color darkAccent = Color(0xFF818CF8);
  static const Color darkSuccess = Color(0xFF34D399);
  static const Color darkWarning = Color(0xFFFBBF24);
  static const Color darkPartial = Color(0xFFFB923C);
  static const Color darkDanger = Color(0xFFF87171);
  static const Color darkInfo = Color(0xFF60A5FA);
  static const Color darkTextStrong = Color(0xFFF1F5F9);
  static const Color darkTextMuted = Color(0xFF94A3B8);
  static const Color darkBorder = Color(0xFF334155);
  static const Color darkBorderMuted = Color(0xFF243147);

  // Active colors resolved by brightness
  static Color get background => brightness == Brightness.dark ? darkBackground : lightBackground;
  static Color get surface => brightness == Brightness.dark ? darkSurface : lightSurface;
  static Color get surfaceSoft => brightness == Brightness.dark ? darkSurfaceSoft : lightSurfaceSoft;
  static Color get surfaceDeep => brightness == Brightness.dark ? darkSurfaceDeep : lightSurfaceDeep;
  static Color get primary => brightness == Brightness.dark ? darkPrimary : lightPrimary;
  static Color get primaryDeep => brightness == Brightness.dark ? darkPrimaryDeep : lightPrimaryDeep;
  static Color get accent => brightness == Brightness.dark ? darkAccent : lightAccent;
  static Color get success => brightness == Brightness.dark ? darkSuccess : lightSuccess;
  static Color get warning => brightness == Brightness.dark ? darkWarning : lightWarning;
  static Color get partial => brightness == Brightness.dark ? darkPartial : lightPartial;
  static Color get danger => brightness == Brightness.dark ? darkDanger : lightDanger;
  static Color get info => brightness == Brightness.dark ? darkInfo : lightInfo;
  static Color get textStrong => brightness == Brightness.dark ? darkTextStrong : lightTextStrong;
  static Color get textMuted => brightness == Brightness.dark ? darkTextMuted : lightTextMuted;
  static Color get border => brightness == Brightness.dark ? darkBorder : lightBorder;
  static Color get borderMuted => brightness == Brightness.dark ? darkBorderMuted : lightBorderMuted;
}

/// Status tone palette used by status pills and decision badges.
class StatusColors {
  static Color success(BuildContext context) => AppColors.success;
  static Color warning(BuildContext context) => AppColors.warning;
  static Color partial(BuildContext context) => AppColors.partial;
  static Color danger(BuildContext context) => AppColors.danger;
  static Color neutral(BuildContext context) => AppColors.textMuted;

  static Color forStatus(String status, BuildContext context) {
    switch (status) {
      case 'APPROVED':
      case 'CONDITIONAL_APPROVAL':
        return AppColors.success;
      case 'PARTIAL_REJECTION':
        return AppColors.partial;
      case 'FULL_REJECTION':
        return AppColors.danger;
      default:
        return AppColors.info;
    }
  }
}