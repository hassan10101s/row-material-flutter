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
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_selection.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_status_badge.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../widgets/bulk_export.dart';
import '../widgets/inspection_filters.dart';
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

/// Desktop inspections ledger: the pre-split screen verbatim.
class DesktopInspectionsScreen extends StatelessWidget {
  const DesktopInspectionsScreen({super.key});
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
    final saved = await showAppWindow<bool>(
      context,
      title: isProduct
          ? AppText.t('فحص منتج جديد', 'New Product Inspection')
          : AppText.t('فحص خامة جديد', 'New Material Inspection'),
      icon: Icons.add_task,
      size: AppWindowSize.lg,
      scrollBody: false,
      child: BlocProvider.value(
        value: formCubit,
        child: InspectionFormScreen(kind: kind),
      ),
    );
    await formCubit.close();
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
    final changed = await showAppWindow<bool>(
      context,
      title: AppText.t('تفاصيل الفحص', 'Inspection Details'),
      icon: Icons.fact_check_outlined,
      size: AppWindowSize.lg,
      scrollBody: false,
      child: BlocProvider(
        create: (c) => InspectionDetailCubit(
          inspectionId: id,
          repo: getIt<InspectionRepository>(),
          reports: getIt<ReportRepository>(),
          labResults: getIt<LabResultRepository>(),
        )..load(),
        child: InspectionDetailScreen(inspectionId: id),
      ),
    );
    if (changed == true && context.mounted) {
      context.read<InspectionsCubit>().load();
    }
  }

  /// Filter dialog (same UX as the lab test-history table): material/product
  /// + status + date period drafts applied on "Apply", discarded on
  /// cancel/dismiss.
  Future<void> _openFilterDialog(BuildContext context) async {
    final cubit = context.read<InspectionsCubit>();
    final isProduct = cubit.isProduct;
    final materialOptions = await loadInspectionMaterialOptions(
      ref: getIt<ReferenceRepository>(),
      isProduct: isProduct,
    );
    if (!context.mounted) return;
    var dStatus = cubit.state.status;
    var dFrom = cubit.state.dateFrom;
    var dTo = cubit.state.dateTo;
    int? dMaterial = cubit.state.materialId;

    await showAppWindow<void>(
      context,
      title: AppText.t('الفلاتر', 'Filters'),
      icon: Icons.filter_alt_outlined,
      maxWidth: 640,
      scrollBody: false,
      child: StatefulBuilder(
        builder: (dialogContext, setDraft) {
          Future<void> pickDate(bool isFrom) async {
            final now = DateTime.now();
            final initial = parseIsoDate(isFrom ? dFrom : dTo) ?? now;
            final picked = await showDatePicker(
              context: dialogContext,
              initialDate: initial,
              firstDate: DateTime(now.year - 20),
              lastDate: DateTime(now.year + 1),
            );
            if (picked == null || !dialogContext.mounted) return;
            final iso = inspectionDayIso(picked);
            setDraft(() {
              if (isFrom) {
                dFrom = iso;
                if (dTo.isNotEmpty && dTo.compareTo(iso) < 0) dTo = iso;
              } else {
                dTo = iso;
                if (dFrom.isNotEmpty && dFrom.compareTo(iso) > 0) dFrom = iso;
              }
            });
          }

          return Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: InspectionFilterGrid(
                    isProduct: isProduct,
                    status: dStatus,
                    dateFrom: dFrom,
                    dateTo: dTo,
                    onStatus: (v) => setDraft(() => dStatus = v),
                    onFrom: (v) => setDraft(() => dFrom = v),
                    onTo: (v) => setDraft(() => dTo = v),
                    onPickDate: pickDate,
                    materialLabel: isProduct
                        ? AppText.t('المنتج', 'Product')
                        : AppText.t('الخامة', 'Material'),
                    materialOptions: materialOptions,
                    selectedMaterialId: dMaterial,
                    onMaterial: (v) => setDraft(() => dMaterial = v),
                  ),
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.sm,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceSoft,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(AppRadii.sm),
                  ),
                  border: Border(top: BorderSide(color: AppColors.borderMuted)),
                ),
                child: Row(
                  children: [
                    AppButton(
                      label: AppText.t('مسح الكل', 'Clear all'),
                      style: AppButtonStyle.ghost,
                      small: true,
                      onPressed: () => setDraft(() {
                        dStatus = '';
                        dFrom = '';
                        dTo = '';
                        dMaterial = null;
                      }),
                    ),
                    const Spacer(),
                    AppButton(
                      label: AppText.t('إلغاء', 'Cancel'),
                      style: AppButtonStyle.secondary,
                      small: true,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                    const SizedBox(width: 8),
                    AppButton(
                      label: AppText.t('تطبيق', 'Apply'),
                      style: AppButtonStyle.primary,
                      small: true,
                      onPressed: () {
                        cubit.applyFilters(
                          status: dStatus,
                          dateFrom: dFrom,
                          dateTo: dTo,
                          materialId: dMaterial,
                          materialName: inspectionMaterialNameFor(
                            materialOptions,
                            dMaterial,
                            cubit.state.materialName,
                          ),
                        );
                        Navigator.of(dialogContext).pop();
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
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
    // Bulk-export selection (Vue register parity): ids of this page plus
    // the tristate for the header checkbox.
    final pageIds = [for (final r in state.visible) (r['id'] as num).toInt()];
    final selectedCount = state.selectedIds.length;
    final selectedOnPage = pageIds.where(state.selectedIds.contains).length;
    final bool? selectAllValue = pageIds.isEmpty || selectedOnPage == 0
        ? false
        : selectedOnPage == pageIds.length
        ? true
        : null;
    final selectedIndices = <int>{
      for (var i = 0; i < pageIds.length; i++)
        if (state.selectedIds.contains(pageIds[i])) i,
    };
    return AppErrorFeedback<InspectionsCubit, InspectionsState>(
      selector: (s) => s.error,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title lives in the shell topbar on desktop; search and every
            // action share one row so no vertical space is wasted.
            AppFilterBar(
              searchLabel: AppText.t('بحث', 'Search'),
              onSearch: (v) => cubit.setQuery(v),
              trailing: canCreate
                  ? AppButton(
                      icon: Icon(Icons.add, size: 18.r),
                      label: isProduct
                          ? AppText.t('فحص منتج جديد', 'New product inspection')
                          : AppStrings.newInspection,
                      onPressed: () => _newInspection(context),
                    )
                  : null,
              filters: [
                InspectionFilterButton(
                  activeCount: inspectionActiveFilterCount(state),
                  onPressed: () => _openFilterDialog(context),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 200,
                    maxWidth: 260,
                  ),
                  child: AppDropdown<String>(
                    value: state.status,
                    labelText: AppText.t('الحالة', 'Status'),
                    items: [
                      AppDropdownItem(
                        value: '',
                        label: AppText.t('الكل', 'All'),
                      ),
                      for (final s in _allStatuses)
                        AppDropdownItem(value: s, label: statusLabel(s)),
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
                if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
                  AppButton(
                    icon: Icon(Icons.qr_code_scanner_outlined, size: 18.r),
                    label: AppText.t('مسح رمز', 'Scan QR'),
                    style: AppButtonStyle.secondary,
                    onPressed: () => Navigator.of(
                      context,
                    ).push(AppPageRoute(builder: (_) => const QrScanScreen())),
                  ),
              ],
            ),
            InspectionFilterChips(
              chips: inspectionFilterChips(state, isProduct: isProduct),
              onClearChip: (key) => cubit.clearChip(key),
              onClearAll: () => cubit.clearFilters(),
            ),
            const SizedBox(height: AppSpacing.md),
            if (state.loading && state.visible.isNotEmpty)
              const AppRefreshBar(),
            if (state.loading && state.visible.isEmpty) ...[
              const AppSkeletonList(rows: 8, lines: 5, height: 460),
            ] else if (state.visible.isEmpty) ...[
              AppEmptyState(
                icon: isProduct
                    ? Icons.factory_outlined
                    : Icons.inventory_2_outlined,
                title: isProduct
                    ? AppText.t(
                        'لا توجد فحوصات منتجات',
                        'No product inspections',
                      )
                    : AppText.t('لا توجد فحوصات', 'No inspections'),
                subtitle: AppText.t(
                  'ابدأ بفحص جديد أو عدّل معايير البحث.',
                  'Start a new inspection or adjust the search.',
                ),
              ),
            ] else ...[
              if (selectedCount > 0) ...[
                SelectionActionBar(
                  selectedCount: selectedCount,
                  onExportReports: () => exportSelectedReports(context),
                  onExportLabels: () => exportSelectedLabels(context),
                  onExportTable: () => exportSelectedTable(context),
                  onClear: cubit.clearSelection,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              AppPaginatedTable(
                // Products carry no header decision: no decision column.
                columnFlex: isProduct
                    ? const [1.0, 1.15, 2.6, 1.8, 0.95, 1.4]
                    : const [1.0, 1.15, 2.6, 1.8, 0.95, 1.25, 1.4],
                rowsPerPage: state.pageSize,
                total: state.total,
                page: state.page,
                onPageChanged: cubit.setPage,
                onPageSizeChanged: cubit.setPageSize,
                selectedIndices: selectedIndices,
                selectHidden: true,
                onToggleIndex: (index) => cubit.toggleSelect(pageIds[index]),
                selectAllValue: selectAllValue,
                onToggleAll: (select) =>
                    cubit.setPageSelection(pageIds, select ?? false),
                headers: [
                  AppText.t('رقم القيد', 'Entry'),
                  AppText.t('التاريخ', 'Date'),
                  isProduct
                      ? AppText.t('المنتج', 'Product')
                      : AppText.t('المادة', 'Material'),
                  isProduct
                      ? AppText.t('التشغيلة', 'Batch')
                      : AppText.t('المورد', 'Supplier'),
                  AppText.t('الكمية', 'Qty'),
                  if (!isProduct) AppText.t('القرار', 'Decision'),
                  '',
                ],
                rows: [
                  for (final r in state.visible)
                    [
                      Text(
                        '${r['entry_code']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        parseIsoToDisplay('${r['inspection_date']}') ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${r['material_name']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        isProduct
                            ? '${r['formula_number'] ?? ''} • ${r['batch_number'] ?? ''}'
                            : '${r['supplier']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${r['quantity']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Products carry no header decision (per-sample only).
                      if (!isProduct) AppStatusBadge('${r['decision_status']}'),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Decision editing is raw-only.
                          if (!isProduct)
                            IconButton(
                              tooltip: AppText.t('تحديث القرار', 'Decision'),
                              icon: Icon(Icons.gavel_outlined, size: 18.r),
                              onPressed: () => _openDecision(context, r),
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 36,
                              ),
                            ),
                          IconButton(
                            tooltip: AppText.t('تصدير PDF', 'PDF'),
                            icon: Icon(
                              Icons.picture_as_pdf_outlined,
                              size: 18.r,
                            ),
                            onPressed: () => _exportOne(context, r, 'report'),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                          ),
                          IconButton(
                            tooltip: AppText.t('ملصق', 'Label'),
                            icon: Icon(Icons.label_outline, size: 18.r),
                            onPressed: () => _exportOne(context, r, 'label'),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                          ),
                        ],
                      ),
                    ],
                ],
                onRowTap: (index) => _openDetail(context, state.visible[index]),
                totalLabel: isProduct
                    ? '${state.total} ${AppText.t('فحص منتج', 'product inspections')}'
                    : '${state.total} ${AppText.t('فحص', 'inspections')}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
