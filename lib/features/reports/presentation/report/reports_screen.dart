import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../core/constants/report_form_keys.dart';
import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../di/service_locator.dart';
import '../../../../core/responsive/form_factor.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/feedback/app_feedback_export.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_date_field.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_page_header.dart';
import '../../../lab/presentation/equipment/equipment_dialogs.dart';
import '../cubit/reports_cubit.dart';
import '../cubit/reports_state.dart';

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
    return '${_pad4(parsed.year)}-${_pad2(parsed.month)}-${_pad2(parsed.day)}' ==
        text;
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
            // Desktop title lives in the shell topbar; the section cards
            // below already say what each report is.
            if (FormFactor.current.isMobile) ...[
              AppPageHeader(
                title: AppText.t('التقارير', 'Reports'),
                subtitle: AppText.t(
                  'تقارير يومية وشهرية وسنوية بصيغة PDF',
                  'Daily, monthly and yearly PDF reports',
                ),
                icon: Icons.picture_as_pdf_outlined,
              ),
              const SizedBox(height: AppSpacing.md),
            ],
            Text(
              AppText.t('تقارير الخامات', 'Raw material reports'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Column(
              key: const ValueKey('raw-period-reports'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _periodCardsColumn([
                _ReportCard(
                  icon: Icons.today,
                  title: AppText.t(
                    'تقرير الخامات اليومي',
                    'Daily raw material report',
                  ),
                  formNoKey: ReportFormKeys.dailyReport,
                  formNoTitle: AppText.t(
                    'رقم فورم تقرير الخامات اليومي',
                    'Daily raw material report form no.',
                  ),
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
                                setState(
                                  () => _dateError = AppText.t(
                                    'أدخل تاريخًا صحيحًا بالصيغة YYYY-MM-DD',
                                    'Enter a valid date as YYYY-MM-DD',
                                  ),
                                );
                                return;
                              }
                              cubit.runDaily(_date.text.trim());
                            },
                    ),
                  ],
                ),
                _ReportCard(
                  icon: Icons.calendar_month,
                  title: AppText.t(
                    'تقرير الخامات الشهري',
                    'Monthly raw material report',
                  ),
                  formNoKey: ReportFormKeys.monthlyReport,
                  formNoTitle: AppText.t(
                    'رقم فورم تقرير الخامات الشهري',
                    'Monthly raw material report form no.',
                  ),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: AppField(
                            label: AppText.t('الشهر', 'Month (1-12)'),
                            controller: _month,
                            keyboardType: TextInputType.number,
                            onChanged: (_) {
                              if (_monthError == null) return;
                              setState(() => _monthError = null);
                            },
                            error: _monthError,
                          ),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: AppField(
                            label: AppText.t('السنة', 'Year'),
                            controller: _monthlyYear,
                            keyboardType: TextInputType.number,
                            onChanged: (_) {
                              if (_monthlyYearError == null) return;
                              setState(() => _monthlyYearError = null);
                            },
                            error: _monthlyYearError,
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
                                  'أدخل شهرًا بين 1 و 12',
                                  'Enter a month between 1 and 12',
                                ),
                                onError: (e) => setState(() => _monthError = e),
                              );
                              if (month == null) return;
                              final year = _requireInt(
                                _monthlyYear.text,
                                min: 1970,
                                max: 9999,
                                error: AppText.t(
                                  'أدخل سنة صحيحة',
                                  'Enter a valid year',
                                ),
                                onError: (e) =>
                                    setState(() => _monthlyYearError = e),
                              );
                              if (year == null) return;
                              cubit.runMonthly(month, year);
                            },
                    ),
                  ],
                ),
                _ReportCard(
                  icon: Icons.calendar_today,
                  title: AppText.t(
                    'تقرير الخامات السنوي',
                    'Yearly raw material report',
                  ),
                  formNoKey: ReportFormKeys.yearlyReport,
                  formNoTitle: AppText.t(
                    'رقم فورم تقرير الخامات السنوي',
                    'Yearly raw material report form no.',
                  ),
                  children: [
                    AppField(
                      label: AppText.t('السنة', 'Year'),
                      controller: _yearlyYear,
                      keyboardType: TextInputType.number,
                      onChanged: (_) {
                        if (_yearlyYearError == null) return;
                        setState(() => _yearlyYearError = null);
                      },
                      error: _yearlyYearError,
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
                                  'أدخل سنة صحيحة',
                                  'Enter a valid year',
                                ),
                                onError: (e) =>
                                    setState(() => _yearlyYearError = e),
                              );
                              if (year == null) return;
                              cubit.runYearly(year);
                            },
                    ),
                  ],
                ),
              ]),
            ),
            const SizedBox(height: AppSpacing.xl),
            const _ProductPeriodReports(),
            if (state.lastExportTitle != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                AppText.t(
                  'آخر تصدير: ${state.lastExportTitle}',
                  'Last export: ${state.lastExportTitle}',
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.success),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The parent columns live in a vertical scroll view, so cards must size
/// themselves without vertical flex, including when this tab is offstage.
List<Widget> _periodCardsColumn(List<Widget> cards) {
  return [
    for (var i = 0; i < cards.length; i++) ...[
      if (i > 0) const SizedBox(height: AppSpacing.md),
      cards[i],
    ],
  ];
}

class _ProductPeriodReports extends StatefulWidget {
  const _ProductPeriodReports();
  @override
  State<_ProductPeriodReports> createState() => _ProductPeriodReportsState();
}

class _ProductPeriodReportsState extends State<_ProductPeriodReports> {
  final _date = TextEditingController(text: todayIso());
  final _month = TextEditingController(text: '${DateTime.now().month}');
  final _monthlyYear = TextEditingController(text: '${DateTime.now().year}');
  final _yearlyYear = TextEditingController(text: '${DateTime.now().year}');
  final _errors = <String, String?>{};
  @override
  void dispose() {
    for (final controller in [_date, _month, _monthlyYear, _yearlyYear]) {
      controller.dispose();
    }
    super.dispose();
  }

  int? _integer(
    TextEditingController controller,
    String key, {
    bool month = false,
  }) => _ReportsScreenState._requireInt(
    controller.text,
    min: month ? 1 : 1970,
    max: month ? 12 : 9999,
    error: month
        ? AppText.t('أدخل شهرًا بين 1 و 12', 'Enter a month between 1 and 12')
        : AppText.t('أدخل سنة صحيحة', 'Enter a valid year'),
    onError: (error) => setState(() => _errors[key] = error),
  );
  Widget _year(TextEditingController controller, String key) => AppField(
    controller: controller,
    label: AppText.t('السنة', 'Year'),
    keyboardType: TextInputType.number,
    error: _errors[key],
    onChanged: (_) => setState(() => _errors[key] = null),
  );
  @override
  Widget build(BuildContext context) {
    final state = context.watch<ReportsCubit>().state;
    final cubit = context.read<ReportsCubit>();
    return Column(
      key: const ValueKey('product-period-reports'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          AppText.t('تقارير المنتجات', 'Product reports'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppSpacing.sm),
        ..._periodCardsColumn([
          _ReportCard(
            icon: Icons.today,
            title: AppText.t('تقرير المنتج اليومي', 'Daily product report'),
            formNoKey: ReportFormKeys.productDailyReport,
            formNoTitle: AppText.t(
              'رقم فورم تقرير المنتج اليومي',
              'Daily product report form no.',
            ),
            children: [
              Text(
                AppText.t(
                  'كل المحاضر والعينات ونتائجها وقراراتها.',
                  'All reports, samples, results and decisions.',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppDateField(
                controller: _date,
                label: AppText.t('التاريخ', 'Date (YYYY-MM-DD)'),
                errorText: _errors['date'],
                onChanged: (_) => setState(() => _errors['date'] = null),
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: AppStrings.exportPdf,
                loading: state.busy == 'product_daily',
                onPressed: state.busy.isNotEmpty
                    ? null
                    : () {
                        if (!_ReportsScreenState._isValidIsoDate(_date.text)) {
                          setState(
                            () => _errors['date'] = AppText.t(
                              'أدخل تاريخًا صحيحًا بالصيغة YYYY-MM-DD',
                              'Enter a valid date as YYYY-MM-DD',
                            ),
                          );
                          return;
                        }
                        cubit.runProductDaily(_date.text.trim());
                      },
              ),
            ],
          ),
          _ReportCard(
            icon: Icons.calendar_month,
            title: AppText.t('تقرير المنتج الشهري', 'Monthly product report'),
            formNoKey: ReportFormKeys.productMonthlyReport,
            formNoTitle: AppText.t(
              'رقم فورم تقرير المنتج الشهري',
              'Monthly product report form no.',
            ),
            children: [
              Text(
                AppText.t(
                  'متوسط عينات كل محضر وكميته.',
                  'Sample means and quantity for each report.',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: AppField(
                      controller: _month,
                      label: AppText.t('الشهر', 'Month (1-12)'),
                      keyboardType: TextInputType.number,
                      error: _errors['month'],
                      onChanged: (_) => setState(() => _errors['month'] = null),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(child: _year(_monthlyYear, 'monthlyYear')),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: AppStrings.exportPdf,
                loading: state.busy == 'product_monthly',
                onPressed: state.busy.isNotEmpty
                    ? null
                    : () {
                        final month = _integer(_month, 'month', month: true);
                        final year = _integer(_monthlyYear, 'monthlyYear');
                        if (month != null && year != null) {
                          cubit.runProductMonthly(month, year);
                        }
                      },
              ),
            ],
          ),
          _ReportCard(
            icon: Icons.calendar_today,
            title: AppText.t('تقرير المنتج السنوي', 'Yearly product report'),
            formNoKey: ReportFormKeys.productYearlyReport,
            formNoTitle: AppText.t(
              'رقم فورم تقرير المنتج السنوي',
              'Yearly product report form no.',
            ),
            children: [
              Text(
                AppText.t(
                  'متوسط عادي لمحاضر كل تشغيلة مع إجمالي كمياتها.',
                  'Unweighted report means per batch, with total quantities.',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _year(_yearlyYear, 'yearlyYear'),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: AppStrings.exportPdf,
                loading: state.busy == 'product_yearly',
                onPressed: state.busy.isNotEmpty
                    ? null
                    : () {
                        final year = _integer(_yearlyYear, 'yearlyYear');
                        if (year != null) cubit.runProductYearly(year);
                      },
              ),
            ],
          ),
        ]),
      ],
    );
  }
}

class _ReportCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;
  final String? formNoKey;
  final String? formNoTitle;
  const _ReportCard({
    required this.icon,
    required this.title,
    required this.children,
    this.formNoKey,
    this.formNoTitle,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppColors.primary, size: 20.r),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                if (formNoKey != null &&
                    getIt.isRegistered<AuthGate>() &&
                    getIt<AuthGate>().canWrite(Permission.reportsCreate))
                  IconButton(
                    tooltip: AppText.t(
                      'رقم فورم هذا التقرير',
                      'This report form number',
                    ),
                    onPressed: () => showQaFormNoDialog(
                      context,
                      key: formNoKey!,
                      title: formNoTitle ?? '',
                    ),
                    icon: const Icon(Icons.settings_outlined),
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
