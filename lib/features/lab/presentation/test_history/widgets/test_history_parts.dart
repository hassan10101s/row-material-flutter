import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_page_size.dart';
import '../../../core/test_history_logic.dart';
import '../../../core/lab_result_format.dart';
import '../../cubit/test_history_state.dart';
import '../test_history_print.dart';
import '../test_history_scope.dart';

/// Small widgets composing the test-history tab on both experiences.
///
/// Data and mutation live in [TestHistoryScope]; everything here is pure
/// rendering + callbacks, so the desktop table and the mobile cards can
/// never disagree on content.

/// Search + filter + "All" toolbar. Stacks on narrow widths (single
/// experience layout via [AppBreakpoints], not a form-factor branch).
class TestHistoryToolbar extends StatelessWidget {
  const TestHistoryToolbar({
    super.key,
    required this.chips,
    required this.hasQuery,
    required this.onOpenFilters,
    required this.onClearAll,
    this.trailing,
  });

  final List<({String key, String label})> chips;
  final bool hasQuery;
  final VoidCallback onOpenFilters;
  final VoidCallback onClearAll;

  /// Extra action sharing the search row (desktop "New test" button), so
  /// search and actions sit on one level instead of stacking rows.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scope = TestHistoryScope.of(context);
    final search = TextField(
      controller: scope.query,
      onChanged: (_) => scope.onQueryChanged(),
      decoration: InputDecoration(
        prefixIcon: Icon(Icons.search, size: 20.r),
        suffixIcon: scope.query.text.isEmpty
            ? null
            : IconButton(
                tooltip: AppText.t('مسح البحث', 'Clear search'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: Icon(Icons.close, size: 18.r),
                onPressed: scope.clearQuery,
              ),
        hintText: AppText.t(
          'بحث في: تحليل / عينة / مصدر / كود دخول / نتيجة / فاحص / حالة...',
          'Search analysis, sample, source, entry code, result...',
        ),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
    final actions = [
      FilterButton(activeCount: chips.length, onPressed: onOpenFilters),
      AppButton(
        label: AppText.t('الكل', 'All'),
        icon: Icon(Icons.grid_view_outlined, size: 16.r),
        style: AppButtonStyle.secondary,
        small: true,
        onPressed: chips.isEmpty && !hasQuery ? null : onClearAll,
      ),
      ?trailing,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= AppBreakpoints.expanded) {
          return Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: AppSpacing.sm),
              ...actions,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            search,
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ],
        );
      },
    );
  }
}

/// Active-filter chips + showing-count + in/out-range badges.
class TestHistoryChips extends StatelessWidget {
  const TestHistoryChips({
    super.key,
    required this.chips,
    required this.showing,
    required this.total,
    required this.summary,
    required this.onClearAll,
  });

  final List<({String key, String label})> chips;
  final int showing;
  final int total;
  final Map<String, int> summary;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final scope = TestHistoryScope.of(context);
    final count = Text(
      AppText.t('يتم عرض $showing من أصل $total', 'Showing $showing of $total'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
    );
    final badges = [
      if (summary['out'] != 0)
        StatBadge(
          label: AppText.t(
            'خارج النطاق: ${summary['out']}',
            'Out of range: ${summary['out']}',
          ),
          color: AppColors.danger,
        ),
      if (summary['in'] != 0)
        StatBadge(
          label: AppText.t(
            'ضمن النطاق: ${summary['in']}',
            'In range: ${summary['in']}',
          ),
          color: AppColors.success,
        ),
    ];
    if (chips.isEmpty) {
      return Row(
        children: [
          Expanded(child: count),
          ...badges,
        ],
      );
    }
    // Narrow phones: the trailing count + badges collapse below the chips
    // instead of squeezing them into an overflowing Row.
    return LayoutBuilder(
      builder: (context, constraints) {
        final chipsWrap = Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              AppText.t('الفلاتر:', 'Filters:'),
              style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
            ),
            for (final chip in chips)
              InputChip(
                visualDensity: VisualDensity.compact,
                label: Text(
                  chip.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.spMax),
                ),
                onDeleted: () => scope.clearChip(chip.key),
              ),
            TextButton(
              onPressed: onClearAll,
              child: Text(
                AppText.t('مسح الكل', 'Clear all'),
                style: TextStyle(fontSize: 12.spMax),
              ),
            ),
          ],
        );
        final trailing = Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [count, ...badges],
        );
        if (constraints.maxWidth < 480) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [chipsWrap, const SizedBox(height: 4), trailing],
          );
        }
        return Row(
          children: [
            Expanded(child: chipsWrap),
            const SizedBox(width: 8),
            Flexible(child: trailing),
          ],
        );
      },
    );
  }
}

