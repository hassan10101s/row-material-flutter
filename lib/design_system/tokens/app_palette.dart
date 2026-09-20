import 'package:flutter/material.dart';

/// Value-object holding the currently active AppColors set (mirrors
/// AppColorScheme in morattab but kept flat for simplicity).
class AppPalette {
  final Color background;
  final Color surface;
  final Color surfaceSoft;
  final Color surfaceDeep;
  final Color primary;
  final Color primaryDeep;
  final Color accent;
  final Color success;
  final Color warning;
  final Color partial;
  final Color danger;
  final Color info;
  final Color textStrong;
  final Color textMuted;
  final Color border;
  final Color borderMuted;

  const AppPalette({
    required this.background,
    required this.surface,
    required this.surfaceSoft,
    required this.surfaceDeep,
    required this.primary,
    required this.primaryDeep,
    required this.accent,
    required this.success,
    required this.warning,
    required this.partial,
    required this.danger,
    required this.info,
    required this.textStrong,
    required this.textMuted,
    required this.border,
    required this.borderMuted,
  });

  static const AppPalette light = AppPalette(
    background: Color(0xFFF3F6FB),
    surface: Color(0xFFFFFFFF),
    surfaceSoft: Color(0xFFF1F5FB),
    surfaceDeep: Color(0xFF071528),
    primary: Color(0xFF0284C7),
    primaryDeep: Color(0xFF015A8A),
    accent: Color(0xFF6366F1),
    success: Color(0xFF10B981),
    warning: Color(0xFFF59E0B),
    partial: Color(0xFFF97316),
    danger: Color(0xFFEF4444),
    info: Color(0xFF3B82F6),
    textStrong: Color(0xFF0F172A),
    textMuted: Color(0xFF64748B),
    border: Color(0xFFD9E1EC),
    borderMuted: Color(0xFFE8ECF1),
  );

  static const AppPalette dark = AppPalette(
    background: Color(0xFF070B14),
    surface: Color(0xFF0F1626),
    surfaceSoft: Color(0xFF101A2E),
    surfaceDeep: Color(0xFF05070D),
    primary: Color(0xFF38BDF8),
    primaryDeep: Color(0xFF0EA5E9),
    accent: Color(0xFF818CF8),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    partial: Color(0xFFFB923C),
    danger: Color(0xFFF87171),
    info: Color(0xFF60A5FA),
    textStrong: Color(0xFFE7EDF5),
    textMuted: Color(0xFF8CA0B8),
    border: Color(0xFF1E2B3F),
    borderMuted: Color(0xFF162238),
  );
}