import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/responsive/form_factor.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../domain/nir_validation_repository.dart';
import '../cubit/nir_validation_state.dart';

/// Opens the full details window of one (خامة/منتج × تحليل) item: the
/// NIR-vs-lab scatter with both fitted lines, every accuracy metric, the
/// adjustment-mode choice (الميل فقط / الميل + القاطع) with its auto
/// reasoning, and the matched-pair table.
Future<void> showNirItemDetails(
  BuildContext context,
  NirParameterStats stats,
) {
  return showAppWindow<void>(
    context,
    title: '${stats.entityName} · ${stats.parameter}',
    subtitle: _detailsSubtitle(stats),
    icon: Icons.insights_outlined,
    size: AppWindowSize.lg,
    child: _NirItemDetails(stats: stats),
  );
}

String _detailsSubtitle(NirParameterStats stats) {
  final count = '${stats.count} ${AppText.t('نقطة مطابقة', 'matched points')}';
  final scope = NirValidationState.scopeLabel(stats.scope);
  final unit = stats.unit.trim();
  final horizon = stats.horizonStart.trim();
  final horizonLabel = horizon.isEmpty
      ? AppText.t('بلا تصفير', 'No reset')
      : '${AppText.t('التصفير', 'Reset')}: ${_displayDate(horizon)}'
          '${stats.scopedHorizon ? '' : ' (${AppText.t('عام', 'global')})'}';
  return unit.isEmpty
      ? '$count · $scope · $horizonLabel'
      : '$count · $scope ($unit) · $horizonLabel';
}

/// `yyyy-MM-dd` → `dd/MM/yyyy` (Arabic) / ISO (English).
String _displayDate(String iso) {
  final parts = iso.split('-');
  if (parts.length == 3) {
    return AppText.t('${parts[2]}/${parts[1]}/${parts[0]}', iso);
  }
  return iso;
}

class _NirItemDetails extends StatefulWidget {
  const _NirItemDetails({required this.stats});

  final NirParameterStats stats;

  @override
  State<_NirItemDetails> createState() => _NirItemDetailsState();
}

class _NirItemDetailsState extends State<_NirItemDetails> {
  late NirAdjustmentMode _mode = widget.stats.adjustmentAdvice.recommended;

  NirParameterStats get _stats => widget.stats;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FitScatterChart(stats: _stats),
        const SizedBox(height: AppSpacing.md),
        _AdjustmentCard(
          stats: _stats,
          mode: _mode,
          onMode: (m) => setState(() => _mode = m),
        ),
        const SizedBox(height: AppSpacing.md),
        _AdviceCard(stats: _stats),
        const SizedBox(height: AppSpacing.md),
        _AllMetricsCard(stats: _stats),
        const SizedBox(height: AppSpacing.md),
        Text(
          AppText.t('جدول النقاط المطابقة', 'Matched-pair table'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppSpacing.xs),
        NirPointsTable(points: _stats.points, unit: _stats.unit),
      ],
    );
  }
}

/// NIR (x) vs lab reference (y) scatter with both adjuster lines drawn over
/// the data range: the full regression `lab = a·nir + b` and the through-
/// origin `lab = a₀·nir` line the slope-only adjustment uses.
class _FitScatterChart extends StatelessWidget {
  const _FitScatterChart({required this.stats});

  final NirParameterStats stats;

