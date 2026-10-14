import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/app_strings.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// Default page size for mobile infinite lists.
///
/// Desktop tables keep `kDefaultPageSize` (200); a phone card list feels
/// sluggish and jumps on rotation with pages that large. 25 cards ≈ 2-3
/// screens, cheap SQLite `LIMIT/OFFSET` scans, smooth append.
const int kMobilePageSize = 25;

/// Distance from the bottom that triggers an automatic `onLoadMore`.
const double kInfiniteAutoLoadThreshold = 300;

/// Footer for an infinite list: spinner while appending, retry on error,
/// explicit "load more" button as fallback (no auto-load / a11y), and an
/// end-of-list label so the user knows the register is complete.
///
/// Ported from `QcInspectionsScreen._LoadMoreRow` into the design system so
/// every mobile list shares one surface.
class AppLoadMoreFooter extends StatelessWidget {
  const AppLoadMoreFooter({
    super.key,
    required this.hasMore,
    this.loadingMore = false,
    this.errorMore,
    this.onLoadMore,
    this.onRetry,
    this.totalLabel,
  });

  final bool hasMore;
  final bool loadingMore;
  final String? errorMore;
  final VoidCallback? onLoadMore;
  final VoidCallback? onRetry;
  final String? totalLabel;

  @override
  Widget build(BuildContext context) {
    if (errorMore != null && errorMore!.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                errorMore!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.danger,
                  fontSize: 12.spMax,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            TextButton.icon(
              onPressed: onRetry ?? onLoadMore,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(AppText.t('إعادة المحاولة', 'Retry')),
            ),
          ],
        ),
      );
    }
    if (loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Center(
          child: TextButton(
            onPressed: onLoadMore,
            child: Text(AppText.t('المزيد', 'Load more')),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Text(
          totalLabel ?? AppText.t('نهاية القائمة', 'End of list'),
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.spMax),
        ),
      ),
    );
  }
}

/// Mobile infinite card list.
///
/// Wraps `ListView.separated` with:
/// * an owned (or externally supplied) [ScrollController] that auto-fires
///   [onLoadMore] when the scroll lands within [autoLoadThreshold] of the
///   bottom — guarded by `hasMore && !loadingMore`;
/// * a trailing [AppLoadMoreFooter] item so the end-of-list state is always
///   visible, even when auto-load is disabled or fails;
/// * `AlwaysScrollableScrollPhysics` by default so a parent
///   `RefreshIndicator` can always be pulled, even on a short list.
class AppInfiniteList extends StatefulWidget {
  const AppInfiniteList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.separator = const SizedBox(height: AppSpacing.md),
    this.hasMore = false,
    this.loadingMore = false,
    this.errorMore,
    this.onLoadMore,
    this.onRetry,
    this.totalLabel,
    this.controller,
    this.padding = const EdgeInsets.all(AppSpacing.pageMobile),
    this.physics = const AlwaysScrollableScrollPhysics(),
    this.shrinkWrap = false,
    this.autoLoadThreshold = kInfiniteAutoLoadThreshold,
    this.autoLoad = true,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final Widget separator;
  final bool hasMore;
  final bool loadingMore;
  final String? errorMore;
  final VoidCallback? onLoadMore;
  final VoidCallback? onRetry;
  final String? totalLabel;
  final ScrollController? controller;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics physics;
  final bool shrinkWrap;
  final double autoLoadThreshold;
  final bool autoLoad;

  @override
  State<AppInfiniteList> createState() => _AppInfiniteListState();
}

class _AppInfiniteListState extends State<AppInfiniteList> {
  ScrollController? _owned;
  ScrollController get _controller => widget.controller ?? _owned!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) _owned = ScrollController();
    _controller.addListener(_maybeAutoLoad);
  }

  @override
  void didUpdateWidget(AppInfiniteList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_maybeAutoLoad);
      if (oldWidget.controller == null) {
        _owned?.dispose();
        _owned = null;
      }
      if (widget.controller == null) _owned ??= ScrollController();
      _controller.addListener(_maybeAutoLoad);
    }
  }

  void _maybeAutoLoad() {
    if (!widget.autoLoad || widget.onLoadMore == null) return;
    if (!widget.hasMore || widget.loadingMore) return;
    if (!_controller.hasClients) return;
    final pos = _controller.position;
    if (pos.maxScrollExtent - pos.pixels <= widget.autoLoadThreshold) {
      widget.onLoadMore!();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_maybeAutoLoad);
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      controller: _controller,
      physics: widget.physics,
      shrinkWrap: widget.shrinkWrap,
      padding: widget.padding,
      itemCount: widget.itemCount + 1,
      separatorBuilder: (_, _) => widget.separator,
      itemBuilder: (context, i) {
        if (i == widget.itemCount) {
          return AppLoadMoreFooter(
            hasMore: widget.hasMore,
            loadingMore: widget.loadingMore,
            errorMore: widget.errorMore,
            onLoadMore: widget.onLoadMore,
            onRetry: widget.onRetry ?? widget.onLoadMore,
            totalLabel: widget.totalLabel,
          );
        }
        return widget.itemBuilder(context, i);
      },
    );
  }
}

