import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../di/service_locator.dart';
import '../../reports/data/report_service.dart';

/// Lab reports (daily/monthly/yearly PDF via ReportService.labReport).
class LabReportsTab extends StatefulWidget {
  const LabReportsTab({super.key});

  @override
  State<LabReportsTab> createState() => _LabReportsTabState();
}

class _LabReportsTabState extends State<LabReportsTab> {
  final _reports = getIt<ReportService>();
  final _date = TextEditingController(text: todayIso());
  final _month = TextEditingController();
  final _year = TextEditingController();
  var _busyKind = '';

  @override
  void dispose() {
    _date.dispose();
    _month.dispose();
    _year.dispose();
    super.dispose();
  }

  Future<void> _run(String kind, Future<ReportDoc> Function() job) async {
    setState(() => _busyKind = kind);
    try {
      final doc = await job();
      final file = await _reports.saveReport(doc);
      if (!mounted) return;
      AppFeedback.success(context, 'تم التصدير | Exported: ${file.path}');
    } on AppError catch (e) {
      if (mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (mounted) AppFeedback.error(context, '$e');
    } finally {
      if (mounted) setState(() => _busyKind = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('تقارير المختبر | Lab reports', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          padding: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('التقرير اليومي | Daily report',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _date,
                  decoration: const InputDecoration(
                    labelText: 'التاريخ | Date (YYYY-MM-DD)',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: AppStrings.exportPdf,
                  loading: _busyKind == 'daily',
                  onPressed: _busyKind == 'daily'
                      ? null
                      : () => _run(
                          'daily',
                          () => _reports.labReport(
                            type: 'daily',
                            dateStr: _date.text.trim(),
                          ),
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
                Text('التقرير الشهري | Monthly report',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _month,
                        decoration: const InputDecoration(
                          labelText: 'الشهر | Month (1-12)',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: TextField(
                        controller: _year,
                        decoration: const InputDecoration(
                          labelText: 'السنة | Year',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: AppStrings.exportPdf,
                  loading: _busyKind == 'monthly',
                  onPressed: _busyKind == 'monthly'
                      ? null
                      : () => _run(
                          'monthly',
                          () => _reports.labReport(
                            type: 'monthly',
                            month: int.tryParse(_month.text.trim()),
                            year: int.tryParse(_year.text.trim()),
                          ),
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
                Text('التقرير السنوي | Yearly report',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _year,
                  decoration: const InputDecoration(
                    labelText: 'السنة | Year',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: AppStrings.exportPdf,
                  loading: _busyKind == 'yearly',
                  onPressed: _busyKind == 'yearly'
                      ? null
                      : () => _run(
                          'yearly',
                          () => _reports.labReport(
                            type: 'yearly',
                            year: int.tryParse(_year.text.trim()),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}