  @override
  Widget build(BuildContext context) {
    final pts = stats.points
        .where((p) => p.nirValue.isFinite && p.labValue.isFinite)
        .toList();
    if (pts.isEmpty) {
      return Text(
        AppText.t('لا توجد نقاط قابلة للرسم', 'No plottable points'),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }

    final a = stats.slope;
    final b = stats.intercept;
    final a0 = stats.slopeOnly;

    double minX = pts.map((p) => p.nirValue).reduce(
          (m, x) => x < m ? x : m,
        );
    double maxX = pts.map((p) => p.nirValue).reduce(
          (m, x) => x > m ? x : m,
        );
    // The slope-only line passes through the origin — keep it inside the view.
    minX = minX > 0 ? 0 : minX;
    maxX = maxX < 0 ? 0 : maxX;
    final xPad = (maxX - minX).abs() < 1e-12 ? 1.0 : (maxX - minX) * 0.08;
    minX -= xPad;
    maxX += xPad;

    double yMin = 0;
    double yMax = 0;
    void expandY(double y) {
      if (!y.isFinite) return;
      if (y < yMin) yMin = y;
      if (y > yMax) yMax = y;
    }

    for (final p in pts) {
      expandY(p.labValue);
      expandY(a * p.nirValue + b);
      expandY(a0 * p.nirValue);
    }
    final yPad = (yMax - yMin).abs() < 1e-12
        ? (yMax.abs() < 1e-12 ? 1.0 : yMax.abs() * 0.15)
        : (yMax - yMin) * 0.08;
    yMin -= yPad;
    yMax += yPad;

    final dataSpots = [
      for (final p in pts) FlSpot(p.nirValue, p.labValue),
    ];

    final headerStyle = TextStyle(
      fontSize: 10.spMin,
      color: AppColors.textMuted,
    );

    final dotsPainter = FlDotData(
      show: true,
      getDotPainter: (s, p, bar, i) => FlDotCirclePainter(
        radius: 4,
        color: AppColors.primary,
      ),
    );
    final touchedDotsPainter = FlDotData(
      show: true,
      getDotPainter: (s, p, bar, i) => FlDotCirclePainter(
        radius: 6,
        color: AppColors.primary,
        strokeColor: Colors.white,
        strokeWidth: 2,
      ),
    );

    // The raw pairs bar is the only one that reacts to touch; the two fit
    // lines are static reference lines identified by identity here.
    final dataBar = LineChartBarData(
      spots: dataSpots,
      color: Colors.transparent,
      barWidth: 0,
      dotData: dotsPainter,
    );
    final fullFitBar = LineChartBarData(
      spots: [
        FlSpot(minX, a * minX + b),
        FlSpot(maxX, a * maxX + b),
      ],
      color: AppColors.success,
      barWidth: 2,
      dotData: const FlDotData(show: false),
    );
    final slopeOnlyBar = LineChartBarData(
      spots: [
        FlSpot(minX, a0 * minX),
        FlSpot(maxX, a0 * maxX),
      ],
      color: AppColors.info,
      barWidth: 2,
      dashArray: const [6, 4],
      dotData: const FlDotData(show: false),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: FormFactor.current.isMobile ? 220 : 300,
          width: double.infinity,
          child: LineChart(
            LineChartData(
              minY: yMin,
              maxY: yMax,
              minX: minX,
              maxX: maxX,
              clipData: const FlClipData.all(),
              lineTouchData: LineTouchData(
                // The painter requires exactly one (nullable) indicator entry
                // per touched spot for every bar it visits — bars other than
                // the raw-pairs series get null (no highlight, no crash).
                getTouchedSpotIndicator: (bar, spotIndexes) => [
                  for (final _ in spotIndexes)
                    bar != dataBar || dataSpots.isEmpty
                        ? null
                        : TouchedSpotIndicatorData(
                            FlLine(
                              color: AppColors.primary.withValues(alpha: 0.4),
                              strokeWidth: 1,
                            ),
                            touchedDotsPainter,
                          ),
                ],
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => [
                    for (final s in spots)
                      if (s.barIndex == _dataSeriesIndex)
                        LineTooltipItem(
                          'NIR: ${s.x.toStringAsFixed(3)}'
                          '\n${AppText.t('المعمل', 'Lab')}: ${s.y.toStringAsFixed(3)}',
                          const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else
                        null,
                  ],
                ),
              ),
              lineBarsData: [
                dataBar,
                fullFitBar,
                slopeOnlyBar,
              ],
              titlesData: FlTitlesData(
                topTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                rightTitles: const AxisTitles(
                  sideTitles: SideTitles(showTitles: false),
                ),
                leftTitles: AxisTitles(
                  axisNameWidget: Text(
                    AppText.t('المعمل (ريفرنس)', 'Lab (reference)'),
                    style: headerStyle,
                  ),
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 44,
                    getTitlesWidget: (v, _) => Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        v.toStringAsFixed(1),
                        style: headerStyle,
                      ),
                    ),
                  ),
                ),
                bottomTitles: AxisTitles(
                  axisNameWidget: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('NIR', style: headerStyle),
                  ),
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 26,
                    getTitlesWidget: (v, _) => Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        v.toStringAsFixed(1),
                        style: headerStyle,
                      ),
                    ),
                  ),
                ),
              ),
              gridData: const FlGridData(show: true),
              borderData: FlBorderData(show: true),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _LegendDot(
              color: AppColors.primary,
              label: AppText.t('نقاط NIR × المعمل', 'NIR × lab pairs'),
            ),
            _LegendDot(
              color: AppColors.success,
              label: AppText.t(
                'الميل + القاطع: lab = a·nir + b',
                'Slope + intercept: lab = a·nir + b',
              ),
            ),
            _LegendDot(
              color: AppColors.info,
              dashed: true,
              label: AppText.t(
                'الميل فقط: lab = a₀·nir',
                'Slope only: lab = a₀·nir',
              ),
            ),
          ],
        ),
      ],
    );
  }

  static const int _dataSeriesIndex = 0;
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
    this.dashed = false,
  });

  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dashed
            ? SizedBox(
                width: 14,
                child: CustomPaint(
                  size: const Size(14, 2),
                  painter: _DashPainter(color: color),
                ),
              )
            : Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(fontSize: 11.spMin),
        ),
      ],
    );
  }
}

