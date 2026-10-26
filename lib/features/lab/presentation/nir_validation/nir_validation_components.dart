import 'package:flutter/material.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../domain/nir_validation_repository.dart';

String nirReliabilityLabel(NirReliability reliability) => switch (reliability) {
  NirReliability.trusted => AppText.t('موثوق', 'Trusted'),
  NirReliability.needsReview => AppText.t('يحتاج مراجعة', 'Needs review'),
  NirReliability.insufficientData => AppText.t(
    'بيانات غير كافية',
    'More data needed',
  ),
};
Color nirReliabilityColor(NirReliability reliability) => switch (reliability) {
  NirReliability.trusted => AppColors.success,
  NirReliability.needsReview => AppColors.warning,
  NirReliability.insufficientData => AppColors.textMuted,
};

String nirFixed(double value, [int digits = 3]) {
  final text = value.toStringAsFixed(digits);
  return double.tryParse(text) == 0 ? 0.0.toStringAsFixed(digits) : text;
}

class NirReliabilityBadge extends StatelessWidget {
  const NirReliabilityBadge({super.key, required this.reliability});
  final NirReliability reliability;
  @override
  Widget build(BuildContext context) {
    final color = nirReliabilityColor(reliability);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(AppRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            switch (reliability) {
              NirReliability.trusted => Icons.verified_outlined,
              NirReliability.needsReview => Icons.fact_check_outlined,
              NirReliability.insufficientData => Icons.hourglass_empty_rounded,
            },
            size: 16,
            color: color,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              nirReliabilityLabel(reliability),
              style: Theme.of(
                context,
              ).textTheme.labelMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class NirMetricTile extends StatelessWidget {
  const NirMetricTile({
    super.key,
    required this.label,
    required this.value,
    this.hint,
    this.tooltip,
  });
  final String label;
  final String value;
  final String? hint;
  final String? tooltip;
  @override
  Widget build(BuildContext context) {
    final child = Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceSoft,
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            textDirection: TextDirection.ltr,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}

class NirSectionTitle extends StatelessWidget {
  const NirSectionTitle({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
  });
  final String title;
  final IconData icon;
  final String? subtitle;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, color: AppColors.primary, size: 20),
      const SizedBox(width: AppSpacing.sm),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
            ],
          ],
        ),
      ),
    ],
  );
}

class NirMetricGrid extends StatelessWidget {
  const NirMetricGrid({super.key, required this.children, this.columns = 3});
  final List<Widget> children;
  final int columns;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaled = MediaQuery.textScalerOf(context).scale(14) / 14;
      final count = (constraints.maxWidth / (145 * scaled)).floor().clamp(
        1,
        columns,
      );
      final width =
          (constraints.maxWidth - AppSpacing.sm * (count - 1)) / count;
      return Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (var i = 0; i < children.length; i++)
            SizedBox(
              width: i == children.length - 1 && children.length % count == 1
                  ? constraints.maxWidth
                  : width,
              child: children[i],
            ),
        ],
      );
    },
  );
}
