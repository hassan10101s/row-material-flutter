import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../animations/app_animations.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_card.dart';

/// Shimmering placeholder box.
class AppSkeleton extends StatelessWidget {
  final double? width;
  final double? height;
  final double radius;

  const AppSkeleton({
    super.key,
    this.width,
    this.height,
    this.radius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return AppShimmer(
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: AppColors.borderMuted,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );
  }
}

/// A single skeleton line (title or body text).
class AppSkeletonLine extends StatelessWidget {
  final double width;
  final double height;
  const AppSkeletonLine({super.key, this.width = 140, this.height = 14});

  @override
  Widget build(BuildContext context) =>
      AppSkeleton(width: width, height: height, radius: height / 2);
}

/// A skeleton list/table filler used while data is loading.
class AppSkeletonList extends StatelessWidget {
  final int rows;
  final int lines;
  final double height;
  final EdgeInsets padding;

  const AppSkeletonList({
    super.key,
    this.rows = 6,
    this.lines = 3,
    this.height = 420,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: padding,
          // Inside the fixed box only as many rows are rendered as actually
          // fit: a caller asking for 6 rows inside a 96-120dp strip used to
          // overflow the stretched Column (the inspections mobile skeleton).
          child: LayoutBuilder(
            builder: (context, constraints) {
              final boxHeight =
                  constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : height - padding.vertical;
              // Header block: 36dp avatar tile + one lg gap below it.
              const headerBlock = 36 + AppSpacing.lg;
              // One row block = the tallest line variant (14dp) + its bottom
              // md spacer.
              const perRow = 14 + AppSpacing.md;
              // A very short strip (e.g. the 64dp routine sheet uses minus
              // the card padding leaves 32dp) cannot hold the header at all:
              // the header would overflow by 20dp no matter how the row
              // count is clamped. So a header is only laid out when room
              // besides it remains for at least one row; otherwise the strip
              // degrades into bare lines filling the whole height.
              final withHeader = boxHeight - headerBlock - 1 >= perRow;
              final available = boxHeight - (withHeader ? headerBlock : 0);
              final shown = (available / perRow).floor().clamp(0, rows);
              final linesShown = math.min(lines, 6);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (withHeader) ...[
                    Row(
                      children: [
                        AppSkeleton(width: 36, height: 36, radius: 18),
                        const SizedBox(width: AppSpacing.md),
                        AppSkeletonLine(width: 160, height: 18),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                  const SizedBox(height: 1),
                  for (var i = 0; i < shown; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.md),
                      child: Row(
                        children: [
                          for (var l = 0; l < linesShown; l++)
                            Expanded(
                              child: Padding(
                                // RTL-aware: mirrors to the text direction.
                                padding: EdgeInsetsDirectional.only(
                                  start: l == 0 ? 0 : AppSpacing.md,
                                ),
                                child: AppSkeletonLine(
                                    width: double.infinity,
                                    height: i.isEven ? 14 : 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A 2px progress bar for a *refresh* — a load that already has data on screen.
///
/// Screens used to swap their whole body for a centred
/// [CircularProgressIndicator] whenever their cubit reported `loading: true`.
/// [AppPage] adds no overlay of its own, so that swap replaced the entire
/// content panel and read as "the whole program is loading" every time a tab
/// was opened.
///
/// The replacement is a two-state pattern, applied uniformly:
///
///  * **first load** (`loading` and nothing to show yet) — an [AppSkeletonList]
///    stands in for the data area, while the shell, filters and buttons stay
///    put and usable, so the app never looks frozen;
///  * **refresh** (`loading` with data already present) — the stale content
///    stays on screen and interactive, with this bar as the only progress cue.
///
/// Pair it with a `hasData` check against real content, e.g.
/// `loading && rows.isEmpty`, otherwise a refresh blanks the screen again.
class AppRefreshBar extends StatelessWidget {
  const AppRefreshBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: LinearProgressIndicator(
        minHeight: 2,
        backgroundColor: Colors.transparent,
        color: AppColors.primary,
      ),
    );
  }
}

const EdgeInsets zero = EdgeInsets.zero;