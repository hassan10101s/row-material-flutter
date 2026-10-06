import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../app/auth_gate.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../design_system/animations/app_animations.dart';
import '../../../design_system/feedback/app_error_feedback.dart';
import '../../../design_system/feedback/app_feedback.dart';
import '../../../design_system/feedback/app_feedback_export.dart';
import '../../../design_system/tokens/app_breakpoints.dart';
import '../../../design_system/tokens/app_spacing.dart';
import '../../../design_system/widgets/app_button.dart';
import '../../../design_system/widgets/app_empty_state.dart';
import '../../../design_system/widgets/app_paginated_table.dart';
import '../../../design_system/widgets/app_skeleton.dart';
import '../../../design_system/widgets/app_status_badge.dart';
import '../../../di/service_locator.dart';
import '../../reference/domain/reference_repository.dart';
import '../../reports/domain/report_repository.dart';
import '../../lab/domain/lab_result_repository.dart';
import '../domain/inspection_repository.dart';
import 'cubit/inspection_detail_cubit.dart';
import 'cubit/inspection_form_cubit.dart';
import 'cubit/inspections_cubit.dart';
import 'cubit/inspections_state.dart';
import 'inspection_detail_screen.dart';
import 'inspection_form_screen.dart';

const _allStatuses = [
  'APPROVED',
  'CONDITIONAL_APPROVAL',
  'PARTIAL_REJECTION',
  'FULL_REJECTION',
];

/// Inspections ledger: search, filter, create, PDFs and follow-up report.
class InspectionsScreen extends StatelessWidget {
  const InspectionsScreen({super.key});
  Future<void> _newInspection(BuildContext context) async {
    final saved = await Navigator.of(context).push<bool>(
      AppPageRoute(
        builder: (_) => BlocProvider(
          create: (c) => InspectionFormCubit(
            repo: getIt<InspectionRepository>(),
            reference: getIt<ReferenceRepository>(),
          )..loadMaterials(),
          child: const InspectionFormScreen(),
        ),
      ),
    );
    if (saved == true && context.mounted) {
      context.read<InspectionsCubit>().load();
    }
  }

  Future<void> _openDetail(
    BuildContext context,
    Map<String, dynamic> row,
  ) async {
    final id = (row['id'] as num).toInt();
    await _pushDetail(context, id);
  }

  Future<void> _openDecision(
    BuildContext context,
    Map<String, dynamic> row,
  ) async {
    final id = (row['id'] as num).toInt();
    await _pushDetail(context, id);
  }

  Future<void> _pushDetail(BuildContext context, int id) async {
    final changed = await Navigator.of(context).push<bool>(
      AppPageRoute(
        builder: (_) => BlocProvider(
          create: (c) => InspectionDetailCubit(
            inspectionId: id,
            repo: getIt<InspectionRepository>(),
            reports: getIt<ReportRepository>(),
            labResults: getIt<LabResultRepository>(),
          )..load(),
          child: InspectionDetailScreen(inspectionId: id),
        ),
      ),
    );
    if (changed == true && context.mounted) {
      context.read<InspectionsCubit>().load();
    }
  }

