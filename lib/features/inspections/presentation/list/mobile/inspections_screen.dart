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
import '../../../../../design_system/widgets/app_page_size.dart';
import '../../../../../design_system/widgets/app_search_field.dart';
import '../../../../../design_system/widgets/app_status_badge.dart';
import '../../../../../design_system/widgets/app_selection.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_window.dart'
    show showAppOverlay;
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

  /// Filter bottom sheet (same UX as the lab test-history table):
  /// material/product + status + date period drafts applied on "Apply",
  /// discarded on cancel/dismiss.
  Future<void> _openFilterSheet(BuildContext context) async {
    final cubit = context.read<InspectionsCubit>();
    final isProduct = cubit.isProduct;
    final materialOptions = await loadInspectionMaterialOptions(
      ref: getIt<ReferenceRepository>(),
      isProduct: isProduct,
    );
    final supplierOptions = await loadInspectionSupplierOptions(
      getIt<InspectionRepository>(),
    );
    if (!context.mounted) return;
    var dStatus = cubit.state.status;
    var dReason = cubit.state.reason;
    var dFrom = cubit.state.dateFrom;
    var dTo = cubit.state.dateTo;
    var dSupplier = cubit.state.supplier;
    int? dMaterial = cubit.state.materialId;

    await showAppOverlay<void>(
      context,
      title: AppText.t('الفلاتر', 'Filters'),
      icon: Icons.filter_alt_outlined,
      builder: (sheetContext, close) {
        return StatefulBuilder(
          builder: (context, setDraft) {
            Future<void> pickDate(bool isFrom) async {
              final now = DateTime.now();
              final initial = parseIsoDate(isFrom ? dFrom : dTo) ?? now;
              final picked = await showDatePicker(
                context: context,
                initialDate: initial,
                firstDate: DateTime(now.year - 20),
                lastDate: DateTime(now.year + 1),
              );
              if (picked == null) return;
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
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    child: InspectionFilterGrid(
                      isProduct: isProduct,
                      status: dStatus,
                      reason: dReason,
                      onReason: (v) => setDraft(() => dReason = v),
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
                      supplierOptions: supplierOptions,
                      selectedSupplier: dSupplier,
                      onSupplier: (v) => setDraft(() => dSupplier = v ?? ''),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: AppSpacing.mobileCtaHeight.h,
                        child: AppButton(
                          label: AppText.t('إلغاء', 'Cancel'),
                          style: AppButtonStyle.secondary,
                          onPressed: () => close(),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      flex: 2,
                      child: SizedBox(
                        height: AppSpacing.mobileCtaHeight.h,
                        child: AppButton(
                          label: AppText.t('تطبيق', 'Apply'),
                          onPressed: () {
                            cubit.applyFilters(
                              status: dStatus,
                              reason: dReason,
                              dateFrom: dFrom,
                              dateTo: dTo,
                              supplier: dSupplier,
                              materialId: dMaterial,
                              materialName: inspectionMaterialNameFor(
                                materialOptions,
                                dMaterial,
                                cubit.state.materialName,
                              ),
                            );
                            close();
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
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
    // Safety net for cubits born with the desktop default (200): phones never
    // page more than `kMobileMaxPageSize`. The router/center already pass 25
    // via `initialPageSize`, so this fires at most once per cubit lifetime.
    if (state.pageSize > kMobileMaxPageSize) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) cubit.setPageSize(kMobileMaxPageSize);
      });
    }
    final isProduct = cubit.isProduct;
    final user = getIt<AuthGate>().currentUser;
    final canCreate = user?.canCreateInspection ?? false;
    // Bulk-export selection, same cubit state as the desktop table.
    final pageIds = [for (final r in state.visible) (r['id'] as num).toInt()];
    final selectedCount = state.selectedIds.length;
    final allPageSelected =
        pageIds.isNotEmpty && pageIds.every(state.selectedIds.contains);
    final activeFilterCount = inspectionActiveFilterCount(state);
    return AppErrorFeedback<InspectionsCubit, InspectionsState>(
      selector: (s) => s.error,
      child: Scaffold(
        floatingActionButton: canCreate
            ? FloatingActionButton(
                // No hero animation: two registers (raw + product) live in one
                // IndexedStack, so two default-tagged FAB heroes share one
                // route subtree and crash navigation (duplicate Hero tag).
                heroTag: null,
                onPressed: () => _newInspection(context),
                child: Icon(Icons.add, size: 24.r),
              )
            : null,
        body: RefreshIndicator(
          onRefresh: () => cubit.load(),
          // Perf: page cards can fill more than one screen (kMobileMaxPageSize
          // up to 25); the old eager Column built and laid out every card at
          // once. A CustomScrollView keeps the card list virtualized.
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(AppSpacing.pageMobile),
                sliver: SliverToBoxAdapter(
                  // Header-only entrance, same convention as the lab/reference
                  // tabs: per-card entrances would keep timers and saveLayers
                  // alive while the card list scrolls.
                  child: AppEntrance(
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
                        // ── Compact filter row (mobile only) ───────────────────
                        // One ~48dp row: the search takes the width, everything else
                        // is an icon button. The old bar stacked a full-width search
                        // + a full-width status dropdown + three buttons, which ate
                        // half the screen before the first card. Status now lives
                        // only in the filter sheet (same source of truth, no loss).
                        Row(
                          children: [
                            Expanded(
                              child: DebouncedSearchField(
                                hint: isProduct
                                    ? AppText.t(
                                        'بحث في المنتجات...',
                                        'Search products...',
                                      )
                                    : AppText.t(
                                        'بحث في الخامات...',
                                        'Search materials...',
                                      ),
                                initialValue: state.query,
                                onChanged: (v) => cubit.setQuery(v),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            // Quick period access (الفترة) beside the filter sheet —
                            // اليوم / آخر ٧ / آخر ٣٠ / الكل, and نطاق مخصص opens
                            // the filter sheet where the date pickers live.
                            InspectionPeriodButton(
                              dateFrom: state.dateFrom,
                              dateTo: state.dateTo,
                              onPreset: (from, to) =>
                                  cubit.setDateRange(from, to),
                              onCustom: () => _openFilterSheet(context),
                            ),
                            Badge(
                              isLabelVisible: activeFilterCount > 0,
                              label: Text('$activeFilterCount'),
                              child: IconButton.filledTonal(
                                tooltip: AppText.t('الفلاتر', 'Filters'),
                                onPressed: () => _openFilterSheet(context),
                                icon: Icon(
                                  Icons.filter_alt_outlined,
                                  size: 20.r,
                                ),
                              ),
                            ),
                            if (!kIsWeb &&
                                defaultTargetPlatform ==
                                    TargetPlatform.android) ...[
                              const SizedBox(width: AppSpacing.xs),
                              IconButton.outlined(
                                tooltip: AppText.t('مسح رمز', 'Scan QR'),
                                onPressed: () => Navigator.of(context).push(
                                  AppPageRoute(
                                    builder: (_) => const QrScanScreen(),
                                  ),
                                ),
                                icon: Icon(
                                  Icons.qr_code_scanner_outlined,
                                  size: 20.r,
                                ),
                              ),
                            ],
                            const SizedBox(width: AppSpacing.xs),
                            PopupMenuButton<String>(
                              tooltip: AppText.t('المزيد', 'More'),
                              icon: const Icon(Icons.more_vert),
                              onSelected: (v) {
                                switch (v) {
                                  case 'followUp':
                                    if (!state.exporting) {
                                      _exportFollowUp(context);
                                    }
                                  case 'selectAll':
                                    cubit.setPageSelection(
                                      pageIds,
                                      !allPageSelected,
                                    );
                                }
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'followUp',
                                  enabled: !state.exporting,
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.description_outlined,
                                        size: 18.r,
                                      ),
                                      const SizedBox(width: AppSpacing.sm),
                                      Text(
                                        AppText.t('تقرير متابعة', 'Follow-up'),
                                      ),
                                    ],
                                  ),
                                ),
                                if (state.visible.isNotEmpty)
                                  PopupMenuItem(
                                    value: 'selectAll',
                                    child: Row(
                                      children: [
                                        Icon(
                                          allPageSelected
                                              ? Icons.deselect_outlined
                                              : Icons.select_all_outlined,
                                          size: 18.r,
                                        ),
                                        const SizedBox(width: AppSpacing.sm),
                                        Text(
                                          allPageSelected
                                              ? AppText.t(
                                                  'إلغاء التحديد',
                                                  'Clear selection',
                                                )
                                              : AppText.t(
                                                  'تحديد الكل',
                                                  'Select all',
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        InspectionFilterChips(
                          chips: inspectionFilterChips(
                            state,
                            isProduct: isProduct,
                          ),
                          onClearChip: (key) => cubit.clearChip(key),
                          onClearAll: () => cubit.clearFilters(),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        if (state.loading && state.visible.isNotEmpty)
                          const AppRefreshBar(),
                        if (state.loading && state.visible.isEmpty) ...[
                          const AppSkeletonList(rows: 6, lines: 2, height: 120),
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
                        ] else if (selectedCount > 0) ...[
                          SelectionActionBar(
                            selectedCount: selectedCount,
                            onExportReports: () =>
                                exportSelectedReports(context),
                            onExportLabels: () => exportSelectedLabels(context),
                            onExportTable: () => exportSelectedTable(context),
                            onClear: cubit.clearSelection,
                          ),
                          const SizedBox(height: AppSpacing.md),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (!(state.loading && state.visible.isEmpty) &&
                  state.visible.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.pageMobile,
                  ),
                  sliver: SliverList.builder(
                    itemCount: state.visible.length,
                    itemBuilder: (context, index) {
                      final r = state.visible[index];
                      final id = (r['id'] as num).toInt();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                        child: _InspectionCard(
                          key: ValueKey('insp_$id'),
                          entry: '${r['entry_code']}',
                          date:
                              parseIsoToDisplay('${r['inspection_date']}') ??
                              '',
                          material: '${r['material_name']}',
                          supplier: isProduct
                              ? '${r['formula_number'] ?? ''} • ${r['batch_number'] ?? ''}'
                              : '${r['supplier']}',
                          qty: '${r['quantity']}',
                          // Products carry no header decision (per-sample only).
                          decision: isProduct ? '' : '${r['decision_status']}',
                          selected: state.selectedIds.contains(id),
                          onSelectChanged: (_) => cubit.toggleSelect(id),
                          onTap: () => _pushDetail(context, id),
                          onPdf: () => _exportOne(context, r, 'report'),
                          onLabel: () => _exportOne(context, r, 'label'),
                        ),
                      );
                    },
                  ),
                ),
              if (!(state.loading && state.visible.isEmpty) &&
                  state.visible.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.pageMobile,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      children: [
                        const SizedBox(height: AppSpacing.md),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          alignment: WrapAlignment.spaceBetween,
                          spacing: AppSpacing.sm,
                          runSpacing: 4,
                          children: [
                            AppPageSizeSelector(
                              value: state.pageSize > kMobileMaxPageSize
                                  ? kMobileMaxPageSize
                                  : state.pageSize,
                              options: kMobilePageSizeOptions,
                              onChanged: (v) => cubit.setPageSize(v),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AppButton(
                                  small: true,
                                  style: AppButtonStyle.ghost,
                                  label: AppText.t('السابق', 'Previous'),
                                  onPressed: state.page > 0
                                      ? () => cubit.setPage(state.page - 1)
                                      : null,
                                ),
                                Text(
                                  '${AppText.t('صفحة', 'Page')} ${state.page + 1}'
                                  ' · ${state.total}',
                                  style: TextStyle(
                                    fontSize: 12.spMax,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                                AppButton(
                                  small: true,
                                  style: AppButtonStyle.ghost,
                                  label: AppText.t('التالي', 'Next'),
                                  onPressed:
                                      (state.page + 1) * state.pageSize <
                                          state.total
                                      ? () => cubit.setPage(state.page + 1)
                                      : null,
                                ),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                ),
              if (state.visible.isEmpty)
                const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mobile inspection card (phones only — desktop keeps its table row).
///
/// Layout priority: the **material name is the hero** — full text up to three
/// lines, never single-line-ellipsized. The decision is a circular dot + short
/// label (not the desktop pill), and both the name and the status sit inside a
/// [Tooltip]: on phones a long-press shows the complete text, which is the
/// touch equivalent of the desktop hover tooltip.
class _InspectionCard extends StatelessWidget {
  const _InspectionCard({
    super.key,
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
    final statusColor = statusColorsPut(decision);
    final statusText = statusLabel(decision);
    return AppCard(
      onTap: onTap,
      // Touch-only device: skip the hover tracking machinery per row.
      enableHover: false,
      // Flat shadow tier: a page of stacked cards reads lighter.
      flat: true,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Circular decision indicator: colored ring + dot. Long-press
              // reveals the full status text (desktop hover equivalent).
              // Raw-only: products carry no header decision.
              if (decision.isNotEmpty) ...[
                Tooltip(
                  message: statusText,
                  child: Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.xxs),
                    child: Container(
                      width: 14.r,
                      height: 14.r,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: statusColor.withValues(alpha: 0.15),
                        border: Border.all(color: statusColor, width: 2),
                      ),
                      child: Center(
                        child: Container(
                          width: 5.r,
                          height: 5.r,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              // Hero: full material name, up to 3 lines. Long-press shows it
              // all when even three lines are not enough.
              Expanded(
                child: Tooltip(
                  message: material,
                  child: Text(
                    material,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.spMax,
                      fontWeight: FontWeight.w800,
                      height: 1.35,
                      color: AppColors.textStrong,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 40.w,
                height: 40.h,
                child: Checkbox(
                  value: selected,
                  visualDensity: VisualDensity.compact,
                  onChanged: onSelectChanged,
                ),
              ),
            ],
          ),
          // Decision short label under the name, in its color.
          // Raw-only: products carry no header decision.
          if (decision.isNotEmpty) ...[
            const SizedBox(height: 2),
            Padding(
              padding: EdgeInsetsDirectional.only(start: 22.w),
              child: Text(
                statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.spMax,
                  fontWeight: FontWeight.w700,
                  color: statusColor,
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
          // Entry + date meta line.
          Row(
            children: [
              Icon(Icons.tag_outlined, size: 13.r, color: AppColors.textMuted),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '$entry • $date',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.spMax,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Supplier + quantity line, two lines max so long supplier names
          // wrap instead of pushing the actions off-screen.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xxs),
                child: Icon(
                  Icons.local_shipping_outlined,
                  size: 13.r,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '$supplier • $qty',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.spMax,
                    height: 1.4,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: AppText.t('تصدير PDF', 'PDF'),
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                visualDensity: VisualDensity.compact,
                onPressed: onPdf,
                icon: Icon(Icons.picture_as_pdf_outlined, size: 20.r),
              ),
              IconButton(
                tooltip: AppText.t('QR', 'QR'),
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                visualDensity: VisualDensity.compact,
                onPressed: onLabel,
                icon: Icon(Icons.label_outline, size: 20.r),
              ),
              IconButton(
                tooltip: AppText.t('التفاصيل', 'Details'),
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                visualDensity: VisualDensity.compact,
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
