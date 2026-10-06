import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';
import '../../../../design_system/tokens/app_spacing.dart';
import '../../../../design_system/widgets/app_button.dart';
import '../../../../design_system/widgets/app_empty_state.dart';
import '../../../../design_system/widgets/app_paginated_table.dart';
import '../../../../design_system/widgets/app_top_app_bar.dart';
import '../domain/ncr_filters.dart';
import '../domain/ncr_report_row.dart';
import 'cubit/qc_ncr_cubit.dart';
import 'widgets/ncr_pill.dart';

/// The NCR table with its filter drawer (plan V6_ENHANCED §22.6).
class QcNcrListScreen extends StatelessWidget {
  const QcNcrListScreen({super.key, this.cubit, this.onOpenFinding});

  /// Optional so the same widget works under a `BlocProvider` (the router,
  /// which then owns and closes the cubit) and standalone (tests, previews).
  final QcNcrCubit? cubit;

  /// Called with the tapped finding's id. Optional so the table can be used in
  /// tests and embedded previews without a router.
  final void Function(int findingId)? onOpenFinding;

  @override
  Widget build(BuildContext context) {
    final cubit = this.cubit ?? context.read<QcNcrCubit>();
    return BlocBuilder<QcNcrCubit, QcNcrState>(
      bloc: cubit,
      builder: (context, state) {
        return Scaffold(
          appBar: AppTopAppBar(
            title: AppText.t('حالات عدم المطابقة', 'Non-conformances'),
            actions: [
              IconButton(
                tooltip: AppText.t('تصفية', 'Filters'),
                onPressed: () => _openFilters(context, state, cubit),
                icon: Badge(
                  isLabelVisible: state.hasFilters,
                  child: const Icon(Icons.filter_list),
                ),
              ),
              IconButton(
                tooltip: AppText.t('تحديث', 'Refresh'),
                onPressed: state.loading ? null : cubit.load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: Column(
            children: [
              if (state.hasFilters) _ActiveFilterChips(state: state),
              Expanded(
                child: state.error != null && state.rows.isEmpty
                    ? AppEmptyState(
                        icon: Icons.error_outline,
                        title: AppText.t(
                          'تعذر تحميل التقرير',
                          'Report unavailable',
                        ),
                        subtitle: state.error,
                        action: AppButton(
                          label: AppText.t('إعادة المحاولة', 'Retry'),
                          icon: const Icon(Icons.refresh),
                          onPressed: cubit.load,
                        ),
                      )
                    : AppPaginatedTable(
                        headers: _headers(),
                        rows: _rows(state.rows),
                        onRowTap: onOpenFinding == null
                            ? null
                            : (index) =>
                                  onOpenFinding!(state.rows[index].findingId),
                        rowsPerPage: cubit.pageSize,
                        loading: state.loading,
                        totalLabel: state.total == 0
                            ? AppText.t('لا نتائج', 'No results')
                            : '${state.total}',
                        empty: AppEmptyState(
                          icon: Icons.inbox_outlined,
                          title: AppText.t(
                            'لا توجد حالات مطابقة',
                            'No non-conformances match',
                          ),
                          subtitle: state.hasFilters
                              ? AppText.t(
                                  'وسّع نطاق التاريخ أو أزل بعض عوامل التصفية',
                                  'Widen the date range or drop a filter',
                                )
                              : null,
                        ),
                        headerTrailing: state.loading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : null,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  static List<String> _headers() => [
    AppText.t('المرجع', 'Ref'),
    AppText.t('الوصف', 'Description'),
    AppText.t('الخطورة', 'Severity'),
    AppText.t('الحالة', 'Status'),
    AppText.t('التفتيش', 'Inspection'),
    AppText.t('المخزون', 'Lot / batch'),
    AppText.t('المسند', 'Assignee'),
    AppText.t('الاستحقاق', 'Due'),
    AppText.t('الإجراء التصحيحي', 'CAPA'),
  ];

  /// Cells are widgets, not strings, so severity and status can be rendered as
  /// the same pills the detail screen uses. A table of plain text is where a
  /// critical finding becomes indistinguishable from a minor one.
  static List<List<Widget>> _rows(List<NcrReportRow> rows) => [
    for (final r in rows)
      <Widget>[
        Text(r.reference),
        Text(r.description, maxLines: 2, overflow: TextOverflow.ellipsis),
        ncrSeverityPill(r.severity),
        ncrStatePill(r.status),
        Text(
          r.inspectionRefId.isEmpty
              ? (r.inspectorName.isEmpty ? '—' : r.inspectorName)
              : r.inspectionRefId,
        ),
        Text(
          r.lotNo.isNotEmpty
              ? r.lotNo
              : r.batchNo.isNotEmpty
              ? r.batchNo
              : '—',
        ),
        Text(r.assignedToName.isEmpty ? '—' : r.assignedToName),
        // The overdue date is the one cell that gets coloured: a date is
        // scannable, but a date that has already passed is not.
        Text(
          r.dueDate.isEmpty ? '—' : r.dueDate,
          style: r.isOverdue
              ? TextStyle(color: AppColors.danger, fontWeight: FontWeight.bold)
              : null,
        ),
        if (r.capaStatus.isEmpty)
          const Text('-')
        else
          ncrCapaPill(r.capaStatus),
      ],
  ];

  void _openFilters(BuildContext context, QcNcrState state, QcNcrCubit cubit) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      // The sheet is a new route, so the page's provider is not an ancestor of
      // it. Re-provide the same instance rather than a copy: the sheet writes
      // filters through it and the page must see the result.
      builder: (sheetContext) => BlocProvider.value(
        value: cubit,
        child: _FilterSheet(state: state),
      ),
    );
  }
}

/// One removable chip per active filter, so the scope is visible on the table
/// itself and not only inside a sheet the reader has to reopen.
class _ActiveFilterChips extends StatelessWidget {
  const _ActiveFilterChips({required this.state});

  final QcNcrState state;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcNcrCubit>();
    final f = state.filters;
    final chips = <Widget>[
      if (f.hasDateRange)
        _Chip(
          label:
              '${f.from.isEmpty ? '…' : f.from} .. ${f.to.isEmpty ? '…' : f.to}',
          onRemove: () => cubit.setDateRange('', ''),
        ),
      if (f.onlyOverdue)
        _Chip(
          label: AppText.t('متأخرة فقط', 'Overdue only'),
          onRemove: cubit.toggleOnlyOverdue,
        ),
      for (final value in f.statuses)
        _Chip(
          label: value,
          onRemove: () => cubit.toggleFilter('status', value),
        ),
      for (final value in f.severities)
        _Chip(
          label: value,
          onRemove: () => cubit.toggleFilter('severity', value),
        ),
      for (final value in f.types)
        _Chip(label: value, onRemove: () => cubit.toggleFilter('type', value)),
      for (final value in f.categories)
        _Chip(
          label: value,
          onRemove: () => cubit.toggleFilter('category', value),
        ),
      for (final value in f.depts)
        _Chip(label: value, onRemove: () => cubit.toggleFilter('dept', value)),
      if (f.lotNo.isNotEmpty)
        _Chip(
          label: '${AppText.t('مخزون', 'Lot')}: ${f.lotNo}',
          onRemove: () => cubit.applyFilters(f.copyWith(lotNo: '')),
        ),
    ];

    return Container(
      width: double.infinity,
      color: AppColors.surfaceSoft,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          ...chips,
          TextButton(
            onPressed: cubit.clearFilters,
            child: Text(AppText.t('مسح الكل', 'Clear all')),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return InputChip(
      label: Text(label),
      onDeleted: onRemove,
      deleteIcon: const Icon(Icons.close, size: 16),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// The filter drawer (plan §22.4).
class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.state});

  final QcNcrState state;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late final TextEditingController _lot;
  late final TextEditingController _batch;
  late final TextEditingController _po;
  late String _dateField;

  @override
  void initState() {
    super.initState();
    final f = widget.state.filters;
    _lot = TextEditingController(text: f.lotNo);
    _batch = TextEditingController(text: f.batchNo);
    _po = TextEditingController(text: f.poNo);
    _dateField = f.dateField;
  }

  @override
  void dispose() {
    _lot.dispose();
    _batch.dispose();
    _po.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<QcNcrCubit>();
    final options = widget.state.options;
    final f = widget.state.filters;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        children: [
          Text(
            AppText.t('تصفية النتائج', 'Filter results'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.md),
          _MultiSelect(
            title: AppText.t('الحالة', 'Status'),
            values: options.statuses,
            selected: f.statuses,
            onToggle: (v) => cubit.toggleFilter('status', v),
          ),
          _MultiSelect(
            title: AppText.t('الخطورة', 'Severity'),
            values: options.severities,
            selected: f.severities,
            onToggle: (v) => cubit.toggleFilter('severity', v),
            render: severityLabel,
          ),
          _MultiSelect(
            title: AppText.t('النوع', 'Type'),
            values: options.types,
            selected: f.types,
            onToggle: (v) => cubit.toggleFilter('type', v),
          ),
          _MultiSelect(
            title: AppText.t('التصنيف', 'Category'),
            values: options.categories,
            selected: f.categories,
            onToggle: (v) => cubit.toggleFilter('category', v),
          ),
          _MultiSelect(
            title: AppText.t('القسم', 'Department'),
            values: options.depts,
            selected: f.depts,
            onToggle: (v) => cubit.toggleFilter('dept', v),
          ),
          _MultiSelect(
            title: AppText.t('حالة الإجراء التصحيحي', 'CAPA status'),
            values: options.capaStatuses,
            selected: f.capaStatuses,
            onToggle: (v) => cubit.toggleFilter('capaStatus', v),
          ),
          _MultiSelect(
            title: AppText.t(' المفتش', 'Inspector'),
            values: options.inspectors.map((p) => p.id).toList(),
            labels: {for (final p in options.inspectors) p.id: p.name},
            selected: f.inspectorIds,
            onToggle: (v) => cubit.toggleFilter('inspector', v),
          ),
          _MultiSelect(
            title: AppText.t('المسند إليه', 'Assignee'),
            values: options.assignees.map((p) => p.id).toList(),
            labels: {for (final p in options.assignees) p.id: p.name},
            selected: f.assignedTo,
            onToggle: (v) => cubit.toggleFilter('assignedTo', v),
          ),
          const SizedBox(height: AppSpacing.md),
          _TextFilter(
            label: AppText.t('رقم المخزون', 'Lot number'),
            controller: _lot,
            onApply: (v) => cubit.applyFilters(f.copyWith(lotNo: v)),
          ),
          _TextFilter(
            label: AppText.t('رقم التشغيلة', 'Batch number'),
            controller: _batch,
            onApply: (v) => cubit.applyFilters(f.copyWith(batchNo: v)),
          ),
          _TextFilter(
            label: AppText.t('أمر الشراء', 'PO number'),
            controller: _po,
            onApply: (v) => cubit.applyFilters(f.copyWith(poNo: v)),
          ),
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<String>(
            initialValue: _dateField,
            decoration: InputDecoration(
              labelText: AppText.t('طبّق النطاق على', 'Date range applies to'),
            ),
            items: [
              DropdownMenuItem(
                value: NcrFilters.dateFieldCreated,
                child: Text(AppText.t('تاريخ الفتح', 'Date raised')),
              ),
              DropdownMenuItem(
                value: NcrFilters.dateFieldInspection,
                child: Text(AppText.t('تاريخ التفتيش', 'Inspection date')),
              ),
              DropdownMenuItem(
                value: NcrFilters.dateFieldClosed,
                child: Text(AppText.t('تاريخ الإغلاق', 'Closure date')),
              ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _dateField = v);
            },
          ),
          const SizedBox(height: AppSpacing.md),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: f.onlyOverdue,
            title: Text(AppText.t('المتأخرة فقط', 'Overdue only')),
            subtitle: Text(
              AppText.t(
                'الحالات المفتوحة التي تجاوزت تاريخ الاستحقاق',
                'Open findings past their due date',
              ),
            ),
            onChanged: (_) => cubit.toggleOnlyOverdue(),
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: AppText.t('مسح الكل', 'Clear all'),
                  icon: const Icon(Icons.clear),
                  style: AppButtonStyle.secondary,
                  onPressed: () {
                    cubit.clearFilters();
                    Navigator.of(context).pop();
                  },
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: AppText.t('عرض النتائج', 'Show results'),
                  icon: const Icon(Icons.check),
                  expanded: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MultiSelect extends StatelessWidget {
  const _MultiSelect({
    required this.title,
    required this.values,
    required this.selected,
    required this.onToggle,
    this.labels = const {},
    this.render,
  });

  final String title;
  final List<String> values;
  final Set<String> selected;
  final void Function(String value) onToggle;

  /// Friendly text for values whose filter key is an id.
  final Map<String, String> labels;

  /// Rewrites a stored value for display (severity codes, for example).
  final String Function(String value)? render;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: AppSpacing.xs),
          Wrap(
            spacing: AppSpacing.xs,
            children: [
              for (final value in values)
                FilterChip(
                  label: Text(labels[value] ?? render?.call(value) ?? value),
                  selected: selected.contains(value),
                  onSelected: (_) => onToggle(value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TextFilter extends StatelessWidget {
  const _TextFilter({
    required this.label,
    required this.controller,
    required this.onApply,
  });

  final String label;
  final TextEditingController controller;
  final void Function(String value) onApply;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: IconButton(
            tooltip: AppText.t('تطبيق', 'Apply'),
            icon: const Icon(Icons.search),
            onPressed: () => onApply(controller.text.trim()),
          ),
        ),
        onSubmitted: onApply,
      ),
    );
  }
}

/// Severity, in the app's vocabulary rather than the database's.
String severityLabel(String value) => switch (value) {
  'Critical' => AppText.t('حرجة', 'Critical'),
  'Major' => AppText.t('كبرى', 'Major'),
  'Minor' => AppText.t('بسيطة', 'Minor'),
  _ => value,
};
