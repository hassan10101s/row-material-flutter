import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_contrast.dart';
import 'app_chart_palette.dart';

/// Data modeling shared by every DS chart primitive.
///
/// - [AppChartSlice]: one donut segment (composition).
/// - [AppChartPoint]: one x position on a bar/line axis, with a short axis
///   label and a rich tooltip line.
class AppChartSlice {
  const AppChartSlice({
    required this.label,
    required this.value,
    required this.color,
    this.tooltip,
  });

  final String label;
  final double value;
  final Color color;

  /// Optional richer tooltip text; defaults to `label: value`.
  final String? tooltip;
}

class AppChartPoint {
  const AppChartPoint({
    required this.label,
    required this.value,
    this.color,
    this.tooltip,
  });

  /// Short label under the axis (a single word, e.g. the month name).
  final String label;

  final double value;

  /// Bar color override; null = the primary series color.
  final Color? color;

  /// Extra tooltip text appended after `label • value` (e.g. `approval: 94%`).
  final String? tooltip;
}

/// Empty-state placeholder inside a chart area.
class AppChartEmpty extends StatelessWidget {
  const AppChartEmpty({super.key, required this.message, this.height = 200});

  final String message;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Center(
        child: Text(
          message,
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      ),
    );
  }
}

/// Donut chart with theme-aware slice titles.
///
/// Zero-valued slices are dropped automatically so a fully empty chart never
/// divides by zero and partial data never renders a degenerate 100% slice.
class AppDonutChart extends StatelessWidget {
  const AppDonutChart({
    super.key,
    required this.slices,
    this.centerText,
    this.height = 200,
    this.centerSpaceRadius = 42,
    this.showSectionTitles = true,
  });

  final List<AppChartSlice> slices;

  /// Text drawn in the hole when the chart is empty.
  final String? centerText;
  final double height;
  final double centerSpaceRadius;
  final bool showSectionTitles;

  @override
  Widget build(BuildContext context) {
    final visible = slices.where((s) => s.value > 0).toList();
    return SizedBox(
      height: height,
      child: visible.isEmpty
          ? AppChartEmpty(message: centerText ?? '—', height: height)
          : PieChart(
              PieChartData(
                centerSpaceRadius: centerSpaceRadius,
                sectionsSpace: 2,
                sections: [
                  for (final s in visible)
                    PieChartSectionData(
                      value: s.value,
                      color: s.color,
                      title: showSectionTitles
                          ? s.value.toInt().toString()
                          : '',
                      titleStyle: TextStyle(
                        color: AppContrast.on(s.color),
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                      radius: height / 2 - 8,
                    ),
                ],
              ),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
            ),
    );
  }
}

/// Value formatter: integers without decimals, otherwise 1-dp.
String formatChartValue(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

/// Bottom-axis label: first word of the point label, muted compact style.
Widget appChartBottomLabel(
  double v,
  List<AppChartPoint> points,
  TextStyle style,
) {
  final i = v.toInt();
  if (i < 0 || i >= points.length) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Text(points[i].label.split(' ').first, style: style),
  );
}

/// Vertical bar chart for count series (monthly volumes, supplier counts…).
/// Tooltips and axis labels are theme-aware; empty bars render as muted
/// placeholders so gaps in the data stay visible.
class AppCountBarChart extends StatelessWidget {
  const AppCountBarChart({
    super.key,
    required this.points,
    this.height = 220,
    this.unit,
    this.maxY,
    this.barWidth = 18,
  });

  final List<AppChartPoint> points;
  final double height;

  /// Suffix word for tooltip values, e.g. 'فحص / inspections'.
  final String? unit;

  /// Locked Y axis top; null = auto (1.2 × max, min 10).
  final double? maxY;
  final double barWidth;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return AppChartEmpty(message: '—', height: height);
    }
    final maxVol = points.fold<double>(0, (m, p) => p.value > m ? p.value : m);
    final top = maxY ?? (maxVol == 0 ? 10 : maxVol * 1.2);
    final tooltipStyle = AppChartPalette.tooltipStyle();
    final axisStyle = appChartAxisStyle();
    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: top,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => AppChartPalette.tooltipBackground,
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final i = group.x.toInt();
                if (i < 0 || i >= points.length) return null;
                final p = points[i];
                final unitText = (unit ?? '').trim();
                return BarTooltipItem(
                  '${p.label}\n${formatChartValue(rod.toY)}'
                  '${unitText.isEmpty ? '' : ' $unitText'}'
                  '${p.tooltip == null ? '' : ' • ${p.tooltip}'}',
                  tooltipStyle,
                  textAlign: TextAlign.center,
                );
              },
            ),
          ),
          barGroups: [
            for (var i = 0; i < points.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: points[i].value,
                    color: points[i].value == 0
                        ? AppColors.borderMuted
                        : (points[i].color ?? AppColors.primary),
                    width: barWidth,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
          ],
          titlesData: appChartTitles().copyWith(
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 36),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, _) =>
                    appChartBottomLabel(v, points, axisStyle),
              ),
            ),
          ),
          gridData: appChartGrid(),
          borderData: appChartBorder(),
        ),
      ),
    );
  }
}

/// Line chart for percentage series with an optional dashed moving-average
/// overlay (acceptance-rate + forecast pattern).
class AppPercentLineChart extends StatelessWidget {
  const AppPercentLineChart({
    super.key,
    required this.points,
    this.height = 200,
    this.movingAvg,
    this.yMax = 100,
    this.yInterval = 25,
  });

  final List<AppChartPoint> points;
  final double height;

  /// Dashed overlay series aligned to [points] by index; a null entry skips
  /// the corresponding spot (moving-average head/tail convention).
  final List<double?>? movingAvg;

  final double yMax;
  final double yInterval;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return AppChartEmpty(message: '—', height: height);
    }
    final tooltipStyle = AppChartPalette.tooltipStyle();
    final axisStyle = appChartAxisStyle();
    return SizedBox(
      height: height,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: yMax,
          lineTouchData: LineTouchData(
            touchTooltipData: LineTouchTooltipData(
              getTooltipColor: (_) => AppChartPalette.tooltipBackground,
              getTooltipItems: (spots) => [
                for (final s in spots)
                  if (s.x.toInt() >= 0 && s.x.toInt() < points.length)
                    LineTooltipItem(
                      '${points[s.x.toInt()].label}\n'
                      '${s.y.toStringAsFixed(1)}%',
                      tooltipStyle,
                      textAlign: TextAlign.center,
                    )
                  else
                    null,
              ],
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [
                for (var i = 0; i < points.length; i++)
                  FlSpot(i.toDouble(), points[i].value),
              ],
              isCurved: true,
              color: AppColors.success,
              barWidth: 3,
              dotData: const FlDotData(show: true),
            ),
            if (movingAvg != null)
              LineChartBarData(
                spots: [
                  for (var i = 0; i < movingAvg!.length; i++)
                    if (movingAvg![i] != null)
                      FlSpot(i.toDouble(), movingAvg![i]!),
                ],
                isCurved: true,
                color: AppColors.info,
                barWidth: 2,
                dashArray: [6, 4],
                dotData: const FlDotData(show: false),
              ),
          ],
          titlesData: appChartTitles().copyWith(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 40,
                interval: yInterval,
                getTitlesWidget: (v, _) =>
                    Text('${v.toInt()}%', style: axisStyle),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, _) => appChartBottomLabel(
                  v,
                  points,
                  TextStyle(fontSize: 10, color: AppColors.textMuted),
                ),
              ),
            ),
          ),
          gridData: appChartGrid(),
          borderData: appChartBorder(),
        ),
      ),
    );
  }
}
