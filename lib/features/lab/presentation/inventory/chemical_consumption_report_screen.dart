import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../app/auth_gate.dart';
import '../../../../core/auth/permissions.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/export/table_html_export.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/feedback/app_feedback_export.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_adaptive.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_dropdown.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_skeleton.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../di/service_locator.dart';
import '../../../reports/domain/report_repository.dart';
import '../../domain/chemical_consumption_report.dart';
import '../../domain/lab_local_repository.dart';
import '../cubit/chemical_consumption_cubit.dart';

class ChemicalConsumptionReportButton extends StatelessWidget {
  const ChemicalConsumptionReportButton({super.key});
  @override
  Widget build(BuildContext context) {
    final gate = getIt<AuthGate>();
    if (!gate.canWrite(Permission.reportsRead) ||
        !gate.canWrite(Permission.labResultsRead)) {
      return const SizedBox.shrink();
    }
    return IconButton(
      tooltip: AppText.t(
        'تقرير استهلاك الكيماويات',
        'Chemical consumption report',
      ),
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      icon: const Icon(Icons.science_outlined),
      onPressed: () => ChemicalConsumptionReportScreen.open(context),
    );
  }
}

class ChemicalConsumptionReportScreen extends StatefulWidget {
  const ChemicalConsumptionReportScreen({
    super.key,
    required this.reports,
    required this.canExport,
  });
  final ReportRepository reports;
  final bool Function() canExport;

  static Future<void> open(BuildContext context) => showAppContent<void>(
    context,
    title: AppText.t('تقرير استهلاك الكيماويات', 'Chemical consumption report'),
    icon: Icons.science_outlined,
    size: AppWindowSize.lg,
    scrollBody: false,
    height: 680,
    builder: (_, _) => BlocProvider(
      create: (_) =>
          ChemicalConsumptionCubit(repo: getIt<LabLocalRepository>())
            ..refresh(),
      child: ChemicalConsumptionReportScreen(
        reports: getIt<ReportRepository>(),
        canExport: () => getIt<AuthGate>().canWrite(Permission.reportsExport),
      ),
    ),
  );

  @override
  State<ChemicalConsumptionReportScreen> createState() =>
      _ChemicalConsumptionReportScreenState();
}

