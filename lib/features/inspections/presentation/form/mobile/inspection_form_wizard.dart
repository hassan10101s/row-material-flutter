import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_wizard.dart';
import '../../cubit/inspection_form_cubit.dart';
import '../../cubit/inspection_form_state.dart';
import '../widgets/inspection_form_sections.dart';

/// Mobile inspection form: the same four sections as desktop, one per
/// step, with a segmented step bar and a 52h bottom action bar.
///
/// Pure view over [InspectionFormSections] (same controllers, same cubit,
/// same save path as desktop) — only the chrome steps through. Opened by
/// the mobile list variant; desktop keeps the full stacked form.
class InspectionFormWizard extends StatefulWidget {
  final InspectionFormSections sections;
  final VoidCallback onSave;
  final String title;

  const InspectionFormWizard({
    super.key,
    required this.sections,
    required this.onSave,
    required this.title,
  });

  @override
  State<InspectionFormWizard> createState() => _InspectionFormWizardState();
}

class _InspectionFormWizardState extends State<InspectionFormWizard> {
  int _step = 0;

  @override
  Widget build(BuildContext context) {
    final formState = context.watch<InspectionFormCubit>().state;
    final sections = widget.sections;

    final steps = <({String title, Widget body})>[
      (
        title: AppText.t('البيانات', 'Basics'),
        body: sections.basicCard(context),
      ),
      if (sections.physical.isNotEmpty)
        (
          title: AppText.t('الفيزيائي', 'Physical'),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              sections.physicalCard(context),
              const SizedBox(height: AppSpacing.md),
              sections.addSampleButton(context),
            ],
          ),
        ),
      if (sections.chemical.isNotEmpty)
        (
          title: AppText.t('الكيميائي', 'Chemical'),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              sections.chemicalCard(context),
              if (sections.physical.isEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                sections.addSampleButton(context),
              ],
            ],
          ),
        ),
      (
        title: AppText.t('القرار', 'Decision'),
        body: sections.decisionCard(context),
      ),
    ];
    final step = _step.clamp(0, steps.length - 1);
    final last = step == steps.length - 1;

    void go(int i) => setState(() => _step = i.clamp(0, steps.length - 1));

    void next() {
      // No silent skips: the material/product gates everything downstream
      // (entry code, reference grids), so the wizard holds here.
      if (step == 0 && formState.materialId == null) {
        AppFeedback.error(
          context,
          sections.isProduct
              ? AppText.t('يجب اختيار المنتج', 'Product selection is required.')
              : AppText.t('يجب اختيار المادة', 'Material selection is required.'),
        );
        return;
      }
      go(step + 1);
    }

    return AppErrorFeedback<InspectionFormCubit, InspectionFormState>(
      selector: (s) => s.error,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppTopAppBar(title: widget.title),
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pageMobile,
                  AppSpacing.md,
                  AppSpacing.pageMobile,
                  AppSpacing.sm,
                ),
                child: AppWizardBar(
                  steps: [for (final s in steps) s.title],
                  current: step,
                  onStep: go,
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageMobile,
                    0,
                    AppSpacing.pageMobile,
                    AppSpacing.pageMobile,
                  ),
                  child: steps[step].body,
                ),
              ),
              AppWizardBottomBar(
                onBack: step > 0 ? () => go(step - 1) : null,
                onNext: last ? widget.onSave : next,
                backLabel: AppText.t('رجوع', 'Back'),
                nextLabel: last
                    ? AppText.t('حفظ الفحص', 'Save inspection')
                    : AppText.t('التالي', 'Next'),
                nextLoading: last && formState.saving,
                nextEnabled: !formState.saving,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
