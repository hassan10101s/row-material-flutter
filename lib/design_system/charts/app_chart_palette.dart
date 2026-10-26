import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_contrast.dart';

/// Ordered categorical palette for multi-series charts, composed from the
/// semantic design tokens so light/dark and brand meaning stay consistent.
/// Never use brand colors (whatsapp/pdf) in data series.
class AppChartPalette {
  const AppChartPalette._();

  /// Semantic order for categorical series: blue→green→amber→indigo→info→
  /// orange→red and back to the deep primary shade for series beyond 7.
  static final List<Color> _order = [
    AppColors.primary,
    AppColors.success,
    AppColors.warning,
    AppColors.accent,
    AppColors.info,
    AppColors.partial,
    AppColors.danger,
    AppColors.primaryDeep,
  ];

  /// First [count] series colors, cycling past the end so long series never
  /// crash (more than 8 series on one chart is a UX smell regardless).
  static List<Color> series(int count) => [
    for (var i = 0; i < count; i++) _order[i % _order.length],
  ];

  /// Color for the [index]-th categorical series (cycling).
  static Color forIndex(int index) => _order[index % _order.length];

  /// Tooltip surface constant across modes (depth-based, not brightness-based)
  /// so the readable text color stays white in both light and dark themes.
  static Color get tooltipBackground => AppColors.surfaceDeep;

  /// Theme-aware chart tooltip text style (the fl_chart default ignores the
  /// app theme and hard-codes white-on-navy).
  static TextStyle tooltipStyle() => TextStyle(
    color: AppContrast.on(AppColors.surfaceDeep),
    fontWeight: FontWeight.w600,
    fontSize: 11,
    leadingDistribution: TextLeadingDistribution.even,
  );
}

/// Shared axis-label style: theme muted text at compact size for hour/month
/// and year labels under bars and lines.
TextStyle appChartAxisStyle() => TextStyle(
  color: AppColors.textMuted,
  fontSize: 11.spMax,
  fontWeight: FontWeight.w500,
);

/// Standard grid + border configuration shared by bar and line charts.
FlGridData appChartGrid() =>
    FlGridData(show: true, drawVerticalLine: false, horizontalInterval: 1);

FlBorderData appChartBorder() => FlBorderData(show: false);

/// Hides every title axis except the explicit ones a chart enables.
FlTitlesData appChartTitles() => FlTitlesData(
  topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
  rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
);
