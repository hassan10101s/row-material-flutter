import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../app/auth_gate.dart';
import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/utils/app_dates.dart';
import '../../../../../core/utils/app_exceptions.dart';
import '../../../../../design_system/animations/app_animations.dart';
import '../../../../../design_system/feedback/app_error_feedback.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/feedback/app_feedback_export.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_selection.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_status_badge.dart';
import '../../../../../di/service_locator.dart';
import '../widgets/bulk_export.dart';
import '../../../../reference/domain/reference_repository.dart';
import '../../../../reports/domain/report_repository.dart';
import '../../../../lab/domain/lab_result_repository.dart';
import '../../../domain/inspection_repository.dart';
import '../../cubit/inspection_detail_cubit.dart';
import '../../cubit/inspection_form_cubit.dart';
import '../../cubit/inspections_cubit.dart';
import '../../cubit/inspections_state.dart';
import '../../detail/inspection_detail_screen.dart';
import '../../form/inspection_form_screen.dart';
import '../../qr/qr_scan_screen.dart';

const _allStatuses = [
  'APPROVED',
  'CONDITIONAL_APPROVAL',
  'PARTIAL_REJECTION',
  'FULL_REJECTION',
];

/// Mobile inspections: card list + full-screen routes (no tables/dialogs).
class MobileInspectionsScreen extends StatelessWidget {
  const MobileInspectionsScreen({super.key});