  Future<void> _exportFollowUp(BuildContext context) async {
    try {
      final path = await context.read<InspectionsCubit>().exportFollowUp();
      if (!context.mounted) return;
      if (path == null) {
        AppFeedback.error(
          context,
          AppText.t('لا توجد فحوصات للتقرير', 'Nothing to report.'),
        );
        return;
      }
      await AppFeedbackExport.actions(context, filePath: path);
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  Future<void> _exportOne(
    BuildContext context,
    Map<String, dynamic> row,
    String kind,
  ) async {
    final id = (row['id'] as num).toInt();
    try {
      final reports = getIt<ReportRepository>();
      final doc = kind == 'label'
          ? await reports.sampleLabelPdf(id)
          : await reports.inspectionReport(id);
      final date = parseIsoDate('${row['inspection_date'] ?? ''}');
      final file = await reports.saveReport(doc, date: date);
      if (!context.mounted) return;
      // Not a bare "Exported: <path>" banner: on a phone that path is inside
      // the app sandbox and cannot be opened, so the user is offered the actions
      // that actually reach the file.
      await AppFeedbackExport.actions(
        context,
        filePath: file.path,
        documentName: file.uri.pathSegments.isEmpty
            ? null
            : file.uri.pathSegments.last,
      );
    } on AppError catch (e) {
      if (context.mounted) AppFeedback.error(context, e.message);
    } catch (e) {
      if (context.mounted) AppFeedback.errorFrom(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<InspectionsCubit>().state;
    final cubit = context.read<InspectionsCubit>();
    final user = getIt<AuthGate>().currentUser;
    final canCreate = user?.canCreateInspection ?? false;
    return AppErrorFeedback<InspectionsCubit, InspectionsState>(
      selector: (s) => s.error,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              AppStrings.inspections,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: AppSpacing.md),
            LayoutBuilder(
              builder: (context, constraints) {
                final search = TextField(
                  onChanged: cubit.setQuery,
                  decoration: InputDecoration(
                    labelText: AppText.t('بحث', 'Search'),
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 20.r),
                  ),
                );
                final filters = <Widget>[
                  SizedBox(
                    width: 260.w,
                    child: DropdownButtonFormField<String>(
                      initialValue: state.status,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: AppText.t('الحالة', 'Status'),
                        isDense: true,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: '',
                          child: Text(AppText.t('الكل', 'All')),
                        ),
                        for (final s in _allStatuses)
                          DropdownMenuItem(value: s, child: Text(statusLabel(s))),
                      ],
                      onChanged: (v) => cubit.setStatus(v ?? ''),
                    ),
                  ),
                  AppButton(
                    icon: Icon(Icons.description_outlined, size: 18.r),
                    label: AppText.t('تقرير متابعة', 'Follow-up'),
                    style: AppButtonStyle.secondary,
                    loading: state.exporting,
                    onPressed: state.exporting
                        ? null
                        : () => _exportFollowUp(context),
                  ),
                  if (canCreate)
                    AppButton(
                      icon: Icon(Icons.add, size: 18.r),
                      label: AppStrings.newInspection,
                      onPressed: () => _newInspection(context),
                    ),
                ];
                if (constraints.maxWidth >= AppBreakpoints.expanded) {
                  return Row(
                    children: [
                      Expanded(child: search),
                      const SizedBox(width: AppSpacing.md),
                      ...filters,
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    search,
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: AppSpacing.md,
                      runSpacing: AppSpacing.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: filters,
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),
            if (state.loading && state.visible.isNotEmpty) const AppRefreshBar(),
            if (state.loading && state.visible.isEmpty) ...[
              const AppSkeletonList(rows: 8, lines: 5, height: 460),
            ] else if (state.visible.isEmpty) ...[
              AppEmptyState(
                icon: Icons.inventory_2_outlined,
                title: AppText.t('لا توجد فحوصات', 'No inspections'),
                subtitle: 'ابدأ بفحص جديد أو عدّل معايير البحث.',
              ),
            ] else
              AppPaginatedTable(
                columnFlex: const [1.0, 1.15, 2.6, 1.8, 0.95, 1.25, 1.4],
                headers: [
                  AppText.t('رقم القيد', 'Entry'),
                  AppText.t('التاريخ', 'Date'),
                  AppText.t('المادة', 'Material'),
                  AppText.t('المورد', 'Supplier'),
                  AppText.t('الكمية', 'Qty'),
                  AppText.t('القرار', 'Decision'),
                  '',
                ],
                rows: [
                  for (final r in state.visible)
                    [
                      Text('${r['entry_code']}'),
                      Text(parseIsoToDisplay('${r['inspection_date']}') ?? ''),
                      Text(
                        '${r['material_name']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text('${r['supplier']}', overflow: TextOverflow.ellipsis),
                      Text('${r['quantity']}'),
                      AppStatusBadge('${r['decision_status']}'),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: AppText.t('تحديث القرار', 'Decision'),
                            icon: Icon(Icons.gavel_outlined, size: 18.r),
                            onPressed: () => _openDecision(context, r),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                          ),
                          IconButton(
                            tooltip: AppText.t('تصدير PDF', 'PDF'),
                            icon: Icon(Icons.picture_as_pdf_outlined, size: 18.r),
                            onPressed: () => _exportOne(context, r, 'report'),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                          ),
                          IconButton(
                            tooltip: AppText.t('ملصق', 'Label'),
                            icon: Icon(Icons.label_outline, size: 18.r),
                            onPressed: () => _exportOne(context, r, 'label'),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                          ),
                        ],
                      ),
                    ],
                ],
                onRowTap: (index) => _openDetail(context, state.visible[index]),
                totalLabel:
                    '${state.visible.length} ${AppText.t('فحص', 'inspections')}',
              ),
          ],
        ),
      ),
    );
  }
}
