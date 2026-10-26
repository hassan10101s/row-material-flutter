import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../../../../core/constants/app_strings.dart';
import '../../../../../core/responsive/form_factor.dart';
import '../../../../../design_system/tokens/app_breakpoints.dart';
import '../../../../../design_system/tokens/app_colors.dart';
import '../../../../../design_system/tokens/app_spacing.dart';
import '../../../../../design_system/widgets/app_button.dart';
import '../../../../../design_system/widgets/app_card.dart';
import '../../../../../design_system/widgets/app_page_size.dart';
import '../../../../../design_system/widgets/app_paginated_table.dart';
import '../../../core/test_history_logic.dart';
import '../../../core/lab_result_format.dart';
import '../../cubit/test_history_state.dart';
import '../test_history_print.dart';
import '../test_history_pdf.dart';
import '../test_history_scope.dart';
import '../../../../../design_system/widgets/app_select_field.dart';
import '../../../../../design_system/widgets/app_text_field.dart';

/// Small widgets composing the test-history tab on both experiences.
///
/// Data and mutation live in [TestHistoryScope]; everything here is pure
/// rendering + callbacks, so the desktop table and the mobile cards can
/// never disagree on content.

/// Search + filter + "All" toolbar. One row at every width: the search takes
/// the remaining width and the actions sit beside it — never stacked, so the
/// pinned header cannot grow past a single line. [AppBreakpoints] keeps the
/// desktop "New test" [trailing] slot from starving the search.
class TestHistoryToolbar extends StatelessWidget {
  const TestHistoryToolbar({
    super.key,
    required this.chips,
    required this.hasQuery,
    required this.onOpenFilters,
    required this.onClearAll,
    this.trailing,
    this.onExportPdf,
  });

  final List<({String key, String label})> chips;
  final bool hasQuery;
  final VoidCallback onOpenFilters;
  final VoidCallback onClearAll;

  /// Extra action sharing the search row (desktop "New test" button), so
  /// search and actions sit on one level instead of stacking rows.
  final Widget? trailing;

  /// Exports the current (filtered) register as a PDF. Null hides the action.
  final VoidCallback? onExportPdf;

