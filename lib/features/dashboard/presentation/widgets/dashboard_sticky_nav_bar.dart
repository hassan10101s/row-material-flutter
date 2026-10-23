import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_lab/core/l10n/app_localizations_x.dart';

import '../../../../core/constants/app_strings.dart';
import '../../../../design_system/tokens/app_colors.dart';

class DashboardStickyNavBar extends SliverPersistentHeaderDelegate {
  final ValueChanged<String> onGo;
  final double topPadding;
  final String period;
  final ValueChanged<String> onPeriodChange;
  final int filterCount;
  final VoidCallback onOpenFilter;
  final Future<void> Function() onRefresh;
  final bool refreshing;

  /// Max text scale used inside the bar (system textScaler effectively
  /// reaches both rows' chips/labels). The extent grows with it so large
  /// accessibility settings can never overflow the pinned header.
  final double textScale;
  const DashboardStickyNavBar({
    required this.onGo,
    required this.topPadding,
    required this.period,
    required this.onPeriodChange,
    required this.filterCount,
    required this.onOpenFilter,
    required this.onRefresh,
    required this.refreshing,
    this.textScale = 1.0,
  });

  // Content window: two compact rows (controls, then section nav) plus
  // container padding.
  //
  // The child MUST fill the extent exactly. A pinned header reports
  // `paintExtent = min(childExtent, remaining)` against
  // `layoutExtent = maxExtent`: when the content sizes itself smaller than
  // the extent the geometry goes invalid
  // (`layoutExtent > paintExtent`) and crashes the whole viewport.
  // The `SizedBox` below pins the child to [contentExtent] so the geometry is
  // valid at every text scale; leftover space is plain header background.
  static const double _rowBase = 34;
  static const double _rowGap = 8;
  static const double _verticalPadding = 12;

  double get _scaledRow => _rowBase * textScale.clamp(1.0, 1.3);

  /// Fixed extent for the current text scale: content height plus a little
  /// breathing room when fonts run large. Never changes with scroll, so the
  /// pinned geometry stays exact (crash-history constraint).
  double get contentExtent =>
      topPadding + _verticalPadding + _scaledRow * 2 + _rowGap + 6;

  @override
  double get minExtent => contentExtent;
  @override
  double get maxExtent => contentExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final sections = <(String, String, IconData)>[
      ('overview', AppText.t('الوضع', 'Overview'), Icons.grid_view_outlined),
      (
        'suppliers',
        AppText.t('الموردين', 'Suppliers'),
        Icons.local_shipping_outlined,
      ),
      ('rejections', AppText.t('الرفض', 'Rejects'), Icons.bar_chart_outlined),
      ('trend', AppText.t('الاتجاه', 'Trend'), Icons.show_chart),
      ('outlook', AppText.t('التوقع', 'Outlook'), Icons.auto_graph_outlined),
      ('quality', AppText.t('الجودة', 'Quality'), Icons.verified_outlined),
      ('stock', AppText.t('المخزون', 'Stock'), Icons.inventory_2_outlined),
    ];
    final periods = <(String, String)>[
      ('7d', context.l10n.period_week),
      ('30d', context.l10n.period_month),
      ('90d', context.l10n.period_3months),
      ('365d', context.l10n.period_year),
      ('ALL', context.l10n.period_all),
    ];
    return SizedBox(
      height: contentExtent,
      width: double.infinity,
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        padding: EdgeInsets.fromLTRB(topPadding, 6, topPadding, 6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.borderMuted),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Row 1 — every control in one place: months, filter, actions.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final p in periods)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(
                            p.$2,
                            style: TextStyle(fontSize: 12.spMax),
                          ),
                          selected: period == p.$1,
                          onSelected: (_) => onPeriodChange(p.$1),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    Badge(
                      isLabelVisible: filterCount > 0,
                      label: Text('$filterCount'),
                      child: IconButton.filledTonal(
                        tooltip: AppText.t('الفلاتر', 'Filters'),
                        onPressed: onOpenFilter,
                        icon: Icon(Icons.filter_alt_outlined, size: 20.r),
                      ),
                    ),
                    const SizedBox(width: 6),
                    refreshing
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: SizedBox(
                              width: 20.r,
                              height: 20.r,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: AppColors.primary,
                              ),
                            ),
                          )
                        : IconButton.filledTonal(
                            tooltip: AppText.t('تحديث', 'Refresh'),
                            onPressed: onRefresh,
                            icon: Icon(Icons.refresh, size: 20.r),
                          ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              // Row 2 — section navigation.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final s in sections)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          avatar: Icon(s.$3, size: 14.r),
                          label: Text(
                            s.$2,
                            style: TextStyle(fontSize: 11.5.spMax),
                          ),
                          onPressed: () => onGo(s.$1),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant DashboardStickyNavBar old) =>
      old.topPadding != topPadding ||
      old.period != period ||
      old.refreshing != refreshing ||
      old.filterCount != filterCount ||
      old.textScale != textScale;
}

/// Status label shared by the filter sheet (the inline card is gone: the
/// three dropdowns live in the sheet now).
