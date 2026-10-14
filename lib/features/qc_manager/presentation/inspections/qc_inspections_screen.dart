import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/feedback/app_feedback.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../app/auth_gate.dart';
import '../../../../../core/auth/permissions.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_delete_confirm.dart';
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_empty_state.dart';
import '../../../../../design_system/widgets/app_field.dart';
import '../../../../../design_system/widgets/app_infinite_list.dart';
import '../../../../../design_system/widgets/app_page_header.dart';
import '../../../../../design_system/widgets/app_skeleton.dart';
import '../../../../../design_system/widgets/app_summary_card.dart';
import '../../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../../../di/service_locator.dart';
import '../widgets/register_exports.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_inspection.dart';
import '../cubit/qc_inspections_cubit.dart';
import '../widgets/qc_pill.dart';
import 'qc_inspection_sheet_screen.dart';
import 'qc_inspection_start_screen.dart';

/// The QC inspection register: every checklist execution, filterable and paged.
///
/// Read-mostly by design. Starting a sheet is the one write here, and it is a
/// separate screen so this list stays a list - a row tap opens the sheet's
/// execution view rather than starting a new one.
class QcInspectionsScreen extends StatelessWidget {
  const QcInspectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcInspectionsCubit>();
    return Scaffold(
      appBar: AppTopAppBar(
        title: AppText.t('فحوصات الجودة', 'Quality inspections'),
        actions: [
          IconButton(
            tooltip: AppText.t('تصدير جدول', 'Export table'),
            onPressed: () =>
                RegisterExports.inspections(context, cubit.state.inspections),
            icon: const Icon(Icons.table_view_outlined),
          ),
          IconButton(
            tooltip: AppText.t('تحديث', 'Refresh'),
            onPressed: () => cubit.refresh(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: AppText.t('فلاتر', 'Filters'),
            onPressed: () => _openFilters(context),
            icon: const Icon(Icons.tune),
          ),
          // Hidden rather than disabled: a read-only session has nothing to do
          // here, and a permanently greyed-out button only teaches people that
          // the screen is broken.
          if (QcInspectionStartScreen.canStart)
            IconButton(
              tooltip: AppText.t('فحص جديد', 'New inspection'),
              onPressed: () => QcInspectionStartScreen.open(context),
              icon: const Icon(Icons.add),
            ),
        ],
      ),
      body: BlocConsumer<QcInspectionsCubit, QcInspectionsState>(
        listenWhen: (a, b) => a.error != b.error && b.error != null,
        listener: (context, state) {
          final error = state.error;
          if (error == null) return;
          // Kept in the state so the empty-state branch can show it too; the
          // top banner is for a failure on top of an already-populated list.
          if (state.inspections.isNotEmpty) {
            AppFeedback.error(context, error);
            cubit.clearError();
          }
        },
        builder: (context, state) {
          if (state.loading && state.inspections.isEmpty) {
            return const AppSkeletonList(rows: 5);
          }
          if (state.inspections.isEmpty) {
            // A failed load is not an empty register. The snackbar the listener
            // shows is transient, so without this the screen would sit there
            // saying "no inspections yet" - which reads as success - right after
            // refusing to read them.
            if (state.error != null) {
              return AppEmptyState(
                icon: Icons.error_outline,
                title: AppText.t(
                  'تعذّر تحميل الفحوصات',
                  'Could not load inspections',
                ),
                subtitle: state.error,
                action: AppButton(
                  label: AppText.t('إعادة المحاولة', 'Retry'),
                  style: AppButtonStyle.secondary,
                  onPressed: () => cubit.refresh(),
                ),
              );
            }
            return AppEmptyState(
              icon: Icons.fact_check_outlined,
              title: AppText.t('لا توجد فحوصات', 'No inspections yet'),
              subtitle: state.filters.isEmpty
                  ? AppText.t(
                      'ابدأ أول فحص بقائمة فحص منشورة',
                      'Start the first inspection from a published checklist',
                    )
                  : AppText.t(
                      'لا توجد فحوصات تطابق هذه الفلاتر',
                      'No inspections match these filters',
                    ),
              action: state.filters.isEmpty
                  ? (QcInspectionStartScreen.canStart
                        ? AppButton(
                            label: AppText.t('فحص جديد', 'New inspection'),
                            icon: const Icon(Icons.add),
                            onPressed: () =>
                                QcInspectionStartScreen.open(context),
                          )
                        : null)
                  : AppButton(
                      label: AppText.t('مسح الفلاتر', 'Clear filters'),
                      style: AppButtonStyle.secondary,
                      onPressed: () => cubit.clearFilters(),
                    ),
            );
          }
          return Column(
            children: [
              if (state.loading && state.inspections.isNotEmpty)
                const AppRefreshBar(),
              _SummaryStrip(summary: state.summary),
              _ActiveFilterBar(
                state: state,
                onEdit: () => _openFilters(context),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md,
                  AppSpacing.sm,
                  AppSpacing.md,
                  0,
                ),
                child: AppFilterBar(
                  searchHint: AppText.t('بحث برقم اللوط', 'Search lot number'),
                  initialSearch: state.filters.lotNo,
                  onSearch: (v) => cubit.applyFilters(
                    state.filters.copyWith(lotNo: v.trim()),
                  ),
                  trailing: AppButton(
                    label: AppText.t('فلاتر', 'Filters'),
                    icon: const Icon(Icons.tune, size: 18),
                    style: AppButtonStyle.ghost,
                    small: true,
                    onPressed: () => _openFilters(context),
                  ),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => cubit.refresh(),
                  child: AppInfiniteList(
                    itemCount: state.inspections.length,
                    hasMore: state.hasMore,
                    loadingMore: state.loadingMore,
                    onLoadMore: () => cubit.loadMore(),
                    itemBuilder: (context, i) =>
                        _InspectionTile(inspection: state.inspections[i]),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openFilters(BuildContext context) {
    final cubit = context.read<QcInspectionsCubit>();
    showAppOverlay<void>(
      context,
      title: AppText.t('فلاتر الفحوصات', 'Inspection filters'),
      icon: Icons.filter_alt_outlined,
      size: AppWindowSize.sm,
      builder: (_, _) => BlocProvider.value(
        value: cubit,
        child: const _InspectionFilterSheet(),
      ),
    );
  }
}

/// Total / in progress / awaiting review / carrying an open NC.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.summary});

  final QcInspectionSummary summary;

  @override
  Widget build(BuildContext context) {
    final cards = [
      AppSummaryCard(
        label: AppText.t('الإجمالي', 'Total'),
        value: '${summary.total}',
        icon: Icons.fact_check_outlined,
        color: AppColors.primary,
      ),
      AppSummaryCard(
        label: AppText.t('جارية', 'Open'),
        value: '${summary.inProgress}',
        icon: Icons.play_circle_outline,
        color: AppColors.info,
      ),
      AppSummaryCard(
        label: AppText.t('بانتظار المراجعة', 'To review'),
        value: '${summary.awaitingReview}',
        icon: Icons.hourglass_top,
        color: AppColors.warning,
      ),
      AppSummaryCard(
        label: AppText.t('بها عدم مطابقة', 'With NC'),
        value: '${summary.withNc}',
        icon: Icons.report_gmailerrorred,
        color: AppColors.danger,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth < 600 ? 2 : 4;
          final gap = AppSpacing.sm;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final card in cards) SizedBox(width: width, child: card),
            ],
          );
        },
      ),
    );
  }
}

/// The chips describing what the rows below are filtered by.
class _ActiveFilterBar extends StatelessWidget {
  const _ActiveFilterBar({required this.state, required this.onEdit});

  final QcInspectionsState state;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final filters = state.filters;
    if (filters.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AppText.t(
                '${filters.activeCount} مرشّح نشط',
                '${filters.activeCount} active filter(s)',
              ),
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            ),
          ),
          AppButton(
            label: AppText.t('تعديل', 'Edit'),
            style: AppButtonStyle.ghost,
            small: true,
            onPressed: onEdit,
          ),
        ],
      ),
    );
  }
}

