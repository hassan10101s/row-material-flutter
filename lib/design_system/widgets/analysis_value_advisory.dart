import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';
import '../../core/utils/analysis_value_warning.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// An advisory only: never sets a form error, alters input, or gates saving.
class AnalysisValueAdvisory extends StatelessWidget {
  const AnalysisValueAdvisory({
    super.key,
    required this.controller,
    required this.parameter,
    required this.reference,
    required this.child,
  });
  final TextEditingController controller;
  final String parameter;
  final Object? reference;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      child,
      ListenableBuilder(
        listenable: controller,
        builder: (_, _) => AnalysisValueWarningText(
          value: controller.text,
          parameter: parameter,
          reference: reference,
        ),
      ),
    ],
  );
}

class AnalysisValueWarningText extends StatelessWidget {
  const AnalysisValueWarningText({
    super.key,
    required this.value,
    required this.parameter,
    required this.reference,
  });
  final Object? value;
  final String parameter;
  final Object? reference;
  @override
  Widget build(BuildContext context) {
    if (!exceedsDoubleAnalysisMaximum(value, reference)) {
      return const SizedBox.shrink();
    }
    final text = AppText.t(
      'هل أنت متأكد من قيمة $parameter: ${'$value'.trim()}؟',
      'Are you sure about $parameter: ${'$value'.trim()}?',
    );
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: AppColors.warning,
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.textStrong),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