/// Desktop ten-column sortable table, verbatim from the pre-split screen.
///
/// Tapping a row opens its detail/edit screen ([onOpen] receives the row).
/// Long-pressing a row enters multi-select mode ([onLongPressRow]); while
/// [selecting], checkboxes appear and tapping toggles instead of opening.
class TestHistoryTable extends StatelessWidget {
  const TestHistoryTable({
    super.key,
    required this.slice,
    required this.start,
    required this.isEmpty,
    this.onOpen,
    this.selecting = false,
    this.selectedIds = const <String>{},
    this.onToggleSelect,
    this.onLongPressRow,
    this.onToggleSelectAll,
    this.allOnPageSelected = false,
  });

  final List<Map<String, dynamic>> slice;
  final int start;
  final bool isEmpty;
  final ValueChanged<Map<String, dynamic>>? onOpen;

  /// True once the user long-pressed: selection checkboxes are shown.
  final bool selecting;

  /// Keys ([thRowKey]) of the selected rows.
  final Set<String> selectedIds;
  final ValueChanged<Map<String, dynamic>>? onToggleSelect;
  final ValueChanged<Map<String, dynamic>>? onLongPressRow;
  final VoidCallback? onToggleSelectAll;
  final bool allOnPageSelected;

  @override
  Widget build(BuildContext context) {
    final scope = TestHistoryScope.of(context);
    DataColumn sortable(String label, String key) {
      return DataColumn(
        label: InkWell(
          onTap: () => scope.setSort(key),
          child: Text('$label${scope.sortMark(key)}'),
        ),
      );
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            // No built-in checkbox column: its boxes would open the editor
            // on tap (onSelectChanged doubles as the row opener). Selection
            // has exactly one UI — the explicit first column below, shown
            // only in select mode after a long-press.
            showCheckboxColumn: false,
            columns: [
              if (selecting)
                DataColumn(
                  label: Checkbox(
                    value: allOnPageSelected,
                    tristate: true,
                    onChanged: onToggleSelectAll == null
                        ? null
                        : (_) => onToggleSelectAll!(),
                  ),
                ),
              const DataColumn(label: Text('#')),
              sortable(AppText.t('التوقيت', 'Time'), 'tested_at'),
              sortable(AppText.t('التحليل', 'Analysis'), 'analysis_name'),
              sortable(AppText.t('العينة', 'Sample'), 'sample_name'),
              sortable(AppText.t('المصدر', 'Source'), 'source_name'),
              sortable(AppText.t('كود الدخول', 'Entry code'), 'entry_code'),
              sortable(AppText.t('النتيجة', 'Result'), 'result_text'),
              DataColumn(label: Text(AppText.t('النطاق', 'Range'))),
              sortable(AppText.t('الحالة', 'Status'), 'range_state'),
              sortable(AppText.t('بواسطة', 'By'), 'tested_by_name'),
            ],
            rows: [
              if (slice.isEmpty)
                DataRow(
                  cells: [
                    if (selecting) const DataCell(SizedBox()),
                    for (var i = 0; i < 10; i++)
                      DataCell(
                        i == 0
                            ? Text(
                                isEmpty
                                    ? AppText.t(
                                        'لا توجد تحاليل بعد. شغّل تحليلاً من تبويب تشغيل تحليل.',
                                        'No analyses yet. Run one from the run-test tab.',
                                      )
                                    : AppText.t(
                                        'لا توجد نتائج مطابقة للفلاتر الحالية.',
                                        'No results match the current filters.',
                                      ),
                                style: TextStyle(color: AppColors.textMuted),
                              )
                            : const SizedBox(),
                      ),
                  ],
                )
              else
                for (var i = 0; i < slice.length; i++)
                  historyRow(
                    slice[i],
                    start + i + 1,
                    onTap: onOpen == null ? null : () => onOpen!(slice[i]),
                    selected: selectedIds.contains(thRowKey(slice[i])),
                    showSelect: selecting,
                    onToggleSelect: onToggleSelect == null
                        ? null
                        : () => onToggleSelect!(slice[i]),
                    onLongPress: onLongPressRow == null
                        ? null
                        : () => onLongPressRow!(slice[i]),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One history row (desktop tint + cells), shared by the table.
/// [onTap] opens the row's detail/edit screen. In select mode the checkbox
/// cell toggles ([onToggleSelect]) and a long-press ([onLongPress]) is what
/// enters the mode in the first place.
DataRow historyRow(
  Map<String, dynamic> r,
  int index, {
  VoidCallback? onTap,
  bool selected = false,
  bool showSelect = false,
  VoidCallback? onToggleSelect,
  VoidCallback? onLongPress,
}) {
  final out = '${r['range_state'] ?? ''}' == 'out';
  final inn = '${r['range_state'] ?? ''}' == 'in';
  final stateColor = out
      ? AppColors.danger
      : inn
      ? AppColors.success
      : AppColors.textMuted;
  final range = r['min'] == null && r['max'] == null
      ? '-'
      : '${r['min'] ?? ''} – ${r['max'] ?? ''} '
            '${r['range_unit'] ?? r['analysis_unit'] ?? '%'}';
  return DataRow(
    selected: selected,
    color: out
        ? WidgetStatePropertyAll(AppColors.danger.withValues(alpha: 0.06))
        : inn
        ? WidgetStatePropertyAll(AppColors.success.withValues(alpha: 0.06))
        : null,
    onSelectChanged: showSelect
        ? (onToggleSelect == null ? null : (_) => onToggleSelect())
        : (onTap == null ? null : (_) => onTap()),
    onLongPress: onLongPress,
    cells: [
      if (showSelect)
        DataCell(
          Checkbox(
            value: selected,
            onChanged: onToggleSelect == null ? null : (_) => onToggleSelect(),
          ),
        ),
      DataCell(Text('$index')),
      DataCell(
        Text(
          thFmtDateTime(r['tested_at']),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      DataCell(
        Text(
          '${r['analysis_name'] ?? '-'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      DataCell(
        Text(
          '${r['sample_name'] ?? '-'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      DataCell(
        Text(
          '${r['source_name'] ?? '-'}'
          '${'${r['source_type'] ?? ''}'.isEmpty ? '' : ' (${r['source_type'] == 'product' ? 'منتج' : 'خام'})'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      DataCell(
        Text(
          '${r['entry_code'] ?? '-'}',
          textDirection: TextDirection.ltr,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      DataCell(
        Text(
          formatLabResult(r['result_text']),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: out ? AppColors.danger : null,
          ),
        ),
      ),
      DataCell(Text(range, overflow: TextOverflow.ellipsis)),
      DataCell(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: stateColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            thRangeLabel('${r['range_state'] ?? 'none'}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: stateColor,
              fontSize: 11.spMax,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      DataCell(
        Text(
          '${r['tested_by_name'] ?? '-'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

/// Mobile card list: one card per result (a ten-column table at 400dp
/// would be unusable). Tapping a card opens its detail/edit screen, unless
/// select mode is on (long-press enters it) — then tapping toggles.
class TestHistoryCards extends StatelessWidget {
  const TestHistoryCards({
    super.key,
    required this.slice,
    required this.start,
    this.onOpen,
    this.selecting = false,
    this.selectedIds = const <String>{},
    this.onToggleSelect,
    this.onLongPressRow,
  });

  final List<Map<String, dynamic>> slice;
  final int start;
  final ValueChanged<Map<String, dynamic>>? onOpen;

  /// True once the user long-pressed: checkboxes are shown.
  final bool selecting;
  final Set<String> selectedIds;
  final ValueChanged<Map<String, dynamic>>? onToggleSelect;
  final ValueChanged<Map<String, dynamic>>? onLongPressRow;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: slice.length,
      // md (12) between cards so they read as separate tappable rows
      // instead of one stuck mass — sm (8) is reserved for in-card gaps.
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
      itemBuilder: (context, i) => TestHistoryCard(
        row: slice[i],
        index: start + i + 1,
        onTap: onOpen == null ? null : () => onOpen!(slice[i]),
        selected: selectedIds.contains(thRowKey(slice[i])),
        showSelect: selecting,
        onToggleSelect: onToggleSelect == null
            ? null
            : () => onToggleSelect!(slice[i]),
        onLongPress: onLongPressRow == null
            ? null
            : () => onLongPressRow!(slice[i]),
      ),
    );
  }
}

class TestHistoryCard extends StatelessWidget {
  const TestHistoryCard({
    super.key,
    required this.row,
    required this.index,
    this.onTap,
    this.selected = false,
    this.showSelect = false,
    this.onToggleSelect,
    this.onLongPress,
  });

  final Map<String, dynamic> row;
  final int index;
  final VoidCallback? onTap;
  final bool selected;
  final bool showSelect;
  final VoidCallback? onToggleSelect;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final out = '${row['range_state'] ?? ''}' == 'out';
    final inn = '${row['range_state'] ?? ''}' == 'in';
    final stateColor = out
        ? AppColors.danger
        : inn
        ? AppColors.success
        : AppColors.textMuted;
    final unit = '${row['range_unit'] ?? row['analysis_unit'] ?? '%'}';
    return AppCard(
      // AppCard (border + radius + shadow) replaces the raw Card so every
      // row has the same surface as the rest of the app; the tap ripple
      // comes free with onTap. In select mode a tap toggles the checkbox
      // instead of opening the editor, so a stray tap can never land the
      // user in the edit screen while selecting.
      onTap: showSelect ? onToggleSelect : onTap,
      onLongPress: onLongPress,
      color: selected ? AppColors.primary.withValues(alpha: 0.06) : null,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showSelect) ...[
                Checkbox(
                  value: selected,
                  visualDensity: VisualDensity.compact,
                  onChanged: onToggleSelect == null
                      ? null
                      : (_) => onToggleSelect!(),
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              Container(
                width: 30.r,
                height: 30.r,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$index',
                  style: TextStyle(
                    fontSize: 12.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  '${row['analysis_name'] ?? '-'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  thRangeLabel('${row['range_state'] ?? 'none'}'),
                  style: TextStyle(
                    color: stateColor,
                    fontSize: 11.spMax,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // One fact per line with its own icon: the old single-line
          // "time • sample • source" ellipsis swallowed two of the three
          // values on a 360dp phone.
          _metaLine(Icons.science_outlined, '${row['sample_name'] ?? '-'}'),
          const SizedBox(height: AppSpacing.xs),
          _metaLine(Icons.inventory_2_outlined, '${row['source_name'] ?? '-'}'),
          const SizedBox(height: AppSpacing.xs),
          _metaLine(
            Icons.schedule_outlined,
            '${thFmtDateTime(row['tested_at'])} • ${row['tested_by_name'] ?? '-'}',
          ),
          if ('${row['entry_code'] ?? ''}'.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            _metaLine(
              Icons.qr_code_2_outlined,
              '${row['entry_code']}',
              mono: true,
            ),
          ],
          const Divider(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    text: formatLabResult(row['result_text']),
                    style: TextStyle(
                      fontSize: 16.spMax,
                      fontWeight: FontWeight.w700,
                      color: out ? AppColors.danger : AppColors.textStrong,
                    ),
                    children: [
                      TextSpan(
                        text: ' $unit',
                        style: TextStyle(
                          fontSize: 12.spMax,
                          fontWeight: FontWeight.w400,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Affordance: the whole card opens the detail/edit screen.
              Icon(Icons.chevron_left, size: 22.r, color: AppColors.textMuted),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bar shown only while selecting (desktop + mobile): how many records are
/// picked, print-them-as-HTML, and exit selection mode. Owns the printing
/// spinner so the hosting tabs stay stateless.
class TestHistorySelectionBar extends StatefulWidget {
  const TestHistorySelectionBar({
    super.key,
    required this.rows,
    required this.onClear,
  });

  /// The selected rows (resolved by the tab against the current list).
  final List<Map<String, dynamic>> rows;
  final VoidCallback onClear;

  @override
  State<TestHistorySelectionBar> createState() =>
      _TestHistorySelectionBarState();
}

class _TestHistorySelectionBarState extends State<TestHistorySelectionBar> {
  bool _printing = false;

  Future<void> _print() async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      await TestHistoryPrinter.printRows(context, widget.rows);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      color: AppColors.primary.withValues(alpha: 0.06),
      child: Row(
        children: [
          Icon(Icons.checklist_outlined, size: 20.r, color: AppColors.primary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              AppText.t(
                'محدد: ${widget.rows.length}',
                'Selected: ${widget.rows.length}',
              ),
              style: TextStyle(
                fontSize: 13.spMax,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
          ),
          AppButton(
            small: true,
            label: AppText.t('طباعة HTML', 'Print HTML'),
            icon: _printing
                ? SizedBox(
                    width: 16.r,
                    height: 16.r,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.print_outlined, size: 16.r),
            onPressed: _printing ? null : _print,
          ),
          const SizedBox(width: AppSpacing.xs),
          IconButton(
            tooltip: AppText.t('إلغاء تحديد الكل', 'Clear selection'),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: widget.onClear,
            icon: Icon(Icons.close, size: 18.r),
          ),
        ],
      ),
    );
  }
}

Widget _metaLine(IconData icon, String text, {bool mono = false}) {
  return Row(
    children: [
      Icon(icon, size: 15.r, color: AppColors.textMuted),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textDirection: mono ? TextDirection.ltr : null,
          style: TextStyle(fontSize: 12.spMax, color: AppColors.textMuted),
        ),
      ),
    ],
  );
}

/// Shared page-number strip (both experiences).
class TestHistoryPagination extends StatelessWidget {
  const TestHistoryPagination({
    super.key,
    required this.page,
    required this.pageCount,
  });

  final int page;
  final int pageCount;

  @override
  Widget build(BuildContext context) {
    final scope = TestHistoryScope.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        AppPageSizeSelector(
          value: scope.pageSize,
          onChanged: scope.setPageSize,
        ),
        if (pageCount > 1)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: AppText.t('السابق', 'Previous'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: page <= 1 ? null : scope.prevPage,
                icon: const Icon(Icons.chevron_left),
              ),
              for (var p = 1; p <= pageCount; p++)
                if (p == 1 || p == pageCount || (p - page).abs() <= 2)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: p == page
                        ? Container(
                            width: 30,
                            height: 30,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '$p',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13.spMax,
                              ),
                            ),
                          )
                        : TextButton(
                            onPressed: () => scope.setPage(p),
                            child: Text(
                              '$p',
                              style: TextStyle(fontSize: 13.spMax),
                            ),
                          ),
                  ),
              IconButton(
                tooltip: AppText.t('التالي', 'Next'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: page >= pageCount ? null : scope.nextPage,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
      ],
    );
  }
}

class FilterButton extends StatelessWidget {
  final int activeCount;
  final VoidCallback onPressed;

  const FilterButton({
    super.key,
    required this.activeCount,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final active = activeCount > 0;
    return AppButton(
      label: active
          ? AppText.t('فلترة ($activeCount)', 'Filter ($activeCount)')
          : AppText.t('فلترة', 'Filter'),
      icon: Icon(Icons.filter_alt_outlined, size: 16.r),
      style: active ? AppButtonStyle.primary : AppButtonStyle.secondary,
      small: true,
      onPressed: onPressed,
    );
  }
}

class StatBadge extends StatelessWidget {
  final String label;
  final Color color;
  const StatBadge({super.key, required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11.spMax,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// The filter grid (period/mode/date/limit/analysis/source/chemical/range),
/// already width-responsive inside: stacks when narrow, so it renders
/// identically in the desktop window and the mobile bottom sheet.
Widget testHistoryFilterGrid(
  TestHistoryState state,
  List<({String value, String label})> chemOptions, {
  required String mode,
  required String specificDate,
  required String analysisId,
  required String sourceType,
  required String chemicalId,
  required String rangeState,
  required String recordLimit,
  required ValueChanged<String> onMode,
  required VoidCallback onDate,
  required ValueChanged<String> onAnalysis,
  required ValueChanged<String> onSource,
  required ValueChanged<String> onChemical,
  required ValueChanged<String> onRange,
  required ValueChanged<String> onLimit,
}) {
  Widget field({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 11.spMax,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }

  Widget modeButton(String label, String value) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: mode == value,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => onMode(value),
      ),
    );
  }

  return LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < AppBreakpoints.expanded;
      final children = <Widget>[
        field(
          label: AppText.t('التصفية', 'Period'),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              modeButton(AppText.t('الكل', 'All'), 'all'),
              modeButton(AppText.t('24 ساعة', '24h'), 'last24h'),
              modeButton(AppText.t('تاريخ', 'Date'), 'specific-date'),
            ],
          ),
        ),
        if (mode == 'specific-date')
          field(
            label: AppText.t('اختر التاريخ', 'Pick date'),
            child: InkWell(
              onTap: onDate,
              borderRadius: BorderRadius.circular(8),
              child: InputDecorator(
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: Icon(Icons.calendar_today, size: 16.r),
                ),
                child: Text(specificDate),
              ),
            ),
          ),
        field(
          label: AppText.t('حد السجلات', 'Record limit'),
          child: DropdownButtonFormField<String>(
            initialValue: recordLimit,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final l in TestHistoryScopeState.recordLimits)
                DropdownMenuItem(value: l, child: Text(l)),
            ],
            onChanged: (v) => onLimit(v ?? recordLimit),
          ),
        ),
        field(
          label: AppText.t('التحليل', 'Analysis'),
          child: DropdownButtonFormField<String>(
            initialValue: analysisId,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(AppText.t('كل التحاليل', 'All analyses')),
              ),
              for (final a in state.analyses)
                DropdownMenuItem(
                  value: '${a['id']}',
                  child: Text('${a['name']}', overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => onAnalysis(v ?? ''),
          ),
        ),
        field(
          label: AppText.t('النوع', 'Source type'),
          child: DropdownButtonFormField<String>(
            initialValue: sourceType,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(AppText.t('كل الأنواع', 'All types')),
              ),
              DropdownMenuItem(
                value: 'raw_material',
                child: Text(AppText.t('مادة خام', 'Raw material')),
              ),
              DropdownMenuItem(
                value: 'product',
                child: Text(AppText.t('منتج', 'Product')),
              ),
            ],
            onChanged: (v) => onSource(v ?? ''),
          ),
        ),
        field(
          label: AppText.t('المواد المستهلكة', 'Consumables'),
          child: DropdownButtonFormField<String>(
            initialValue: chemicalId,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(AppText.t('كل المواد', 'All items')),
              ),
              for (final o in chemOptions)
                DropdownMenuItem(value: o.value, child: Text(o.label)),
            ],
            onChanged: (v) => onChemical(v ?? ''),
          ),
        ),
        field(
          label: AppText.t('الحالة', 'Range state'),
          child: DropdownButtonFormField<String>(
            initialValue: rangeState,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(AppText.t('كل النتائج', 'All results')),
              ),
              DropdownMenuItem(
                value: 'out',
                child: Text(AppText.t('خارج النطاق', 'Out of range')),
              ),
              DropdownMenuItem(
                value: 'in',
                child: Text(AppText.t('ضمن النطاق', 'In range')),
              ),
              DropdownMenuItem(
                value: 'none',
                child: Text(AppText.t('بدون نطاق', 'No range')),
              ),
            ],
            onChanged: (v) => onRange(v ?? ''),
          ),
        ),
      ];
      if (narrow) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final c in children)
            Expanded(
              child: Padding(
                padding: const EdgeInsetsDirectional.only(start: AppSpacing.sm),
                child: c,
              ),
            ),
        ],
      );
    },
  );
}
