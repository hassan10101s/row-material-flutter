import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Mobile step-by-step wizard shell (pernit behaviour, material_lab identity).
///
/// Used by long mobile forms (inspection form, run-test, large editors):
/// a segmented step header + content + bottom action bar with
/// Back/Next + 52h full-width primary CTA. Desktop keeps its multi-column
/// form untouched; only the mobile variant builds this.
class AppWizardBar extends StatelessWidget {
  const AppWizardBar({
    super.key,
    required this.steps,
    required this.current,
    required this.onStep,
  });

  final List<String> steps;
  final int current;
  final ValueChanged<int> onStep;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsetsDirectional.only(
                end: i == steps.length - 1 ? 0 : AppSpacing.sm,
              ),
              child: ChoiceChip(
                selected: i == current,
                label: Text(steps[i]),
                avatar: i < current
                    ? const Icon(Icons.check, size: 16)
                    : null,
                onSelected: (_) => onStep(i),
                selectedColor: AppColors.primary,
                checkmarkColor: Colors.white,
                showCheckmark: false,
                visualDensity: VisualDensity.comfortable,
                materialTapTargetSize: MaterialTapTargetSize.padded,
                labelStyle: TextStyle(
                  color: i == current ? Colors.white : AppColors.textStrong,
                  fontSize: 12.5.spMax,
                  fontWeight: FontWeight.w700,
                ),
                side: BorderSide(
                  color: i == current
                      ? AppColors.primary
                      : AppColors.border,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Linear progress stepper (mirrors pernit `_ProgressStepper`).
class AppProgressStepper extends StatelessWidget {
  const AppProgressStepper({
    super.key,
    required this.steps,
    required this.current,
  });

  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < steps.length; i++)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i <= current
                            ? AppColors.success
                            : AppColors.borderMuted,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      steps[i],
                      style: TextStyle(
                        fontSize: 11.spMax,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
                if (i != steps.length - 1)
                  Container(
                    width: 32,
                    height: 2,
                    margin: const EdgeInsets.only(bottom: 20, left: 4, right: 4),
                    color: i < current
                        ? AppColors.success
                        : AppColors.borderMuted,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Bottom action bar: Back + Next/Save, 52h primary CTA (pernit sizing).
class AppWizardBottomBar extends StatelessWidget {
  const AppWizardBottomBar({
    super.key,
    required this.onBack,
    required this.onNext,
    this.backLabel,
    required this.nextLabel,
    this.nextEnabled = true,
    this.nextLoading = false,
  });

  final VoidCallback? onBack;
  final VoidCallback? onNext;
  final String? backLabel;
  final String nextLabel;
  final bool nextEnabled;
  final bool nextLoading;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.pageMobile),
        child: Row(
          children: [
            if (onBack != null) ...[
              Expanded(
                child: SizedBox(
                  height: AppSpacing.mobileCtaHeight.h,
                  child: OutlinedButton(
                    onPressed: onBack,
                    child: Text(backLabel ?? 'رجوع'),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
            ],
            Expanded(
              flex: 2,
              child: SizedBox(
                height: AppSpacing.mobileCtaHeight.h,
                child: FilledButton(
                  onPressed: (nextEnabled && !nextLoading) ? onNext : null,
                  child: nextLoading
                      ? SizedBox(
                          width: 18.r,
                          height: 18.r,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(nextLabel),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