  Future<void> _newInspection(BuildContext context) async {
    final kind = context.read<InspectionsCubit>().kind;
    final isProduct = kind == 'product';
    final formCubit = InspectionFormCubit(
      repo: getIt<InspectionRepository>(),
      reference: getIt<ReferenceRepository>(),
    );
    if (isProduct) {
      formCubit.loadProducts();
    } else {
      formCubit.loadMaterials();
    }
    final saved = await Navigator.of(context).push<bool>(
      AppPageRoute(
        builder: (_) => BlocProvider.value(
          value: formCubit,
          // Stepped chrome: same sections, same save, one step at a time.
          child: InspectionFormScreen(wizard: true, kind: kind),
        ),
      ),
    );
    await formCubit.close();
    if (saved == true && context.mounted) {
      context.read<InspectionsCubit>().load();
    }
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
    final isProduct = cubit.isProduct;
    final user = getIt<AuthGate>().currentUser;
    final canCreate = user?.canCreateInspection ?? false;
    // Bulk-export selection, same cubit state as the desktop table.
    final pageIds = [
      for (final r in state.visible) (r['id'] as num).toInt(),
    ];
    final selectedCount = state.selectedIds.length;
    final allPageSelected = pageIds.isNotEmpty &&
        pageIds.every(state.selectedIds.contains);
    return AppErrorFeedback<InspectionsCubit, InspectionsState>(
      selector: (s) => s.error,
      child: Scaffold(
        floatingActionButton: canCreate
            ? FloatingActionButton(
                onPressed: () => _newInspection(context),
                child: Icon(Icons.add, size: 24.r),
              )
            : null,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.pageMobile),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppPageHeader(
                title: isProduct
                    ? AppText.t('فحص المنتجات', 'Product inspections')
                    : AppStrings.inspections,
                subtitle:
                    '${state.total} ${AppText.t('فحص', 'inspections')}',
                icon: isProduct
                    ? Icons.factory_outlined
                    : Icons.inventory_2_outlined,
              ),
              const SizedBox(height: AppSpacing.md),
              AppFilterBar(
                searchLabel: AppText.t('بحث', 'Search'),
                onSearch: (v) => cubit.setQuery(v),
                filters: [
                  DropdownButtonFormField<String>(
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
                        DropdownMenuItem(
                            value: s, child: Text(statusLabel(s))),
                    ],
                    onChanged: (v) => cubit.setStatus(v ?? ''),
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
                  if (state.visible.isNotEmpty)
                    AppButton(
                      icon: Icon(
                        allPageSelected
                            ? Icons.deselect_outlined
                            : Icons.select_all_outlined,
                        size: 18.r,
                      ),
                      label: allPageSelected
                          ? AppText.t('إلغاء التحديد', 'Clear selection')
                          : AppText.t('تحديد الكل', 'Select all'),
                      style: AppButtonStyle.secondary,
                      onPressed: () => cubit.setPageSelection(
                        pageIds,
                        !allPageSelected,
                      ),
                    ),
                  if (!kIsWeb &&
                      defaultTargetPlatform == TargetPlatform.android)
                    AppButton(
                      icon: Icon(
                        Icons.qr_code_scanner_outlined,
                        size: 18.r,
                      ),
                      label: AppText.t('مسح رمز', 'Scan QR'),
                      style: AppButtonStyle.secondary,
                      onPressed: () => Navigator.of(context).push(
                        AppPageRoute(
                          builder: (_) => const QrScanScreen(),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              if (state.loading && state.visible.isNotEmpty)
                const AppRefreshBar(),
              if (state.loading && state.visible.isEmpty) ...[
                const AppSkeletonList(rows: 6, lines: 3, height: 380),
              ] else if (state.visible.isEmpty) ...[
                AppEmptyState(
                  icon: isProduct
                      ? Icons.factory_outlined
                      : Icons.inventory_2_outlined,
                  title: isProduct
                      ? AppText.t(
                          'لا توجد فحوصات منتجات', 'No product inspections')
                      : AppText.t('لا توجد فحوصات', 'No inspections'),
                  subtitle: AppText.t(
                      'ابدأ بفحص جديد أو عدّل معايير البحث.',
                      'Start a new inspection or adjust the search.'),
                ),
              ] else ...[
                if (selectedCount > 0) ...[
                  SelectionActionBar(
                    selectedCount: selectedCount,
                    onExportReports: () => exportSelectedReports(context),
                    onExportLabels: () => exportSelectedLabels(context),
                    onClear: cubit.clearSelection,
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: state.visible.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final r = state.visible[index];
                    final id = (r['id'] as num).toInt();
                    return _InspectionCard(
                      entry: '${r['entry_code']}',
                      date:
                          parseIsoToDisplay('${r['inspection_date']}') ?? '',
                      material: '${r['material_name']}',
                      supplier: isProduct
                          ? '${r['formula_number'] ?? ''} • ${r['batch_number'] ?? ''}'
                          : '${r['supplier']}',
                      qty: '${r['quantity']}',
                      decision: '${r['decision_status']}',
                      selected: state.selectedIds.contains(id),
                      onSelectChanged: (_) => cubit.toggleSelect(id),
                      onTap: () => _pushDetail(context, id),
                      onPdf: () => _exportOne(context, r, 'report'),
                      onLabel: () => _exportOne(context, r, 'label'),
                    );
                  },
                ),
              ],
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }
}

class _InspectionCard extends StatelessWidget {
  const _InspectionCard({
    required this.entry,
    required this.date,
    required this.material,
    required this.supplier,
    required this.qty,
    required this.decision,
    required this.selected,
    required this.onSelectChanged,
    required this.onTap,
    required this.onPdf,
    required this.onLabel,
  });

  final String entry;
  final String date;
  final String material;
  final String supplier;
  final String qty;
  final String decision;
  final bool selected;
  final ValueChanged<bool?> onSelectChanged;
  final VoidCallback onTap;
  final VoidCallback onPdf;
  final VoidCallback onLabel;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      // Touch-only device: skip the hover tracking machinery per row.
      enableHover: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: selected,
                visualDensity: VisualDensity.compact,
                onChanged: onSelectChanged,
              ),
              Expanded(
                child: Text(
                  '$entry • $material',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
              AppStatusBadge(decision),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$date • $supplier • $qty',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12.spMax,
              color: AppColors.textMuted,
            ),
          ),
          const Divider(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: AppText.t('تصدير PDF', 'PDF'),
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                onPressed: onPdf,
                icon: Icon(Icons.picture_as_pdf_outlined, size: 20.r),
              ),
              IconButton(
                tooltip: AppText.t('ملصق', 'Label'),
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                onPressed: onLabel,
                icon: Icon(Icons.label_outline, size: 20.r),
              ),
              IconButton(
                tooltip: AppText.t('التفاصيل', 'Details'),
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                onPressed: onTap,
                icon: Icon(Icons.chevron_left, size: 22.r),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
