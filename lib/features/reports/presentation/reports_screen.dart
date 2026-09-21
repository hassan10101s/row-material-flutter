import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import 'cubit/reports_cubit.dart';
import 'cubit/reports_state.dart';

/// Reports center (port of Web ReportsView daily/monthly/yearly actions).
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
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
    final state = context.watch<ReportsCubit>().state;
    final cubit = context.read<ReportsCubit>();
    return BlocListener<ReportsCubit, ReportsState>(
      listenWhen: (prev, curr) =>
          (curr.error != null && curr.error != prev.error) ||
          (curr.lastExport != null && curr.lastExport != prev.lastExport),
      listener: (context, state) {
        if (state.error != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.error!), backgroundColor: AppColors.danger),
          );
        } else if (state.lastExport != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تم إنشاء التقرير | Report ready: ${state.lastExport}')),
          );
        }
      },
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('التقارير | Reports', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.md),
            _ReportCard(
              icon: Icons.today,
              title: 'تقرير اليومي | Daily report',
              children: [
                TextField(
                  controller: _date,
                  decoration: const InputDecoration(
                      labelText: 'التاريخ | Date (YYYY-MM-DD)', isDense: true),
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
            const SizedBox(height: AppSpacing.md),
            _ReportCard(
              icon: Icons.calendar_month,
              title: 'التقرير الشهري | Monthly report',
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _month,
                        decoration: const InputDecoration(
                            labelText: 'الشهر | Month (1-12)', isDense: true),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: TextField(
                        controller: _year,
                        decoration: const InputDecoration(
                            labelText: 'السنة | Year', isDense: true),
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
                            int.tryParse(_month.text.trim()) ?? DateTime.now().month,
                            int.tryParse(_year.text.trim()) ?? DateTime.now().year,
                          ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _ReportCard(
              icon: Icons.calendar_today,
              title: 'التقرير السنوي | Yearly report',
              children: [
                TextField(
                  controller: _year,
                  decoration: const InputDecoration(labelText: 'السنة | Year', isDense: true),
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: AppStrings.exportPdf,
                  loading: state.busy == 'yearly',
                  onPressed: state.busy == 'yearly'
                      ? null
                      : () => cubit.runYearly(
                          int.tryParse(_year.text.trim()) ?? DateTime.now().year),
                ),
              ],
            ),
            if (state.lastExportTitle != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text('آخر تصدير | Last export: ${state.lastExportTitle}',
                  style: TextStyle(color: AppColors.success)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;
  const _ReportCard({required this.icon, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppColors.primary, size: 20.r),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            ...children,
          ],
        ),
      ),
    );
  }
}