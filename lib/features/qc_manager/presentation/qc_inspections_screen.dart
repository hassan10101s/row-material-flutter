import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/feedback/app_feedback.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_card.dart';
import '../../../../design_system/widgets/app_dropdown.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_field.dart';
import '../../../../design_system/widgets/app_summary_card.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../../../../design_system/widgets/app_window.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_inspection.dart';
import 'cubit/qc_inspections_cubit.dart';
import 'widgets/qc_pill.dart';
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
            return const Center(child: CircularProgressIndicator());
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
                action: FilledButton.tonal(
                  onPressed: () => cubit.refresh(),
                  child: Text(AppText.t('إعادة المحاولة', 'Retry')),
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
                        ? FilledButton.icon(
                            onPressed: () =>
                                QcInspectionStartScreen.open(context),
                            icon: const Icon(Icons.add),
                            label: Text(
                              AppText.t('فحص جديد', 'New inspection'),
                            ),
                          )
                        : null)
                  : FilledButton.tonal(
                      onPressed: () => cubit.clearFilters(),
                      child: Text(AppText.t('مسح الفلاتر', 'Clear filters')),
                    ),
            );
          }
          return Column(
            children: [
              _SummaryStrip(summary: state.summary),
              _ActiveFilterBar(
                state: state,
                onEdit: () => _openFilters(context),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => cubit.refresh(),
                  child: ListView.separated(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    itemCount: state.inspections.length + 1,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (context, i) {
                      if (i == state.inspections.length) {
                        return _LoadMoreRow(
                          hasMore: state.hasMore,
                          busy: state.loadingMore,
                          onLoadMore: () => cubit.loadMore(),
                        );
                      }
                      return _InspectionTile(inspection: state.inspections[i]);
                    },
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        0,
      ),
      child: Row(
        children: [
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('الإجمالي', 'Total'),
              value: '${summary.total}',
              icon: Icons.fact_check_outlined,
              color: AppColors.primary,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('جارية', 'Open'),
              value: '${summary.inProgress}',
              icon: Icons.play_circle_outline,
              color: AppColors.info,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('بانتظار المراجعة', 'To review'),
              value: '${summary.awaitingReview}',
              icon: Icons.hourglass_top,
              color: AppColors.warning,
            ),
          ),
          Expanded(
            child: AppSummaryCard(
              label: AppText.t('بها عدم مطابقة', 'With NC'),
              value: '${summary.withNc}',
              icon: Icons.report_gmailerrorred,
              color: AppColors.danger,
            ),
          ),
        ],
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
          TextButton(
            onPressed: onEdit,
            child: Text(AppText.t('تعديل', 'Edit')),
          ),
        ],
      ),
    );
  }
}

class _InspectionTile extends StatelessWidget {
  const _InspectionTile({required this.inspection});

  final QcInspection inspection;

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

/// A page's worth came back, so ask for the next one; or the end, so stop.
class _LoadMoreRow extends StatelessWidget {
  const _LoadMoreRow({
    required this.hasMore,
    required this.busy,
    required this.onLoadMore,
  });

  final bool hasMore;
  final bool busy;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    if (!hasMore && !busy) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: Text(
            AppText.t('نهاية القائمة', 'End of list'),
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(
                onPressed: onLoadMore,
                child: Text(AppText.t('المزيد', 'Load more')),
              ),
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
              children: [
                for (final status in QcInspectionStatus.all)
                  FilterChip(
                    label: Text(QcPill.inspectionStatusLabel(status)),
                    selected: _draft.statuses.contains(status),
                    onSelected: (_) {
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
                AppDropdownItem(
                  value: '',
                  label: AppText.t('الكل', 'All'),
                ),
                for (final type in QcRefType.all)
                  AppDropdownItem(
                    value: type,
                    label: QcPill.refTypeLabel(type),
                  ),
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
            AppField(
              label: AppText.t('القسم', 'Department'),
              controller: _dept,
            ),
            const SizedBox(height: AppSpacing.lg),
            AppWindow.footer(
              actions: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      _lot.clear();
                      _dept.clear();
                      cubit.clearFilters();
                      Navigator.of(context).pop();
                    },
                    child: Text(AppText.t('مسح', 'Clear')),
                  ),
                ),
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      cubit.applyFilters(
                        _draft.copyWith(
                          lotNo: _lot.text.trim(),
                          dept: _dept.text.trim(),
                        ),
                      );
                      Navigator.of(context).pop();
                    },
                    child: Text(AppText.t('تطبيق', 'Apply')),
                  ),
                ),
              ],
            ),
          ],
        );
  }
}
