import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/widgets/app_adaptive.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../domain/nir_validation_repository.dart';
import '../cubit/nir_validation_state.dart';
import 'nir_validation_components.dart';

/// Opens the full details window of one (خامة/منتج × تحليل) item: the
/// NIR-vs-lab scatter with both fitted lines, every accuracy metric, the
/// adjustment-mode choice (الميل فقط / الميل + القاطع) with its auto
/// reasoning, and the matched-pair table.
Future<void> showNirItemDetails(
  BuildContext context,
  NirParameterStats stats, {
  Future<void> Function()? onReset,
}) async {
  final reset = await showAppDialog<bool>(
    context,
    builder: (overlay) => AppDialog(
      title: '${stats.entityName} · ${stats.parameter}',
      subtitle: _detailsSubtitle(stats),
      icon: Icons.insights_outlined,
      size: AppWindowSize.lg,
      actions: [
        if (onReset != null)
          AppButton(
            label: AppText.t(
              'بدء فترة جديدة لهذا التحليل',
              'New period for this analysis',
            ),
            icon: const Icon(Icons.restart_alt_outlined, size: 18),
            style: AppButtonStyle.ghost,
            onPressed: () => Navigator.pop(overlay, true),
          ),
        AppButton(
          label: AppText.t('إغلاق', 'Close'),
          style: AppButtonStyle.secondary,
          onPressed: () => Navigator.pop(overlay, false),
        ),
      ],
      child: _NirItemDetails(stats: stats),
    ),
  );
  if (reset == true && context.mounted) await onReset?.call();
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
    final chart = AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NirSectionTitle(
            title: AppText.t('NIR مقابل المعمل', 'NIR versus laboratory'),
            icon: Icons.scatter_plot_outlined,
            subtitle: AppText.t(
              'كل نقطة تمثل قراءتين لنفس الفحص.',
              'Each point is a paired reading from the same inspection.',
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _FitScatterChart(stats: _stats),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: AppSpacing.md,
                runSpacing: AppSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  NirReliabilityBadge(reliability: _stats.reliability),
                  Text(
                    '${_stats.count} ${AppText.t('نقطة مطابقة', 'matched pairs')}',
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                _stats.reliability == NirReliability.insufficientData
                    ? AppText.t(
                        'اجمع 5 نقاط على الأقل لتقييم موثوقية هذا التحليل. التوصية الحالية مبنية على البيانات المتاحة.',
                        'Collect at least 5 pairs to assess reliability. The current recommendation uses the available data.',
                      )
                    : _stats.reliability == NirReliability.needsReview
                    ? AppText.t(
                        'راجع النقاط المرجعية وتشتت القراءات قبل الاعتماد على التصحيح المقترح.',
                        'Review the reference pairs and reading scatter before relying on the proposed correction.',
                      )
                    : AppText.t(
                        'يحقق هذا التحليل شروط الموثوقية الحالية: 5 نقاط على الأقل ومعامل تحديد لا يقل عن 0.90.',
                        'This analysis meets the current reliability criteria: at least 5 pairs and R² ≥ 0.90.',
                      ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _AdjustmentCard(
          stats: _stats,
          mode: _mode,
          onMode: (m) => setState(() => _mode = m),
        ),
        const SizedBox(height: AppSpacing.md),
        appAdaptiveVariant(
          context,
          desktop: (_) => LayoutBuilder(
            builder: (_, constraints) => constraints.maxWidth < 700
                ? Column(
                    children: [
                      chart,
                      const SizedBox(height: AppSpacing.md),
                      _AdviceCard(stats: _stats),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 3, child: chart),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(flex: 2, child: _AdviceCard(stats: _stats)),
                    ],
                  ),
          ),
          mobile: (_) => Column(
            children: [
              chart,
              const SizedBox(height: AppSpacing.md),
              _AdviceCard(stats: _stats),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _AllMetricsCard(stats: _stats),
        const SizedBox(height: AppSpacing.md),
        NirSectionTitle(
          title: AppText.t('القراءات المطابقة', 'Matched readings'),
          icon: Icons.table_rows_outlined,
          subtitle: AppText.t(
            'الانحراف = NIR − المعمل. الإشارة تحدد اتجاه الفرق فقط.',
            'Deviation = NIR − lab. The sign indicates direction only.',
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
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

    double minX = pts.map((p) => p.nirValue).reduce((m, x) => x < m ? x : m);
    double maxX = pts.map((p) => p.nirValue).reduce((m, x) => x > m ? x : m);
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

    final dataSpots = [for (final p in pts) FlSpot(p.nirValue, p.labValue)];

    final headerStyle = TextStyle(
      fontSize: 10.spMin,
      color: AppColors.textMuted,
    );

    final dotsPainter = FlDotData(
      show: true,
      getDotPainter: (s, p, bar, i) =>
          FlDotCirclePainter(radius: 4, color: AppColors.primary),
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
      spots: [FlSpot(minX, a * minX + b), FlSpot(maxX, a * maxX + b)],
      color: AppColors.success,
      barWidth: 2,
      dotData: const FlDotData(show: false),
    );
    final slopeOnlyBar = LineChartBarData(
      spots: [FlSpot(minX, a0 * minX), FlSpot(maxX, a0 * maxX)],
      color: AppColors.info,
      barWidth: 2,
      dashArray: const [6, 4],
      dotData: const FlDotData(show: false),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: appUsesDesktopChrome(context) ? 300 : 220,
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
              lineBarsData: [dataBar, fullFitBar, slopeOnlyBar],
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
                      child: Text(v.toStringAsFixed(1), style: headerStyle),
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
                      child: Text(v.toStringAsFixed(1), style: headerStyle),
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
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(label, style: TextStyle(fontSize: 11.spMin)),
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
    final recommended = stats.adjustmentAdvice.recommended;
    final formula = mode == NirAdjustmentMode.slopeOnly
        ? 'Lab = ${stats.slopeOnly.toStringAsFixed(4)} × NIR'
        : 'Lab = ${stats.slope.toStringAsFixed(4)} × NIR ${stats.intercept < 0 ? '−' : '+'} ${stats.intercept.abs().toStringAsFixed(4)}';
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NirSectionTitle(
            title: AppText.t(
              'معاينة التصحيح المقترح',
              'Preview the proposed correction',
            ),
            icon: Icons.tune_rounded,
            subtitle: AppText.t(
              'اختيار الطريقة يغيّر المعاينة فقط؛ لا يغيّر معايرة الجهاز أو النتائج المحفوظة.',
              'Changing the method updates this preview only. It does not change device calibration or saved results.',
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final candidate in NirAdjustmentMode.values)
                ChoiceChip(
                  selected: mode == candidate,
                  onSelected: (_) => onMode(candidate),
                  label: Text(
                    '${candidate == NirAdjustmentMode.slopeOnly ? AppText.t('الميل فقط', 'Slope only') : AppText.t('الميل + القاطع', 'Slope + intercept')}${candidate == recommended ? AppText.t(' · المقترح', ' · Suggested') : ''}',
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: .06),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(
                color: AppColors.primary.withValues(alpha: .15),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppText.t(
                    'المعادلة: القيمة المعملية المتوقعة',
                    'Formula: predicted laboratory value',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: AppSpacing.sm),
                SelectableText(
                  stats.count == 0 ? '—' : formula,
                  textDirection: TextDirection.ltr,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton(
                  label: AppText.t('نسخ المعادلة', 'Copy formula'),
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  style: AppButtonStyle.ghost,
                  small: true,
                  onPressed: stats.count == 0
                      ? null
                      : () async {
                          try {
                            await Clipboard.setData(
                              ClipboardData(text: formula),
                            );
                            if (context.mounted) {
                              AppFeedback.show(
                                context,
                                AppText.t('تم نسخ المعادلة', 'Formula copied'),
                                type: AppFeedbackType.success,
                              );
                            }
                          } on Object catch (error) {
                            if (context.mounted) {
                              AppFeedback.errorFrom(context, error);
                            }
                          }
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Semantics(
            liveRegion: true,
            child: NirMetricGrid(
              children: [
                NirMetricTile(
                  label: AppText.t(
                    'متوسط الباقي بعد التصحيح',
                    'Mean residual after correction',
                  ),
                  value: stats.count == 0 ? '—' : nirFixed(stats.biasOf(mode)),
                  hint: AppText.t(
                    'المعمل − القيمة المصححة',
                    'Lab − corrected reading',
                  ),
                ),
                NirMetricTile(
                  label: 'RMSE',
                  value: stats.count < 2
                      ? '—'
                      : stats.rmseOf(mode).toStringAsFixed(3),
                  hint: AppText.t(
                    'خطأ التصحيح على هذه النقاط',
                    'Correction error on these pairs',
                  ),
                ),
                NirMetricTile(
                  label: 'R²',
                  value: stats.count < 2
                      ? '—'
                      : stats.r2Of(mode).toStringAsFixed(3),
                  hint: AppText.t(
                    'معامل التحديد بعد التصحيح',
                    'Determination after correction',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
          NirSectionTitle(
            title: AppText.t('لماذا هذه التوصية؟', 'Why this recommendation?'),
            icon: Icons.lightbulb_outline_rounded,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            advice.recommended == NirAdjustmentMode.slopeOnly
                ? AppText.t('الميل فقط', 'Slope only')
                : AppText.t('الميل + القاطع', 'Slope + intercept'),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(color: AppColors.primary),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < advice.reasons.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${i + 1}.',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      AppText.t(advice.reasons[i].ar, advice.reasons[i].en),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _AllMetricsCard extends StatelessWidget {
  const _AllMetricsCard({required this.stats});
  final NirParameterStats stats;
  @override
  Widget build(BuildContext context) => AppCard(
    padding: EdgeInsets.zero,
    child: ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      childrenPadding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        0,
        AppSpacing.md,
        AppSpacing.md,
      ),
      title: Text(
        AppText.t(
          'المؤشرات التفصيلية وفترة المقارنة',
          'Detailed metrics & comparison period',
        ),
        style: Theme.of(context).textTheme.titleSmall,
      ),
      children: [
        NirMetricGrid(
          children: [
            NirMetricTile(
              label: AppText.t('متوسط NIR', 'Mean NIR'),
              value: stats.count == 0 ? '—' : stats.meanNir.toStringAsFixed(3),
            ),
            NirMetricTile(
              label: AppText.t('متوسط المعمل', 'Mean laboratory'),
              value: stats.count == 0 ? '—' : stats.meanLab.toStringAsFixed(3),
            ),
            NirMetricTile(
              label: AppText.t(
                'الانحراف قبل التصحيح',
                'Bias before correction',
              ),
              value: stats.count == 0 ? '—' : stats.bias.toStringAsFixed(3),
              hint: 'NIR − Lab',
            ),
            NirMetricTile(
              label: AppText.t('الميل a', 'Slope a'),
              value: stats.count < 2 ? '—' : stats.slope.toStringAsFixed(4),
            ),
            NirMetricTile(
              label: AppText.t('القاطع b', 'Intercept b'),
              value: stats.count < 2 ? '—' : stats.intercept.toStringAsFixed(4),
            ),
            NirMetricTile(
              label: AppText.t('الميل فقط a₀', 'Slope only a₀'),
              value: stats.count == 0
                  ? '—'
                  : stats.slopeOnly.toStringAsFixed(4),
            ),
            NirMetricTile(
              label: AppText.t(
                'أكبر انحراف مطلق',
                'Largest absolute deviation',
              ),
              value: stats.count == 0
                  ? '—'
                  : stats.maxDeviation.toStringAsFixed(3),
            ),
            NirMetricTile(
              label: AppText.t(
                'معنوية القاطع |t|',
                'Intercept significance |t|',
              ),
              value: stats.adjustmentAdvice.interceptT.toStringAsFixed(2),
            ),
            NirMetricTile(
              label: AppText.t(
                'بداية فترة المقارنة',
                'Comparison period starts',
              ),
              value: stats.horizonStart.trim().isEmpty
                  ? '—'
                  : _displayDate(stats.horizonStart),
              hint: stats.horizonStart.trim().isEmpty
                  ? AppText.t('كل القراءات المسجلة', 'All recorded readings')
                  : stats.scopedHorizon
                  ? AppText.t(
                      'فترة خاصة بهذا التحليل',
                      'Period for this analysis only',
                    )
                  : AppText.t('فترة عامة', 'Global period'),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Desktop pagination and mobile cards keep large reference sets manageable.
class NirPointsTable extends StatefulWidget {
  const NirPointsTable({super.key, required this.points, required this.unit});
  final List<NirValidationPoint> points;
  final String unit;
  @override
  State<NirPointsTable> createState() => _NirPointsTableState();
}

class _NirPointsTableState extends State<NirPointsTable> {
  int _visible = 20;
  @override
  void didUpdateWidget(covariant NirPointsTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.points, widget.points)) _visible = 20;
  }

  @override
  Widget build(BuildContext context) {
    final suffix = widget.unit.trim().isEmpty ? '' : ' (${widget.unit.trim()})';
    if (widget.points.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Text(
          AppText.t(
            'لا توجد قراءات مطابقة في هذه الفترة.',
            'No paired readings in this period.',
          ),
        ),
      );
    }
    return appAdaptiveVariant(
      context,
      desktop: (_) => AppPaginatedTable(
        height: 320,
        rowsPerPage: 10,
        rowHeight: 60,
        minTableWidth: 640,
        columnFlex: const [2.5, 2.5, 1.5, 1.5, 1.5],
        headers: [
          AppText.t('التاريخ / المحضر', 'Date / inspection'),
          AppText.t('العينة', 'Sample'),
          'NIR$suffix',
          '${AppText.t('المعمل', 'Lab')}$suffix',
          AppText.t('الانحراف', 'Deviation'),
        ],
        rows: [
          for (final point in widget.points)
            [
              Tooltip(
                message: '${point.inspectionDate} · ${point.entryCode}',
                child: Text(
                  '${point.inspectionDate}\n${point.entryCode}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Tooltip(
                message: point.sampleName,
                child: Text(
                  point.sampleName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                point.nirValue.toStringAsFixed(3),
                textDirection: TextDirection.ltr,
              ),
              Text(
                point.labValue.toStringAsFixed(3),
                textDirection: TextDirection.ltr,
              ),
              Text(
                point.deviation.toStringAsFixed(3),
                textDirection: TextDirection.ltr,
              ),
            ],
        ],
      ),
      mobile: (_) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final point in widget.points.take(_visible)) ...[
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    point.entryCode,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${point.inspectionDate} · ${point.sampleName}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.sm,
                    children: [
                      _PointValue(label: 'NIR$suffix', value: point.nirValue),
                      _PointValue(
                        label: '${AppText.t('المعمل', 'Lab')}$suffix',
                        value: point.labValue,
                      ),
                      _PointValue(
                        label: AppText.t('الانحراف', 'Deviation'),
                        value: point.deviation,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (_visible < widget.points.length)
            AppButton(
              label: AppText.t(
                'عرض قراءات أكثر (${widget.points.length - _visible} متبقية)',
                'Show more readings (${widget.points.length - _visible} remaining)',
              ),
              style: AppButtonStyle.secondary,
              onPressed: () => setState(() => _visible += 20),
            ),
        ],
      ),
    );
  }
}

class _PointValue extends StatelessWidget {
  const _PointValue({required this.label, required this.value});
  final String label;
  final double value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
      ),
      Text(
        value.toStringAsFixed(3),
        textDirection: TextDirection.ltr,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    ],
  );
}
