import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/feedback/app_feedback_export.dart';
import '../../../design_system/tokens/app_colors.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_date_field.dart';
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
  final _month = TextEditingController(text: '${DateTime.now().month}');
  // One controller per field. They used to be a single `_year` attached to both
  // the monthly and the yearly card, so typing in one rewrote the other.
  final _monthlyYear = TextEditingController(text: '${DateTime.now().year}');
  final _yearlyYear = TextEditingController(text: '${DateTime.now().year}');

  // Inline validation messages. A mistyped value used to be swallowed by
  // `int.tryParse(...) ?? DateTime.now()`, which silently exported the wrong
  // period instead of telling the user.
  String? _dateError;
  String? _monthError;
  String? _monthlyYearError;
  String? _yearlyYearError;

  @override
  void dispose() {
    _date.dispose();
    _month.dispose();
    _monthlyYear.dispose();
    _yearlyYear.dispose();
    super.dispose();
  }

  /// Parses a required integer, reporting [error] instead of substituting a
  /// default. Returns null when [text] is not a valid value.
  static int? _requireInt(
    String text, {
    required int min,
    required int max,
    required String error,
    required void Function(String?) onError,
  }) {
    final raw = text.trim();
    final value = int.tryParse(raw);
    if (value == null || value < min || value > max) {
      onError(error);
      return null;
    }
    onError(null);
    return value;
  }

  /// A strict `YYYY-MM-DD` check: `parseIsoDate` alone would accept nonsense
  /// like `2026-02-31`, which `DateTime` silently rolls over to March.
  static bool _isValidIsoDate(String raw) {
    final text = raw.trim();
    if (text.length != 10 || text[4] != '-' || text[7] != '-') return false;
    final parsed = parseIsoDate(text);
    if (parsed == null) return false;
    return '${_pad4(parsed.year)}-${_pad2(parsed.month)}-${_pad2(parsed.day)}' == text;
  }

  static String _pad2(int n) => n.toString().padLeft(2, '0');
  static String _pad4(int n) => n.toString().padLeft(4, '0');

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReportsCubit>().state;
    final cubit = context.read<ReportsCubit>();
    return BlocListener<ReportsCubit, ReportsState>(
      listenWhen: (prev, curr) =>
          (curr.error != null && curr.error != prev.error) ||
          (curr.lastExport != null && curr.lastExport != prev.lastExport),
      listener: (context, state) async {
        if (state.error != null) {
          AppFeedback.error(context, state.error!);
        } else if (state.lastExport != null) {
          // A bare path is unreachable from inside the Android sandbox - see
          // AppFeedbackExport.
          await AppFeedbackExport.actions(
            context,
            filePath: state.lastExport!,
            documentName: state.lastExportTitle,
          );
        }
      },
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppText.t('التقارير', 'Reports'), style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: AppSpacing.md),
            _ReportCard(
              icon: Icons.today,
              title: AppText.t('تقرير اليومي', 'Daily report'),
              children: [
                AppDateField(
                  controller: _date,
                  label: AppText.t('التاريخ', 'Date (YYYY-MM-DD)'),
                  onChanged: (_) {
                    if (_dateError == null) return;
                    setState(() => _dateError = null);
                  },
                  errorText: _dateError,
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: AppStrings.exportPdf,
                  loading: state.busy == 'daily',
                  onPressed: state.busy == 'daily'
                      ? null
                      : () {
                          if (!_isValidIsoDate(_date.text)) {
                            setState(() => _dateError = AppText.t(
                                'أدخل تاريخًا صحيحًا بالصيغة YYYY-MM-DD',
                                'Enter a valid date as YYYY-MM-DD'));
                            return;
                          }
                          cubit.runDaily(_date.text.trim());
                        },
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _ReportCard(
              icon: Icons.calendar_month,
              title: AppText.t('التقرير الشهري', 'Monthly report'),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _month,
                        keyboardType: TextInputType.number,
                        onChanged: (_) {
                          if (_monthError == null) return;
                          setState(() => _monthError = null);
                        },
                        decoration: InputDecoration(
                          labelText: AppText.t('الشهر', 'Month (1-12)'),
                          isDense: true,
                          errorText: _monthError,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: TextField(
                        controller: _monthlyYear,
                        keyboardType: TextInputType.number,
                        onChanged: (_) {
                          if (_monthlyYearError == null) return;
                          setState(() => _monthlyYearError = null);
                        },
                        decoration: InputDecoration(
                          labelText: AppText.t('السنة', 'Year'),
                          isDense: true,
                          errorText: _monthlyYearError,
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
                      : () {
                          final month = _requireInt(
                            _month.text,
                            min: 1,
                            max: 12,
                            error: AppText.t(
                                'أدخل شهرًا بين 1 و 12', 'Enter a month between 1 and 12'),
                            onError: (e) => setState(() => _monthError = e),
                          );
                          if (month == null) return;
                          final year = _requireInt(
                            _monthlyYear.text,
                            min: 1970,
                            max: 9999,
                            error: AppText.t(
                                'أدخل سنة صحيحة', 'Enter a valid year'),
                            onError: (e) => setState(() => _monthlyYearError = e),
                          );
                          if (year == null) return;
                          cubit.runMonthly(month, year);
                        },
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            _ReportCard(
              icon: Icons.calendar_today,
              title: AppText.t('التقرير السنوي', 'Yearly report'),
              children: [
                TextField(
                  controller: _yearlyYear,
                  keyboardType: TextInputType.number,
                  onChanged: (_) {
                    if (_yearlyYearError == null) return;
                    setState(() => _yearlyYearError = null);
                  },
                  decoration: InputDecoration(
                    labelText: AppText.t('السنة', 'Year'),
                    isDense: true,
                    errorText: _yearlyYearError,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                AppButton(
                  label: AppStrings.exportPdf,
                  loading: state.busy == 'yearly',
                  onPressed: state.busy == 'yearly'
                      ? null
                      : () {
                          final year = _requireInt(
                            _yearlyYear.text,
                            min: 1970,
                            max: 9999,
                            error: AppText.t(
                                'أدخل سنة صحيحة', 'Enter a valid year'),
                            onError: (e) => setState(() => _yearlyYearError = e),
                          );
                          if (year == null) return;
                          cubit.runYearly(year);
                        },
                ),
              ],
            ),
            if (state.lastExportTitle != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text('آخر تصدير: ${state.lastExportTitle}',
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