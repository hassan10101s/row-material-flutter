import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_adaptive_list.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_dropdown.dart';
import '../../../../../design_system/widgets/app_window.dart';
import '../../../domain/ncr_filters.dart';
import '../../../domain/ncr_report_row.dart';
import '../../cubit/qc_ncr_cubit.dart';
import '../../widgets/ncr_pill.dart';

/// Shared NCR-list pieces, composed by both variants.
///
/// The desktop variant renders [ncrHeaders]/[ncrCells] in an
/// [AppPaginatedTable]; the mobile variant maps the same cells into
/// [AppDataRow]s for cards. Pills, filter sheet and chips are identical.

List<String> ncrHeaders() => [
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

/// Cells are widgets, not strings, so severity and status render as the
/// same pills the detail screen uses.
/// Table/card cells ellipsize: these render in fixed-flex columns and in
/// the mobile `_DataCard` facts, where a long reference or name would
/// otherwise clip mid-word.
List<Widget> ncrCells(NcrReportRow r) => <Widget>[
  Text(r.reference, maxLines: 1, overflow: TextOverflow.ellipsis),
  Text(r.description, maxLines: 2, overflow: TextOverflow.ellipsis),
  ncrSeverityPill(r.severity),
  ncrStatePill(r.status),
  Text(
    r.inspectionRefId.isEmpty
        ? (r.inspectorName.isEmpty ? '—' : r.inspectorName)
        : r.inspectionRefId,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  ),
  Text(
    r.lotNo.isNotEmpty
        ? r.lotNo
        : r.batchNo.isNotEmpty
        ? r.batchNo
        : '—',
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  ),
  Text(
    r.assignedToName.isEmpty ? '—' : r.assignedToName,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  ),
  // The overdue date is the one cell that gets coloured: a date is
  // scannable, but a date that has already passed is not.
  Text(
    r.dueDate.isEmpty ? '—' : r.dueDate,
    style: r.isOverdue
        ? TextStyle(color: AppColors.danger, fontWeight: FontWeight.bold)
        : null,
  ),
  if (r.capaStatus.isEmpty) const Text('-') else ncrCapaPill(r.capaStatus),
];

/// Severity, in the app's vocabulary rather than the database's.
String severityLabel(String value) => switch (value) {
  'Critical' => AppText.t('حرجة', 'Critical'),
  'Major' => AppText.t('كبرى', 'Major'),
  'Minor' => AppText.t('بسيطة', 'Minor'),
  _ => value,
};

/// Opens the filter sheet as an adaptive overlay (dialog on desktop,
/// bottom sheet on phones). The overlay is a new route, so the page's
/// provider is re-provided by value: the sheet writes filters through
/// the same instance the page reads.
void openNcrFilters(
  BuildContext context,
  QcNcrState state,
  QcNcrCubit cubit,
) {
  showAppOverlay<void>(
    context,
    title: AppText.t('تصفية النتائج', 'Filter results'),
    icon: Icons.filter_alt_outlined,
    size: AppWindowSize.sm,
    builder: (_, _) => BlocProvider.value(
      value: cubit,
      child: NcrFilterSheet(state: state),
    ),
  );
}

/// One removable chip per active filter, so the scope is visible on the
/// list itself and not only inside a sheet the reader has to reopen.
class NcrActiveFilterChips extends StatelessWidget {
  const NcrActiveFilterChips({super.key, required this.state});

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
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onDeleted: onRemove,
      deleteIcon: const Icon(Icons.close, size: 16),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// The filter drawer (plan §22.4). Chrome (title, padding, scroll) comes
/// from the overlay host.
class NcrFilterSheet extends StatefulWidget {
  const NcrFilterSheet({super.key, required this.state});

  final QcNcrState state;

  @override
  State<NcrFilterSheet> createState() => _NcrFilterSheetState();
}

class _NcrFilterSheetState extends State<NcrFilterSheet> {
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

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        // A stored filter from an older build can hold a value outside
        // this list; [AppDropdown] renders it disabled instead of throwing.
        AppDropdown<String>(
          value: _dateField,
          labelText: AppText.t('طبّق النطاق على', 'Date range applies to'),
          items: [
            AppDropdownItem(
              value: NcrFilters.dateFieldCreated,
              label: AppText.t('تاريخ الفتح', 'Date raised'),
            ),
            AppDropdownItem(
              value: NcrFilters.dateFieldInspection,
              label: AppText.t('تاريخ التفتيش', 'Inspection date'),
            ),
            AppDropdownItem(
              value: NcrFilters.dateFieldClosed,
              label: AppText.t('تاريخ الإغلاق', 'Closure date'),
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
        AppWindow.footer(
          actions: [
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
                  label: Text(
                    labels[value] ?? render?.call(value) ?? value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
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
