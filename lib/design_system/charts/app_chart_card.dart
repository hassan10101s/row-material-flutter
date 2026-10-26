import 'package:flutter/material.dart';

import '../animations/app_animations.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// One legend chip: color swatch + label (+ dashed hairline for line-style
/// series such as moving averages).
class AppChartLegendEntry {
  const AppChartLegendEntry({
    required this.color,
    required this.label,
    this.dashed = false,
  });

  final Color color;
  final String label;
  final bool dashed;
}

/// Legend row shared by every chart card so charts read identically.
class AppChartLegend extends StatelessWidget {
  const AppChartLegend({
    super.key,
    required this.entries,
    this.spacing = 14,
    this.runSpacing = 6,
  });

  final List<AppChartLegendEntry> entries;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      children: [
        for (final e in entries)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _swatch(e),
              const SizedBox(width: 6),
              Text(
                e.label,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _swatch(AppChartLegendEntry e) => Container(
    width: 22,
    height: 4,
    decoration: BoxDecoration(
      color: e.dashed ? Colors.transparent : e.color,
      borderRadius: BorderRadius.circular(2),
      border: e.dashed
          ? Border(top: BorderSide(color: e.color, width: 2))
          : null,
    ),
    child: e.dashed
        ? Row(
            children: [
              for (var i = 0; i < 4; i++)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    height: 3,
                    color: e.color,
                  ),
                ),
            ],
          )
        : null,
  );
}

/// Canonical chart surface: a card shell with an optional title row, the
/// chart body and an optional legend row, wrapped in a RepaintBoundary with
/// the shared entrance animation.
class AppChartCard extends StatelessWidget {
  const AppChartCard({
    super.key,
    this.title,
    this.trailing,
    this.legend,
    required this.child,
    this.padding = 16,
    this.legendTopSpacing = 10,
    this.animate = true,
  });

  final String? title;
  final Widget? trailing;
  final List<AppChartLegendEntry>? legend;
  final Widget child;
  final double padding;
  final double legendTopSpacing;

  /// Set false when the parent already staggers the card.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null || trailing != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  title ?? '',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ?trailing,
            ],
          ),
        child,
        if (legend != null && legend!.isNotEmpty) ...[
          SizedBox(height: legendTopSpacing),
          AppChartLegend(entries: legend!),
        ],
      ],
    );
    return AppEntrance(
      child: RepaintBoundary(
        child: Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.lg),
          ),
          child: Padding(padding: EdgeInsets.all(padding), child: body),
        ),
      ),
    );
  }
}
