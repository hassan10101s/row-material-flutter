import 'package:flutter/widgets.dart';

/// Layout breakpoints, in logical pixels.
///
/// ## These are *not* how the form factor is decided
///
/// [AppBreakpoints] exists to lay a **single** experience out across the widths
/// it can end up at: how many cards fit side by side, whether a filter row
/// becomes a wrap, how wide a dialog may be. The choice of *which experience*
/// to build is made by `FormFactor` in `core/responsive/`, from the platform.
///
/// That separation is deliberate. Deriving the form factor from width would
/// mean a snapped desktop window got the phone grid, because
/// `ScreenUtilInit.designSize` is a process-wide singleton - see
/// `FormFactor.resolve`.
///
/// ## History
///
/// The app had five unrelated magic numbers (600 / 700 / 720 / 760 / 900)
/// spread across `app_shell`, `dashboard_screen`, `inspections_screen`,
/// `inspection_detail_screen`, `inspection_form_screen` and `test_history_tab`,
/// each picking its own threshold for what is really one responsive shell.
/// This file already existed to replace them but had **zero importers**, so it
/// was documentation pretending to be code. It now holds the values and the
/// call sites use them.
abstract final class AppBreakpoints {
  /// Below this, content stacks in a single column and a data surface is a
  /// card list rather than a table.
  static const double compact = 600;

  /// At or above this there is room for a persistent side rail next to the
  /// content. The former hard-coded `720` in `app_shell`.
  static const double medium = 720;

  /// At or above this, data surfaces and two-column detail pages can use the
  /// extra room. The former `760` in `inspections_screen` / `test_history_tab`
  /// and the former `900` in `inspection_detail_screen`.
  static const double expanded = 1024;

  /// At or above this the widest layouts (multi-column forms, wide filters) are
  /// allowed. New in this revision - it is where `inspection_form_screen` puts
  /// its side-by-side parameter grid.
  static const double large = 1200;

  /// Convenience predicates over a [BuildContext].
  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compact;

  static bool isMedium(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width >= compact && width < expanded;
  }

  static bool isExpanded(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= expanded;

  /// True when [availableWidth] can fit [columns] side by side without any of
  /// them dropping below [minColumnWidth].
  ///
  /// Takes the width as a parameter rather than reading `MediaQuery` because
  /// the call sites sit inside a `LayoutBuilder`, where `constraints.maxWidth`
  /// is the *local* width - it can be narrower than the window, and using the
  /// window there is how a widget ends up laying out for space it was not
  /// given.
  static bool fitsColumnsIn({
    required double availableWidth,
    required int columns,
    double minColumnWidth = 260,
    double gap = 16,
  }) {
    if (columns <= 1) return true;
    final needed = columns * minColumnWidth + (columns - 1) * gap;
    return availableWidth >= needed;
  }

  /// [fitsColumnsIn] against the window width, for call sites that are not
  /// already inside a `LayoutBuilder`.
  static bool fitsColumns(
    BuildContext context, {
    required int columns,
    double minColumnWidth = 260,
    double gap = 16,
  }) => fitsColumnsIn(
    availableWidth: MediaQuery.sizeOf(context).width,
    columns: columns,
    minColumnWidth: minColumnWidth,
    gap: gap,
  );
}