  @override
  Widget build(BuildContext context) {
    final scope = TestHistoryScope.of(context);
    final search = AppTextField(
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
      if (onExportPdf != null)
        IconButton(
          tooltip: AppText.t('تصدير الجدول PDF', 'Export table PDF'),
          visualDensity: VisualDensity.compact,
          onPressed: onExportPdf,
          icon: Icon(Icons.picture_as_pdf_outlined, size: 18.r),
        ),
      ?trailing,
    ];
    return Builder(
      builder: (context) {
        if (!FormFactor.current.isMobile) {
          return Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: AppSpacing.sm),
              ...actions,
            ],
          );
        }
        // Phones: one row — the search keeps the width, the filter/clear
        // actions sit beside it. The old layout stacked the search above the
        // actions, which ate half the screen before the first card.
        return Row(
          children: [
            Expanded(child: search),
            const SizedBox(width: AppSpacing.sm),
            for (final action in actions) ...[
              action,
              const SizedBox(width: AppSpacing.sm),
            ],
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
    // Narrow phones: keep the whole strip to a single (scrollable) line so
    // the pinned header never grows past one row; the count/badges ride on
    // the same line instead of collapsing below the chips.
    final chipItems = <Widget>[
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
      AppButton(
        onPressed: onClearAll,
        label: AppText.t('مسح الكل', 'Clear all'),
        style: AppButtonStyle.ghost,
        small: true,
      ),
    ];
    final trailingItems = <Widget>[count, ...badges];
    return Builder(
      builder: (context) {
        if (FormFactor.current.isMobile) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ...chipItems,
                const SizedBox(width: 8),
                ...trailingItems,
              ],
            ),
          );
        }
        return Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: chipItems,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: trailingItems,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Desktop test log: the shared [AppPaginatedTable] (pinned header, built-in
/// pager, long-press multi-select) with the log's own columns and sort keys.
///
/// Tapping a row opens its detail/edit screen ([onOpen] receives the row).
/// Long-pressing a row enters multi-select mode; while [selecting] the
/// checkboxes appear and a tap toggles instead of opening. The out-of-range /
/// in-range row tint and the range badge ride on the shared table too.
class TestHistoryTable extends StatelessWidget {
  const TestHistoryTable({
    super.key,
    required this.slice,
    required this.start,
    required this.isEmpty,
    this.onOpen,
    this.onOpenReport,
    this.selecting = false,
    this.selectedIds = const <String>{},
    this.onToggleSelect,
    this.onLongPressRow,
    this.onToggleSelectAll,
    this.allOnPageSelected = false,
    this.total,
    this.page,
    this.onPageChanged,
    this.onPageSizeChanged,
    this.rowsPerPage = thPageSize,
  });

  final List<Map<String, dynamic>> slice;
  final int start;
  final bool isEmpty;
  final ValueChanged<Map<String, dynamic>>? onOpen;

  /// Opens the inspection (المحضر) linked by the row's entry code. Tapping the
  /// merged source+code cell calls this instead of [onOpen] — the freed entry
  /// code column lives inside the source cell now.
  final ValueChanged<Map<String, dynamic>>? onOpenReport;

  /// True once the user long-pressed: selection checkboxes are shown.
  final bool selecting;

  /// Keys ([thRowKey]) of the selected rows.
  final Set<String> selectedIds;
  final ValueChanged<Map<String, dynamic>>? onToggleSelect;

  /// Kept for API parity: the shared table now owns long-press-to-select, so
  /// the press itself enters select mode through [onToggleSelect].
  final ValueChanged<Map<String, dynamic>>? onLongPressRow;
  final VoidCallback? onToggleSelectAll;
  final bool allOnPageSelected;

  /// Server-driven paging, owned by [TestHistoryScope]. When [total] and
  /// [onPageChanged] are supplied the shared table pages through them; without
  /// them it slices [slice] in memory (used by the selection widget test).
  final int? total;
  final int? page;
  final Future<void> Function(int page)? onPageChanged;
  final Future<void> Function(int pageSize)? onPageSizeChanged;
  final int rowsPerPage;

  /// Sort keys aligned with the headers; null = not sortable (#, Range).
  static const List<String?> _sortKeys = [
    null,
    'tested_at',
    'analysis_name',
    'sample_name',
    'source_name',
    'result_text',
    null,
    'range_state',
    'tested_by_name',
  ];

  @override
  Widget build(BuildContext context) {
    final scope = TestHistoryScope.of(context);
    final selectedIndices = <int>{
      for (var i = 0; i < slice.length; i++)
        if (selectedIds.contains(thRowKey(slice[i]))) i,
    };
    return AppPaginatedTable(
      height: null,
      minTableWidth: 900,
      columnFlex: const [0.35, 1.15, 1.4, 1.0, 1.3, 0.95, 1.05, 0.8, 0.9],
      headers: [
        '#',
        AppText.t('التوقيت', 'Time'),
        AppText.t('التحليل', 'Analysis'),
        AppText.t('العينة', 'Sample'),
        AppText.t('المصدر', 'Source'),
        AppText.t('النتيجة', 'Result'),
        AppText.t('النطاق', 'Range'),
        AppText.t('الحالة', 'Status'),
        AppText.t('بواسطة', 'By'),
      ],
      headerSortKeys: _sortKeys,
      sortKey: scope.sortKey,
      sortAscending: scope.sortDir > 0,
      onSortChanged: scope.setSort,
      rows: [
        for (var i = 0; i < slice.length; i++)
          _rowCells(slice[i], start + i + 1),
      ],
      rowBackgrounds: [for (final r in slice) _rowTint(r)],
      empty: Padding(
        padding: const EdgeInsets.all(AppSpacing.page),
        child: Text(
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
        ),
      ),
      onRowTap: onOpen == null ? null : (i) => onOpen!(slice[i]),
      selectHidden: true,
      selectedIndices: selectedIndices,
      onToggleIndex: onToggleSelect == null
          ? null
          : (i) => onToggleSelect!(slice[i]),
      selectAllValue: allOnPageSelected
          ? true
          : selectedIndices.isEmpty
          ? false
          : null,
      onToggleAll: onToggleSelectAll == null
          ? null
          : (_) => onToggleSelectAll!(),
      total: total,
      page: page,
      rowsPerPage: rowsPerPage,
      onPageChanged: onPageChanged,
      onPageSizeChanged: onPageSizeChanged,
    );
  }

  /// One row's cells, in the same column order as the headers above.
  List<Widget> _rowCells(Map<String, dynamic> r, int index) {
    final out = '${r['range_state'] ?? ''}' == 'out';
    final range = r['min'] == null && r['max'] == null
        ? '-'
        : '${r['min'] ?? ''} – ${r['max'] ?? ''} '
              '${r['range_unit'] ?? r['analysis_unit'] ?? '%'}';
    return [
      Text('$index'),
      Text(
        thFmtDateTime(r['tested_at']),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      _analysisCell(r),
      Text(
        '${r['sample_name'] ?? '-'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      _sourceEntryCell(
        r,
        onOpenReport: selecting || onOpenReport == null
            ? null
            : () => onOpenReport!(r),
      ),
      Text(
        formatLabResult(r['result_text']),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: out ? AppColors.danger : null,
        ),
      ),
      Text(
        range,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12.spMax),
      ),
      _statusPill(r),
      Text(
        '${r['tested_by_name'] ?? '-'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ];
  }

  /// Faint out-of-range / in-range row tint (the pre-rebuild DataRow colour).
  Color? _rowTint(Map<String, dynamic> r) {
    final state = '${r['range_state'] ?? ''}';
    if (state == 'out') return AppColors.danger.withValues(alpha: 0.06);
    if (state == 'in') return AppColors.success.withValues(alpha: 0.06);
    return null;
  }

  Widget _statusPill(Map<String, dynamic> r) {
    final state = '${r['range_state'] ?? ''}';
    final color = state == 'out'
        ? AppColors.danger
        : state == 'in'
        ? AppColors.success
        : AppColors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        thRangeLabel(state.isEmpty ? 'none' : state),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 11.spMax,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Analysis cell: the analysis name on top, the method/reference (`a.reference`,
/// e.g. "ISO 2171" or an in-house method) beneath it in a very small muted font.
/// Hidden when the analysis has no reference, so the cell collapses to a single
/// line exactly like before.
Widget _analysisCell(
  Map<String, dynamic> r, {
  TextStyle? nameStyle,
  int nameMaxLines = 1,
}) {
  final reference = '${r['analysis_reference'] ?? ''}'.trim();
  final hasReference = reference.isNotEmpty && reference != 'null';
  return Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Flexible(
        child: Text(
          '${r['analysis_name'] ?? '-'}',
          maxLines: nameMaxLines,
          overflow: TextOverflow.ellipsis,
          style: nameStyle,
        ),
      ),
      if (hasReference) ...[
        const SizedBox(height: 2),
        Flexible(
          child: Text(
            reference,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9.5.spMax,
              height: 1.1,
              color: AppColors.textMuted,
            ),
          ),
        ),
      ],
    ],
  );
}

/// Merged source + entry-code cell: the source name (with its خام/منتج tag) on
/// top, the entry code beneath it. Tapping opens the linked inspection
/// ([onOpenReport]); with [onOpenReport] null it is plain text (select mode, or
/// no link callback wired). Merging the old entry-code column in here frees a
/// whole column of width for the analysis/result cells.
Widget _sourceEntryCell(Map<String, dynamic> r, {VoidCallback? onOpenReport}) {
  final sourceType = '${r['source_type'] ?? ''}';
  final label =
      '${r['source_name'] ?? '-'}'
      '${sourceType.isEmpty ? '' : ' (${thSourceLabel(sourceType)})'}';
  // The table row reserves a fixed 44px slot (rowHeight 52 − 2×4 vertical
  // padding). Two stacked lines sit right at that limit at the authored text
  // scale, so each line is wrapped in Flexible: when text scale or the window
  // grows the lines compress into the slot instead of overflowing it.
  final code = '${r['entry_code'] ?? ''}'.trim();
  final hasCode = code.isNotEmpty && code != 'null';
  final body = Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Flexible(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      if (hasCode) ...[
        const SizedBox(height: 2),
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.qr_code_2_outlined,
                size: 13,
                color: AppColors.primary,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  code,
                  textDirection: TextDirection.ltr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ],
  );
  if (onOpenReport == null) return body;
  return InkWell(
    onTap: onOpenReport,
    borderRadius: BorderRadius.circular(6),
    child: Tooltip(
      message: AppText.t('فتح المحضر المرتبط', 'Open the linked report'),
      child: body,
    ),
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
    this.onOpenReport,
    this.selecting = false,
    this.selectedIds = const <String>{},
    this.onToggleSelect,
    this.onLongPressRow,
  });

  final List<Map<String, dynamic>> slice;
  final int start;
  final ValueChanged<Map<String, dynamic>>? onOpen;

  /// Opens the inspection (المحضر) linked by a card's entry code.
  final ValueChanged<Map<String, dynamic>>? onOpenReport;

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
      itemBuilder: (context, i) => RepaintBoundary(
        child: TestHistoryCard(
          row: slice[i],
          index: start + i + 1,
          onTap: onOpen == null ? null : () => onOpen!(slice[i]),
          onOpenReport: onOpenReport == null
              ? null
              : () => onOpenReport!(slice[i]),
          selected: selectedIds.contains(thRowKey(slice[i])),
          showSelect: selecting,
          onToggleSelect: onToggleSelect == null
              ? null
              : () => onToggleSelect!(slice[i]),
          onLongPress: onLongPressRow == null
              ? null
              : () => onLongPressRow!(slice[i]),
        ),
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
    this.onOpenReport,
    this.selected = false,
    this.showSelect = false,
    this.onToggleSelect,
    this.onLongPress,
  });

  final Map<String, dynamic> row;
  final int index;
  final VoidCallback? onTap;

  /// Opens the inspection (المحضر) linked by [row]'s entry code.
  final VoidCallback? onOpenReport;
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
      // Dense list card: flat shadow tier on mobile keeps long registers
      // light; the desktop grid keeps the standard lift.
      flat: FormFactor.current.isMobile,
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
                child: _analysisCell(
                  row,
                  nameMaxLines: 2,
                  nameStyle: TextStyle(
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
          _sourceEntryLine(row, onOpenReport: showSelect ? null : onOpenReport),
          const SizedBox(height: AppSpacing.xs),
          _metaLine(
            Icons.schedule_outlined,
            '${thFmtDateTime(row['tested_at'])} • ${row['tested_by_name'] ?? '-'}',
          ),
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

  Future<void> _exportPdf() async {
    if (_printing) return;
    setState(() => _printing = true);
    try {
      await TestHistoryPdf.export(context, widget.rows);
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
          AppButton(
            small: true,
            style: AppButtonStyle.secondary,
            label: AppText.t('PDF', 'PDF'),
            icon: Icon(Icons.picture_as_pdf_outlined, size: 16.r),
            onPressed: _printing ? null : _exportPdf,
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

/// Mobile card line merging the source name (خام/منتج) with the entry code.
/// Tapping it opens the linked inspection (المحضر) — the card's own tap still
/// opens the lab-test detail, so this is a deliberate, labelled link target.
Widget _sourceEntryLine(
  Map<String, dynamic> row, {
  VoidCallback? onOpenReport,
}) {
  final sourceType = '${row['source_type'] ?? ''}';
  final source =
      '${row['source_name'] ?? '-'}'
      '${sourceType.isEmpty ? '' : ' (${thSourceLabel(sourceType)})'}';
  final code = '${row['entry_code'] ?? ''}'.trim();
  final hasCode = code.isNotEmpty && code != 'null';
  final tappable = onOpenReport != null && hasCode;
  final content = Row(
    children: [
      Icon(
        Icons.qr_code_2_outlined,
        size: 15.r,
        color: tappable ? AppColors.primary : AppColors.textMuted,
      ),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          hasCode ? '$source • $code' : source,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.spMax,
            color: tappable ? AppColors.primary : AppColors.textMuted,
            fontWeight: tappable ? FontWeight.w600 : null,
            decoration: tappable ? TextDecoration.underline : null,
          ),
        ),
      ),
    ],
  );
  if (!tappable) return content;
  return InkWell(
    onTap: onOpenReport,
    borderRadius: BorderRadius.circular(6),
    child: Tooltip(
      message: AppText.t('فتح المحضر المرتبط', 'Open the linked report'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: content,
      ),
    ),
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
                        : AppButton(
                            onPressed: () => scope.setPage(p),
                            label: '$p',
                            style: AppButtonStyle.ghost,
                            small: true,
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
  required String reasonState,
  required String recordLimit,
  required ValueChanged<String> onMode,
  required VoidCallback onDate,
  required ValueChanged<String> onAnalysis,
  required ValueChanged<String> onSource,
  required ValueChanged<String> onChemical,
  required ValueChanged<String> onRange,
  required ValueChanged<String> onReason,
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

  return Builder(
    builder: (context) {
      final narrow = FormFactor.current.isMobile;
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
                  suffixIcon: Icon(Icons.calendar_today, size: 16.r),
                ),
                child: Text(specificDate),
              ),
            ),
          ),
        field(
          label: AppText.t('حد السجلات', 'Record limit'),
          child: AppSelectField<String>(
            initialValue: recordLimit,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(),
            items: [
              for (final l in TestHistoryScopeState.recordLimits)
                DropdownMenuItem(value: l, child: Text(l)),
            ],
            onChanged: (v) => onLimit(v ?? recordLimit),
          ),
        ),
        field(
          label: AppText.t('التحليل', 'Analysis'),
          child: AppSelectField<String>(
            initialValue: analysisId,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(),
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
          child: AppSelectField<String>(
            initialValue: sourceType,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(),
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
              DropdownMenuItem(
                value: 'sample',
                child: Text(AppText.t('عينة جديدة', 'New sample')),
              ),
            ],
            onChanged: (v) => onSource(v ?? ''),
          ),
        ),
        field(
          label: AppText.t('المواد المستهلكة', 'Consumables'),
          child: AppSelectField<String>(
            initialValue: chemicalId,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(),
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
          label: AppText.t('سبب القرار', 'Decision reason'),
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: Text(AppText.t('الكل', 'All')),
                selected: reasonState.isEmpty,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => onReason(''),
              ),
              ChoiceChip(
                label: Text(AppText.t('فيها سبب فقط', 'With reason only')),
                selected: reasonState == 'has',
                visualDensity: VisualDensity.compact,
                onSelected: (_) => onReason('has'),
              ),
            ],
          ),
        ),
        field(
          label: AppText.t('الحالة', 'Range state'),
          child: AppSelectField<String>(
            initialValue: rangeState,
            isExpanded: true,
            menuMaxHeight: 320,
            decoration: const InputDecoration(),
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