class _ChemicalConsumptionReportScreenState
    extends State<ChemicalConsumptionReportScreen> {
  bool _exporting = false;

  Future<void> _pickPeriod() async {
    final cubit = context.read<ChemicalConsumptionCubit>();
    final today = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1900),
      lastDate: DateTime(today.year, today.month, today.day),
      initialDateRange: DateTimeRange(
        start: cubit.state.period.from,
        end: cubit.state.period.to,
      ),
    );
    if (picked != null && mounted) {
      await cubit.selectPeriod(ConsumptionPeriod(picked.start, picked.end));
    }
  }

  Future<void> _export({required bool pdf}) async {
    final state = context.read<ChemicalConsumptionCubit>().state;
    final report = state.report;
    if (_exporting ||
        state.loading ||
        state.error != null ||
        report == null ||
        report.rows.isEmpty) {
      return;
    }
    if (!widget.canExport()) {
      AppFeedback.error(
        context,
        AppText.t(
          'لا تملك صلاحية تصدير التقارير.',
          'Report export is not permitted.',
        ),
      );
      return;
    }
    setState(() => _exporting = true);
    try {
      if (pdf) {
        final doc = await widget.reports.chemicalConsumptionReport(report);
        final file = await widget.reports.saveReport(doc);
        if (!mounted) return;
        await AppFeedbackExport.actions(
          context,
          filePath: file.path,
          documentName: doc.title,
        );
      } else {
        final html = await widget.reports.chemicalConsumptionHtml(report);
        if (!mounted) return;
        await TableHtmlExport.writeHtmlFile(
          context,
          filePrefix: 'chemical_consumption',
          html: html,
        );
      }
    } catch (error) {
      if (mounted) AppFeedback.errorFrom(context, error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<ChemicalConsumptionCubit>().state;
    final cubit = context.read<ChemicalConsumptionCubit>();
    final rows = state.report?.rows ?? const <ChemicalConsumptionRow>[];
    final chemicals =
        state.report?.chemicals ?? const <ChemicalConsumptionRow>[];
    final ready =
        !state.loading &&
        !_exporting &&
        state.error == null &&
        rows.isNotEmpty &&
        widget.canExport();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppDropdown<int>(
          value: state.inventoryId ?? 0,
          labelText: AppText.t('المادة', 'Chemical'),
          items: [
            AppDropdownItem(
              value: 0,
              label: AppText.t('كل المواد', 'All chemicals'),
            ),
            for (final row in chemicals)
              AppDropdownItem(
                value: row.inventoryId,
                label: '${row.name} (${row.unit})',
              ),
            if (state.inventoryId != null &&
                !chemicals.any((row) => row.inventoryId == state.inventoryId))
              AppDropdownItem(
                value: state.inventoryId!,
                label: AppText.t('مادة غير متاحة', 'Unavailable chemical'),
              ),
          ],
          onChanged: _exporting
              ? null
              : (value) => cubit.selectChemical(value == 0 ? null : value),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppButton(
              label: state.period.label,
              icon: const Icon(Icons.date_range_outlined),
              style: AppButtonStyle.secondary,
              onPressed: _exporting ? null : _pickPeriod,
            ),
            IconButton(
              tooltip: AppText.t('تحديث', 'Refresh'),
              onPressed: state.loading || _exporting ? null : cubit.refresh,
              icon: const Icon(Icons.refresh),
            ),
            AppButton(
              label: AppText.t('طباعة', 'Print'),
              icon: const Icon(Icons.print_outlined),
              style: AppButtonStyle.secondary,
              onPressed: ready ? () => _export(pdf: false) : null,
            ),
            AppButton(
              label: AppText.t('حفظ PDF', 'Save PDF'),
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: ready ? () => _export(pdf: true) : null,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          AppText.t(
            'الصافي = المستهلك - المرتجع داخل الفترة، بوحدة كل مادة.',
            'Net = consumed - returned within the period, in each chemical\'s unit.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AppSpacing.sm),
        if (_exporting || state.loading) const LinearProgressIndicator(),
        Expanded(
          child: state.loading
              ? const AppSkeletonList(rows: 5, lines: 2, height: 320)
              : state.error != null
              ? AppErrorState(
                  title: AppText.t(
                    'تعذر تحميل التقرير',
                    'Could not load report',
                  ),
                  subtitle: state.error,
                  onRetry: cubit.refresh,
                )
              : rows.isEmpty
              ? AppEmptyState(
                  icon: Icons.science_outlined,
                  title: AppText.t(
                    'لا توجد مواد في الفترة المحددة',
                    'No chemicals in this period',
                  ),
                )
              : appUsesDesktopChrome(context)
              ? AppPaginatedTable(
                  height: null,
                  columnFlex: const [3, 1, 1.4, 1.4, 1.4],
                  headers: [
                    AppText.t('المادة', 'Chemical'),
                    AppText.t('الوحدة', 'Unit'),
                    AppText.t('المستهلك', 'Consumed'),
                    AppText.t('المرتجع', 'Returned'),
                    AppText.t('الصافي', 'Net'),
                  ],
                  rows: [
                    for (final row in rows)
                      [
                        Text(
                          row.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(row.unit),
                        Text(ChemicalConsumptionRow.quantity(row.consumed)),
                        Text(ChemicalConsumptionRow.quantity(row.returned)),
                        Text(ChemicalConsumptionRow.quantity(row.net)),
                      ],
                  ],
                )
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (_, index) {
                    final row = rows[index];
                    return AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${row.name} (${row.unit})',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Wrap(
                            spacing: AppSpacing.lg,
                            runSpacing: AppSpacing.xs,
                            children: [
                              Text(
                                '${AppText.t('المستهلك', 'Consumed')}: ${ChemicalConsumptionRow.quantity(row.consumed)}',
                              ),
                              Text(
                                '${AppText.t('المرتجع', 'Returned')}: ${ChemicalConsumptionRow.quantity(row.returned)}',
                              ),
                              Text(
                                '${AppText.t('الصافي', 'Net')}: ${ChemicalConsumptionRow.quantity(row.net)}',
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