/// Sliver variant for `CustomScrollView` screens with a sticky search header.
///
/// Use when the screen already owns a `CustomScrollView` (sticky filter bar
/// via `SliverPersistentHeader`): this delegate renders the paged cards as
/// slivers plus the same footer states as [AppLoadMoreFooter].
class SliverInfiniteCards extends StatelessWidget {
  const SliverInfiniteCards({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.hasMore = false,
    this.loadingMore = false,
    this.errorMore,
    this.onLoadMore,
    this.onRetry,
    this.totalLabel,
  });

  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final bool hasMore;
  final bool loadingMore;
  final String? errorMore;
  final VoidCallback? onLoadMore;
  final VoidCallback? onRetry;
  final String? totalLabel;

  @override
  Widget build(BuildContext context) {
    return SliverMainAxisGroup(
      slivers: [
        SliverList.separated(
          itemCount: itemCount,
          separatorBuilder: (_, _) =>
              const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.md)),
          itemBuilder: itemBuilder,
        ),
        SliverToBoxAdapter(
          child: AppLoadMoreFooter(
            hasMore: hasMore,
            loadingMore: loadingMore,
            errorMore: errorMore,
            onLoadMore: onLoadMore,
            onRetry: onRetry ?? onLoadMore,
            totalLabel: totalLabel,
          ),
        ),
      ],
    );
  }
}

/// Desktop "showing N of M" footer for tables fed by append-model cubits.
///
/// Desktop tables page client-side over the loaded rows; this footer tells
/// the user how many rows are loaded out of the filtered total and offers
/// the next page — the desktop counterpart of infinite scroll.
class AppDesktopLoadMore extends StatelessWidget {
  const AppDesktopLoadMore({
    super.key,
    required this.loaded,
    required this.total,
    required this.hasMore,
    this.loadingMore = false,
    this.errorMore,
    this.onLoadMore,
    this.onRetry,
  });

  final int loaded;
  final int total;
  final bool hasMore;
  final bool loadingMore;
  final String? errorMore;
  final VoidCallback? onLoadMore;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$loaded ${AppText.t('من', 'of')} $total',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.spMax,
                color: AppColors.textMuted,
              ),
            ),
          ),
          if (loadingMore)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (errorMore != null && errorMore!.isNotEmpty)
            TextButton.icon(
              onPressed: onRetry ?? onLoadMore,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(AppText.t('إعادة المحاولة', 'Retry')),
            )
          else if (hasMore)
            OutlinedButton.icon(
              onPressed: onLoadMore,
              icon: const Icon(Icons.expand_more),
              label: Text(AppText.t('عرض المزيد', 'Show more')),
            )
          else
            Text(
              AppText.t('نهاية القائمة', 'End of list'),
              style: TextStyle(
                fontSize: 12.spMax,
                color: AppColors.textMuted,
              ),
            ),
        ],
      ),
    );
  }
}

/// Pinned header delegate for sticky search/filter bars on mobile lists.
///
/// Ports the dashboard `_StickyNavBar` recipe: a slim pinned row that stays
/// visible while cards scroll underneath.
class AppStickyHeaderDelegate extends SliverPersistentHeaderDelegate {
  AppStickyHeaderDelegate({
    required this.child,
    this.minHeight = 64,
    this.maxHeight = 76,
  });

  final Widget child;
  final double minHeight;
  final double maxHeight;

  @override
  double get minExtent => minHeight;

  @override
  double get maxExtent => maxHeight;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pageMobile,
        AppSpacing.sm,
        AppSpacing.pageMobile,
        AppSpacing.sm,
      ),
      child: child,
    );
  }

  @override
  bool shouldRebuild(AppStickyHeaderDelegate oldDelegate) =>
      oldDelegate.child != child ||
      oldDelegate.minHeight != minHeight ||
      oldDelegate.maxHeight != maxHeight;
}
