import 'package:flutter/material.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_card.dart';
import '../../../di/service_locator.dart';
import '../../reports/data/report_service.dart';

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
  var _busyKind = '';
  String? _lastExport;

  @override
  void dispose() {
    _date.dispose();
    _month.dispose();
    _year.dispose();
    super.dispose();
  }

  Future<void> _run(String kind, Future<ReportDoc> Function() job) async {
    setState(() {
      _busyKind = kind;
      _lastExport = null;
    });
    try {
      final doc = await job();
      if (!mounted) return;
      setState(() {
        _busyKind = '';
        _lastExport = doc.title;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تم إنشاء التقرير | Report ready: ${doc.filename}')),
      );
    } on AppError catch (e) {
      if (mounted) _err(e.message);
    } catch (e) {
      if (mounted) _err('$e');
    } finally {
      if (mounted && _busyKind == kind) setState(() => _busyKind = '');
    }
  }

  void _err(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message), backgroundColor: AppColors.danger));
  }

  @override
  Widget build(BuildContext context) {
    final service = getIt<ReportService>();
    return SingleChildScrollView(
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
                decoration: const InputDecoration(labelText: 'التاريخ | Date (YYYY-MM-DD)', isDense: true),
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: AppStrings.exportPdf,
                loading: _busyKind == 'daily',
                onPressed: _busyKind == 'daily'
                    ? null
                    : () => _run('daily', () => service.dailyReport(_date.text.trim())),
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
                      decoration: const InputDecoration(labelText: 'الشهر | Month (1-12)', isDense: true),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: TextField(
                      controller: _year,
                      decoration: const InputDecoration(labelText: 'السنة | Year', isDense: true),
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
                        () => service.monthlyReport(
                          month: int.tryParse(_month.text.trim()) ?? DateTime.now().month,
                          year: int.tryParse(_year.text.trim()) ?? DateTime.now().year,
                        ),
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
                loading: _busyKind == 'yearly',
                onPressed: _busyKind == 'yearly'
                    ? null
                    : () => _run(
                        'yearly',
                        () => service.yearlyReport(
                            year: int.tryParse(_year.text.trim()) ?? DateTime.now().year),
                      ),
              ),
            ],
          ),
          if (_lastExport != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text('آخر تصدير | Last export: $_lastExport',
                style: TextStyle(color: AppColors.success)),
          ],
        ],
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
                Icon(icon, color: AppColors.primary, size: 20),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
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