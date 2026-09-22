import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_card.dart';
import 'app_empty_state.dart';

/// Data table with a pinned header, vertical scrolling body, optional
/// horizontal scroll and built-in pagination.
class AppPaginatedTable extends StatefulWidget {
  final List<String> headers;
  final List<List<Widget>> rows;
  final void Function(int index)? onRowTap;
  final int rowsPerPage;
  final double tableWidth;
  final double height;
  final Widget? empty;
  final String? totalLabel;
  final bool loading;
  final Widget? headerTrailing;

  const AppPaginatedTable({
    super.key,
    required this.headers,
    required this.rows,
    this.onRowTap,
    this.rowsPerPage = 10,
    this.tableWidth = 920,
    this.height = 470,
    this.empty,
    this.totalLabel,
    this.loading = false,
    this.headerTrailing,
  });

  @override
  State<AppPaginatedTable> createState() => _AppPaginatedTableState();
}

class _AppPaginatedTableState extends State<AppPaginatedTable> {
  int _page = 0;

  int get _pageCount =>
      (widget.rows.length / widget.rowsPerPage).ceil().clamp(1, 1 << 31);

  int get _effectivePage =>
      _page.clamp(0, _pageCount - 1);

  void _changePage(int delta) {
    setState(() => _page = (_effectivePage + delta).clamp(0, _pageCount - 1));
  }

  @override
  Widget build(BuildContext context) {
    final leftIndex = _effectivePage * widget.rowsPerPage;
    final pageRows = leftIndex >= widget.rows.length
        ? const <List<Widget>>[]
        : widget.rows.sublist(
            leftIndex,
            (leftIndex + widget.rowsPerPage).clamp(0, widget.rows.length),
          );
    final colWidth = widget.tableWidth / widget.headers.length;

    return AppCard(
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: widget.height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, colWidth),
            const Divider(height: 1),
            Expanded(
              child: ClipRect(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: widget.tableWidth,
                    child: widget.loading
                        ? _loadingBody()
                        : pageRows.isEmpty
                            ? _emptyBody()
                            : ListView.builder(
                                padding: EdgeInsets.zero,
                                itemCount: pageRows.length,
                                itemExtent: 52,
                                itemBuilder: (context, index) {
                                  final row = pageRows[index];
                                  final realIndex = leftIndex + index;
                                  return _dataRow(context, colWidth, row,
                                      realIndex: realIndex);
                                },
                              ),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            _footer(context, widget.rows.length),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, double colWidth) {
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      color: AppColors.surfaceSoft,
      child: Row(
        children: [
          for (final h in widget.headers)
            SizedBox(
              width: colWidth,
              child: Padding(
                padding: const EdgeInsets.only(
                    right: AppSpacing.sm, left: AppSpacing.sm),
                child: Text(
                  h,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ),
          if (widget.headerTrailing != null) widget.headerTrailing!,
        ],
      ),
    );
  }

  Widget _dataRow(
      BuildContext context, double colWidth, List<Widget> row,
      {required int realIndex}) {
    return InkWell(
      onTap: widget.onRowTap == null ? null : () => widget.onRowTap!(realIndex),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: [
              for (final cell in row)
                SizedBox(
                  width: colWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm, vertical: 4),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: cell,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loadingBody() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      itemCount: (widget.height / 52).floor().clamp(3, 10),
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Container(
          height: 14,
          decoration: BoxDecoration(
            color: AppColors.borderMuted,
            borderRadius: BorderRadius.circular(7),
          ),
        ),
      ),
    );
  }

  Widget _emptyBody() {
    return Center(
      child: widget.empty ??
          AppEmptyState(
            icon: Icons.inbox_outlined,
            title: 'لا توجد بيانات | No data',
          ),
    );
  }

  Widget _footer(BuildContext context, int total) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      color: AppColors.surfaceSoft,
      child: Row(
        children: [
          Text(
            widget.totalLabel ??
                '$pageRowsLength ${appTextOf(context, 'من', 'of')} $total',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
          const Spacer(),
          IconButton(
            tooltip: appTextOf(context, 'السابق', 'Previous'),
            onPressed: _effectivePage > 0 ? () => _changePage(-1) : null,
            icon: const Icon(Icons.chevron_left),
            visualDensity: VisualDensity.compact,
          ),
          Text(
            '${_effectivePage + 1} ${appTextOf(context, 'من', 'of')} $_pageCount',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
          ),
          IconButton(
            tooltip: appTextOf(context, 'التالي', 'Next'),
            onPressed: _effectivePage < _pageCount - 1 ? () => _changePage(1) : null,
            icon: const Icon(Icons.chevron_right),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  int get pageRowsLength {
    final left = _effectivePage * widget.rowsPerPage;
    if (left >= widget.rows.length) return 0;
    return (widget.rows.length - left).clamp(0, widget.rowsPerPage);
  }
}

/// Minimal localization helper for pagination chrome.
String appTextOf(BuildContext context, String ar, String en) =>
    Localizations.maybeLocaleOf(context)?.languageCode == 'ar' ? ar : en;