import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/responsive/form_factor.dart';
import '../../core/responsive/layout_spec.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../animations/app_animations.dart';
import 'app_adaptive.dart';
import 'app_card.dart';
import 'app_empty_state.dart';
import 'app_paginated_table.dart';

/// One row, described once, for both experiences.
///
/// The point of this type is that a data screen does **not** have to own two
/// renderings of its own data. It describes each row once - a primary line, an
/// optional secondary line, and any number of trailing facts - and
/// [AppAdaptiveDataView] decides whether that becomes a table row or a card.
class AppDataRow {
  const AppDataRow({
    required this.cells,
    this.secondary,
    this.onTap,
  });

  /// The cells, in the same order as the table's headers. Index 0 is the
  /// primary line; on a card it becomes the title.
  final List<Widget> cells;

  /// A muted second line, shown under [cells] on a card. Ignored by the table,
  /// which has a row to itself.
  final String? secondary;

  final VoidCallback? onTap;
}

/// Renders [rows] as a table on desktop and as a card list on mobile.
///
/// Set [cardsOnly] to always render the card list (unified mobile logic on
/// every form factor). Callers constrain the width on wide screens.
class AppAdaptiveDataView extends StatefulWidget {
  const AppAdaptiveDataView({
    super.key,
    required this.headers,
    required this.rows,
    this.onRowTap,
    this.rowsPerPage = 10,
    this.columnFlex,
    this.empty,
    this.totalLabel,
    this.loading = false,
    this.headerTrailing,
    this.cardsOnly = false,
  });

  final List<String> headers;
  final List<AppDataRow> rows;
  final void Function(int index)? onRowTap;
  final int rowsPerPage;
  final List<double>? columnFlex;
  final Widget? empty;
  final String? totalLabel;
  final bool loading;
  final Widget? headerTrailing;

  /// Cards on desktop too — the table variant is skipped.
  final bool cardsOnly;

  @override
  State<AppAdaptiveDataView> createState() => _AppAdaptiveDataViewState();
}

class _AppAdaptiveDataViewState extends State<AppAdaptiveDataView> {
  @override
  Widget build(BuildContext context) {
    if (widget.cardsOnly) return _buildMobile(context);
    return appAdaptiveVariant(
      context,
      desktop: _buildDesktop,
      mobile: _buildMobile,
    );
  }

  /// Byte-for-byte the pre-split surface: same widget, same defaults.
  Widget _buildDesktop(BuildContext context) {
    return AppPaginatedTable(
      headers: widget.headers,
      rows: [
        for (final row in widget.rows) row.cells,
      ],
      onRowTap: widget.onRowTap,
      rowsPerPage: widget.rowsPerPage,
      columnFlex: widget.columnFlex,
      empty: widget.empty,
      totalLabel: widget.totalLabel,
      loading: widget.loading,
      headerTrailing: widget.headerTrailing,
    );
  }

  Widget _buildMobile(BuildContext context) {
    if (widget.loading) return const _CardListSkeleton();
    if (widget.rows.isEmpty) {
      return AppCard(
        padding: EdgeInsets.zero,
        // Compact min-height for phones: the old fixed 470dp filled a
        // desktop-sized card on a 400dp phone. ConstrainedBox lets taller
        // content grow while short empty states stay compact.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 240),
          child: Center(
            child: widget.empty ??
                AppEmptyState(
                  icon: Icons.inbox_outlined,
                  title: appTextOf(context, 'لا توجد بيانات', 'No data'),
                ),
          ),
        ),
      );
    }
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: widget.rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final row = widget.rows[index];
                final tap = widget.onRowTap == null
                    ? null
                    : () => widget.onRowTap!(index);
                return InkWell(
                  onTap: tap ?? row.onTap,
                  child: _DataCard(row: row, headers: widget.headers),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// One row as a card: the primary cell on top, the rest as label/value facts.
class _DataCard extends StatelessWidget {
  const _DataCard({required this.row, required this.headers});

  final AppDataRow row;
  final List<String> headers;

  @override
  Widget build(BuildContext context) {
    final primary = row.cells.isEmpty ? const SizedBox.shrink() : row.cells.first;
    final facts = <({String label, Widget value})>[];
    for (var i = 1; i < row.cells.length && i < headers.length; i++) {
      facts.add((label: headers[i], value: row.cells[i]));
    }
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.surfaceSoft.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.borderMuted),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DefaultTextStyle(
              style: TextStyle(
                fontSize: 14.spMax,
                fontWeight: FontWeight.w800,
                height: 1.3,
                color: AppColors.textStrong,
              ),
              child: primary,
            ),
          if (row.secondary != null) ...[
            const SizedBox(height: 2),
            Text(
              row.secondary!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.spMax, color: AppColors.textMuted),
            ),
          ],
          for (final fact in facts)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 108,
                    child: Text(
                      fact.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.spMax,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                  Expanded(child: DefaultTextStyle.merge(
                    style: TextStyle(
                      fontSize: 12.5.spMax,
                      height: 1.4,
                      color: AppColors.textStrong,
                    ),
                    child: fact.value,
                  )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CardListSkeleton extends StatelessWidget {
  const _CardListSkeleton();

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      // Bounded height (not minHeight): AppShimmer's ShaderMask needs a
      // finite box. 320dp is compact on a 400dp phone vs the old 470dp
      // desktop-sized card, while staying bounded for the shimmer.
      child: SizedBox(
        height: 320,
        child: AppShimmer(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            itemCount: 5,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Container(
                height: 56,
                decoration: BoxDecoration(
                  color: AppColors.borderMuted,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// True when the current experience can render a data table at all. Use this to
/// decide whether a table-specific affordance (a sort header, a column menu)
/// is worth offering, not to branch layout - [AppAdaptiveDataView] does that.
bool get supportsDataTable => LayoutSpec.of(FormFactor.current).supportsTable;