class _DashPainter extends CustomPainter {
  const _DashPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    const dash = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(x + dash, size.height / 2),
        paint,
      );
      x += dash * 2;
    }
  }

  @override
  bool shouldRepaint(covariant _DashPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Adjuster card: the mode choice (slope only / slope + intercept), the
/// resulting formula and the accuracy of the chosen adjustment.
class _AdjustmentCard extends StatelessWidget {
  const _AdjustmentCard({
    required this.stats,
    required this.mode,
    required this.onMode,
  });

  final NirParameterStats stats;
  final NirAdjustmentMode mode;
  final ValueChanged<NirAdjustmentMode> onMode;

  @override
  Widget build(BuildContext context) {
    final n = stats.count;
    final (formulaAr, formulaEn) = switch (mode) {
      NirAdjustmentMode.slopeOnly => (
          'المصحح = a₀ × NIR (a₀ = ${stats.slopeOnly.toStringAsFixed(4)})',
          'Adjusted = a₀ × NIR (a₀ = ${stats.slopeOnly.toStringAsFixed(4)})',
        ),
      NirAdjustmentMode.slopeAndIntercept => (
          'المصحح = a × NIR + b (a = ${stats.slope.toStringAsFixed(4)}, b = ${stats.intercept.toStringAsFixed(4)})',
          'Adjusted = a × NIR + b (a = ${stats.slope.toStringAsFixed(4)}, b = ${stats.intercept.toStringAsFixed(4)})',
        ),
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t(
              'اختر طريقة تصحيح قراءة الجهاز',
              'Choose how the raw device reading is adjusted',
            ),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              ChoiceChip(
                label: Text(
                  AppText.t('الميل فقط', 'Slope only'),
                ),
                selected: mode == NirAdjustmentMode.slopeOnly,
                onSelected: (_) => onMode(NirAdjustmentMode.slopeOnly),
              ),
              ChoiceChip(
                label: Text(
                  AppText.t('الميل + القاطع', 'Slope + intercept'),
                ),
                selected: mode == NirAdjustmentMode.slopeAndIntercept,
                onSelected: (_) => onMode(NirAdjustmentMode.slopeAndIntercept),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            AppText.t(formulaAr, formulaEn),
            style: Theme.of(context).textTheme.bodyMedium!.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: 4,
            children: [
              _DetailChip(
                label: AppText.t('الانحراف بعد التصحيح', 'Bias after'),
                value: n == 0
                    ? '-'
                    : stats.biasOf(mode).toStringAsFixed(3),
                color: stats.biasOf(mode) > 0
                    ? AppColors.danger
                    : AppColors.success,
              ),
              _DetailChip(
                label: 'RMSE',
                value: n < 2 ? '-' : stats.rmseOf(mode).toStringAsFixed(3),
              ),
              _DetailChip(
                label: 'R²',
                value: n < 2 ? '-' : stats.r2Of(mode).toStringAsFixed(3),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The auto-recommendation card ("deep thinking"): the suggested mode with
/// every reason behind it — slope distance from 1, intercept significance
/// (t-test) and the RMSE gain the intercept buys.
class _AdviceCard extends StatelessWidget {
  const _AdviceCard({required this.stats});

  final NirParameterStats stats;

  @override
  Widget build(BuildContext context) {
    final advice = stats.adjustmentAdvice;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.psychology_outlined,
                size: 20.r,
                color: AppColors.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AppText.t('القرار المقترح', 'Suggested decision'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              _DetailChip(
                label: '',
                value: advice.recommended == NirAdjustmentMode.slopeOnly
                    ? AppText.t('الميل فقط', 'Slope only')
                    : AppText.t('الميل + القاطع', 'Slope + intercept'),
                color: AppColors.success,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final r in advice.reasons) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Text('•'),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      AppText.t(r.ar, r.en),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Every metric of the item in one glance: raw fit, slope-only fit, the
/// recommendation signal (intercept |t|) and the horizon data.
class _AllMetricsCard extends StatelessWidget {
  const _AllMetricsCard({required this.stats});

  final NirParameterStats stats;

  @override
  Widget build(BuildContext context) {
    final n = stats.count;
    final horizon = stats.horizonStart.trim();
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppText.t('كل التفاصيل', 'All details'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: 4,
            children: [
              _DetailChip(label: 'N', value: '$n'),
              _DetailChip(
                label: AppText.t('الانحراف (خام)', 'Bias (raw)'),
                value: n == 0 ? '-' : stats.bias.toStringAsFixed(3),
                color:
                    stats.bias > 0 ? AppColors.danger : AppColors.success,
              ),
              _DetailChip(
                label: AppText.t('الميل a', 'Slope a'),
                value: n < 2 ? '-' : stats.slope.toStringAsFixed(4),
              ),
              _DetailChip(
                label: AppText.t('القاطع b', 'Intercept b'),
                value: n < 2 ? '-' : stats.intercept.toStringAsFixed(4),
              ),
              _DetailChip(
                label: AppText.t('الميل فقط a₀', 'Slope only a₀'),
                value: n < 1 ? '-' : stats.slopeOnly.toStringAsFixed(4),
              ),
              _DetailChip(
                label: 'R²',
                value: n < 2 ? '-' : stats.r2.toStringAsFixed(3),
              ),
              _DetailChip(
                label: 'RMSE',
                value: n < 2 ? '-' : stats.rmse.toStringAsFixed(3),
              ),
              _DetailChip(
                label: 'RMSE ${AppText.t('ميل فقط', 'slope-only')}',
                value: n < 2 ? '-' : stats.rmseOf(NirAdjustmentMode.slopeOnly).toStringAsFixed(3),
              ),
              _DetailChip(
                label: 'R² ${AppText.t('ميل فقط', 'slope-only')}',
                value: n < 2 ? '-' : stats.r2Of(NirAdjustmentMode.slopeOnly).toStringAsFixed(3),
              ),
              _DetailChip(
                label: AppText.t('أكبر انحراف', 'Max deviation'),
                value: n == 0 ? '-' : stats.maxDeviation.toStringAsFixed(3),
              ),
              _DetailChip(
                label: '|t| ${AppText.t('القاطع', 'intercept')}',
                value: stats.adjustmentAdvice.interceptT.toStringAsFixed(2),
                color: stats.adjustmentAdvice.interceptT >= 2
                    ? AppColors.warning
                    : AppColors.textMuted,
              ),
              if (unit.isNotEmpty)
                _DetailChip(
                  label: AppText.t('الوحدة', 'Unit'),
                  value: unit,
                ),
              _DetailChip(
                label: NirValidationState.scopeLabel(stats.scope),
                value: stats.entityName,
                color: AppColors.info,
              ),
              if (horizon.isNotEmpty)
                _DetailChip(
                  label: AppText.t(
                    stats.scopedHorizon ? 'تصفير الخاص' : 'تصفير عام من',
                    stats.scopedHorizon ? 'Item reset' : 'Global reset from',
                  ),
                  value: _displayDate(horizon),
                  color: AppColors.primary,
                ),
            ],
          ),
        ],
      ),
    );
  }

  String get unit => stats.unit.trim();
}

class _DetailChip extends StatelessWidget {
  const _DetailChip({
    required this.label,
    required this.value,
    this.color,
  });

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final resolved = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: resolved.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            if (label.isNotEmpty) ...[
              TextSpan(
                text: '$label: ',
                style: TextStyle(
                  fontSize: 12.spMin,
                  fontWeight: FontWeight.w600,
                  color: resolved,
                ),
              ),
            ],
            TextSpan(
              text: value,
              style: TextStyle(
                fontSize: 12.spMin,
                fontWeight: FontWeight.w700,
                color: resolved,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The matched-pair table (NIR vs lab reference) — shared by the details
/// window and the tab expansion.
class NirPointsTable extends StatelessWidget {
  const NirPointsTable({super.key, required this.points, required this.unit});

  final List<NirValidationPoint> points;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final u = unit.trim().isEmpty ? '' : ' $unit';
    final headerStyle = TextStyle(
      fontWeight: FontWeight.w700,
      fontSize: 12.spMin,
      color: AppColors.textMuted,
    );
    final cellStyle = TextStyle(fontSize: 12.spMin);
    // Five columns in ~330dp of dialog-width track: on the phone each
    // matched pair becomes a two-line item instead (identity on top, the
    // three readings side by side); desktop keeps the aligned grid.
    if (FormFactor.current.isMobile) {
      return Column(
        children: [
          for (final p in points) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${p.inspectionDate} · ${p.entryCode}',
                    style: cellStyle.copyWith(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    p.sampleName,
                    style: cellStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Wrap(
                    spacing: 12,
                    runSpacing: 2,
                    children: [
                      Text(
                        'NIR: ${p.nirValue.toStringAsFixed(3)}$u',
                        style: cellStyle,
                      ),
                      Text(
                        '${AppText.t('المعمل', 'Lab')}: ${p.labValue.toStringAsFixed(3)}$u',
                        style: cellStyle,
                      ),
                      Text(
                        '${AppText.t('انحراف', 'Dev.')}: ${p.deviation.toStringAsFixed(3)}',
                        style: cellStyle.copyWith(
                          color: p.deviation > 0
                              ? AppColors.danger
                              : p.deviation < 0
                              ? AppColors.success
                              : AppColors.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 6),
          ],
        ],
      );
    }
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                AppText.t('التاريخ / المحضر', 'Date / محضر'),
                style: headerStyle,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(AppText.t('العينة', 'Sample'), style: headerStyle),
            ),
            Expanded(
              flex: 2,
              child: Text('NIR', style: headerStyle),
            ),
            Expanded(
              flex: 2,
              child: Text(
                AppText.t('المعمل (ريفرنس)', 'Lab (reference)'),
                style: headerStyle,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                AppText.t('الانحراف', 'Dev.'),
                style: headerStyle,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
        const Divider(height: 8),
        for (final p in points) ...[
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  '${p.inspectionDate} · ${p.entryCode}',
                  style: cellStyle,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(p.sampleName, style: cellStyle),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '${p.nirValue.toStringAsFixed(3)}$u',
                  style: cellStyle,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  '${p.labValue.toStringAsFixed(3)}$u',
                  style: cellStyle,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  p.deviation.toStringAsFixed(3),
                  textAlign: TextAlign.center,
                  style: cellStyle.copyWith(
                    color: p.deviation > 0
                        ? AppColors.danger
                        : p.deviation < 0
                        ? AppColors.success
                        : AppColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 6),
        ],
      ],
    );
  }
}