class _InspectionTile extends StatelessWidget {
  const _InspectionTile({required this.inspection});

  final QcInspection inspection;

  static bool get canDelete {
    try {
      return getIt<AuthGate>().canWrite(Permission.qcWrite);
    } catch (_) {
      return true;
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await AppDeleteConfirmDialog.show(
      context,
      title: AppText.t('حذف الفحص', 'Delete inspection'),
      name: inspection.refLabel,
    );
    if (!confirmed || !context.mounted) return;
    final cubit = context.read<QcInspectionsCubit>();
    await cubit.deleteInspection(inspection.inspectionId ?? 0);
    if (!context.mounted) return;
    final error = cubit.state.error;
    if (error != null && error.isNotEmpty) {
      AppFeedback.error(context, error);
      cubit.clearError();
    } else {
      AppFeedback.success(
        context,
        AppText.t('تم حذف الفحص', 'Inspection deleted'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final score = inspection.scorePct;
    final id = inspection.inspectionId;
    return AppCard(
      onTap: id == null
          ? null
          : () => QcInspectionSheetScreen.open(context, inspectionId: id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  inspection.refLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15.spMax,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              QcPill.inspectionResult(inspection.resultOverall),
              if (canDelete && id != null) ...[
                const SizedBox(width: AppSpacing.xs),
                PopupMenuButton<String>(
                  tooltip: AppText.t('خيارات', 'Options'),
                  iconSize: 20,
                  onSelected: (v) {
                    if (v == 'delete') _confirmDelete(context);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: AppColors.danger,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(AppText.t('حذف', 'Delete')),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              QcPill.inspectionStatus(inspection.status),
              if (inspection.dept.isNotEmpty)
                QcPill(inspection.dept, AppColors.textMuted),
              if (score != null)
                QcPill(
                  '${score.toStringAsFixed(0)}%',
                  score >= 95
                      ? AppColors.success
                      : (score >= 80 ? AppColors.warning : AppColors.danger),
                ),
              if (inspection.hasOpenNc)
                QcPill(
                  AppText.t(
                    '${inspection.ncCount} عدم مطابقة',
                    '${inspection.ncCount} NC',
                  ),
                  AppColors.danger,
                ),
            ],
          ),
          if (inspection.remarks.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              inspection.remarks,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            ),
          ],
        ],
      ),
    );
  }
}

/// Status / refType / lot / dept narrowing for the register.
class _InspectionFilterSheet extends StatefulWidget {
  const _InspectionFilterSheet();

  @override
  State<_InspectionFilterSheet> createState() => _InspectionFilterSheetState();
}

class _InspectionFilterSheetState extends State<_InspectionFilterSheet> {
  late QcInspectionFilters _draft;
  late TextEditingController _lot;
  late TextEditingController _dept;

  @override
  void initState() {
    super.initState();
    _draft = context.read<QcInspectionsCubit>().state.filters;
    _lot = TextEditingController(text: _draft.lotNo);
    _dept = TextEditingController(text: _draft.dept);
  }

  @override
  void dispose() {
    _lot.dispose();
    _dept.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcInspectionsCubit>();
    // Chrome (title, padding, scroll) comes from the overlay host.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          AppText.t('الحالة', 'Status'),
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
        const SizedBox(height: AppSpacing.xs),
        Wrap(
          spacing: AppSpacing.xs,
          runSpacing: AppSpacing.xs,
          children: [
            for (final status in QcInspectionStatus.all)
              AppButton(
                small: true,
                style: _draft.statuses.contains(status)
                    ? AppButtonStyle.primary
                    : AppButtonStyle.secondary,
                label: QcPill.inspectionStatusLabel(status),
                onPressed: () {
                  final next = {..._draft.statuses};
                  if (!next.remove(status)) next.add(status);
                  setState(() => _draft = _draft.copyWith(statuses: next));
                },
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          AppText.t('نوع المرجع', 'Reference type'),
          style: TextStyle(color: AppColors.textMuted, fontSize: 13.spMax),
        ),
        const SizedBox(height: AppSpacing.xs),
        AppDropdown<String>(
          value: _draft.refType,
          items: [
            AppDropdownItem(value: '', label: AppText.t('الكل', 'All')),
            for (final type in QcRefType.all)
              AppDropdownItem(value: type, label: QcPill.refTypeLabel(type)),
          ],
          onChanged: (v) =>
              setState(() => _draft = _draft.copyWith(refType: v ?? '')),
        ),
        const SizedBox(height: AppSpacing.md),
        AppField(
          label: AppText.t('رقم التشغيلة / اللوط', 'Lot / batch number'),
          controller: _lot,
        ),
        const SizedBox(height: AppSpacing.md),
        AppField(label: AppText.t('القسم', 'Department'), controller: _dept),
        const SizedBox(height: AppSpacing.lg),
        AppWindow.footer(
          actions: [
            Expanded(
              child: AppButton(
                label: AppText.t('مسح', 'Clear'),
                style: AppButtonStyle.secondary,
                expanded: true,
                onPressed: () {
                  _lot.clear();
                  _dept.clear();
                  cubit.clearFilters();
                  Navigator.of(context).pop();
                },
              ),
            ),
            Expanded(
              child: AppButton(
                label: AppText.t('تطبيق', 'Apply'),
                expanded: true,
                onPressed: () {
                  cubit.applyFilters(
                    _draft.copyWith(
                      lotNo: _lot.text.trim(),
                      dept: _dept.text.trim(),
                    ),
                  );
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
