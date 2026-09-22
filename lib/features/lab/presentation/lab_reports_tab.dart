import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import 'cubit/lab_reports_cubit.dart';
import 'cubit/lab_reports_state.dart';

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

  @override
  Widget build(BuildContext context) {
    final state = context.watch<LabReportsCubit>().state;
    final cubit = context.read<LabReportsCubit>();
    return BlocListener<LabReportsCubit, LabReportsState>(
      listenWhen: (prev, curr) =>
          (curr.error != null && curr.error != prev.error) ||
          (curr.lastExport != null && curr.lastExport != prev.lastExport),
      listener: (context, state) {
        if (state.error != null) {
          AppFeedback.error(context, state.error!);
        } else if (state.lastExport != null) {
          AppFeedback.success(
            context,
            '${AppText.t('تم التصدير', 'Exported')}: ${state.lastExport}',
          );
        }
      },
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Text(AppText.t('تقارير المختبر', 'Lab reports'),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            padding: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppText.t('التقرير اليومي', 'Daily report'),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _date,
                    decoration: InputDecoration(
                      labelText: AppText.t('التاريخ', 'Date (YYYY-MM-DD)'),
                      isDense: true,
                    ),
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
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            padding: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppText.t('التقرير الشهري', 'Monthly report'),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _month,
                          decoration: InputDecoration(
                            labelText: AppText.t('الشهر', 'Month (1-12)'),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: TextField(
                          controller: _year,
                          decoration: InputDecoration(
                            labelText: AppText.t('السنة', 'Year'),
                            isDense: true,
                          ),
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
          ),
          const SizedBox(height: AppSpacing.md),
          AppCard(
            padding: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppText.t('التقرير السنوي', 'Yearly report'),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: _year,
                    decoration: InputDecoration(
                      labelText: AppText.t('السنة', 'Year'),
                      isDense: true,
                    ),
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
          ),
          ],
        ),
      ),
    );
  }
}