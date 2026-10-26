import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/report_form_keys.dart';
import '../../../../core/responsive/form_factor.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/feedback/app_feedback_export.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_date_field.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../equipment/equipment_dialogs.dart';
import '../cubit/lab_reports_cubit.dart';
import '../cubit/lab_reports_state.dart';

/// Lab reports (daily/monthly/yearly PDF via ReportService.labReport).
class LabReportsTab extends StatefulWidget {
  const LabReportsTab({super.key});

  @override
  State<LabReportsTab> createState() => _LabReportsTabState();
}

class _LabReportsTabState extends State<LabReportsTab> {
  final _date = TextEditingController(text: todayIso());
  final _month = TextEditingController();
  final _year = TextEditingController();

  @override
  void dispose() {
    _date.dispose();
    _month.dispose();
    _year.dispose();
    super.dispose();
  }

  /// Card title with the per-report form-number gear.
  Widget _reportTitle(String title, String formNoKey, String dialogTitle) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          tooltip: AppText.t('رقم فورم هذا التقرير', 'This report form number'),
          onPressed: () =>
              showQaFormNoDialog(context, key: formNoKey, title: dialogTitle),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabReportsCubit>().state;
    final cubit = context.read<LabReportsCubit>();
    return BlocListener<LabReportsCubit, LabReportsState>(
      listenWhen: (prev, curr) =>
          (curr.error != null && curr.error != prev.error) ||
          (curr.lastExport != null && curr.lastExport != prev.lastExport),
      listener: (context, state) async {
        if (state.error != null) {
          AppFeedback.error(context, state.error!);
        } else if (state.lastExport != null) {
          await AppFeedbackExport.actions(context, filePath: state.lastExport!);
        }
      },
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Desktop title lives in the shell topbar.
            if (FormFactor.current.isMobile) ...[
              Text(
                AppText.t('تقارير المعمل', 'Lab reports'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _reportTitle(
                    AppText.t('التقرير اليومي', 'Daily report'),
                    ReportFormKeys.labDailyReport,
                    AppText.t(
                      'رقم فورم التقرير اليومي',
                      'Daily lab report form no.',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppDateField(
                    controller: _date,
                    label: AppText.t('التاريخ', 'Date (YYYY-MM-DD)'),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    label: AppStrings.exportPdf,
                    loading: state.busy == 'daily',
                    onPressed: state.busy == 'daily'
                        ? null
                        : () => cubit.runDaily(_date.text.trim()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _reportTitle(
                    AppText.t('التقرير الشهري', 'Monthly report'),
                    ReportFormKeys.labMonthlyReport,
                    AppText.t(
                      'رقم فورم التقرير الشهري',
                      'Monthly lab report form no.',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: AppField(
                          label: AppText.t('الشهر', 'Month (1-12)'),
                          controller: _month,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: AppField(
                          label: AppText.t('السنة', 'Year'),
                          controller: _year,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    label: AppStrings.exportPdf,
                    loading: state.busy == 'monthly',
                    onPressed: state.busy == 'monthly'
                        ? null
                        : () => cubit.runMonthly(
                            int.tryParse(_month.text.trim()) ?? 0,
                            int.tryParse(_year.text.trim()) ?? 0,
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            AppCard(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _reportTitle(
                    AppText.t('التقرير السنوي', 'Yearly report'),
                    ReportFormKeys.labYearlyReport,
                    AppText.t(
                      'رقم فورم التقرير السنوي',
                      'Yearly lab report form no.',
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AppField(
                    label: AppText.t('السنة', 'Year'),
                    controller: _year,
                  ),
                  const SizedBox(height: AppSpacing.md),
                  AppButton(
                    label: AppStrings.exportPdf,
                    loading: state.busy == 'yearly',
                    onPressed: state.busy == 'yearly'
                        ? null
                        : () => cubit.runYearly(
                            int.tryParse(_year.text.trim()) ?? 0,
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
