import 'package:flutter/widgets.dart';

/// Layout breakpoints, in logical pixels.
///
/// The app had five unrelated magic numbers (600 / 700 / 720 / 760 / 900)
/// spread across `app_shell`, `dashboard_screen`, `inspections_screen`,
/// `inspection_detail_screen` and `test_history_tab`, each picking its own
/// threshold for what is really one responsive shell. These replace them.
///
/// Use with `MediaQuery.sizeOf(context).width >= AppBreakpoints.medium` or
/// `LayoutBuilder`; prefer [AppBreakpoints.of] when a bare comparison is
/// enough.
class AppBreakpoints {
  /// Below this the shell collapses to a drawer and content stacks in one
  /// column. Designed for phones.
  static const double compact = 600;

  /// At or above this the persistent navigation rail/drawer is shown. The
  /// former 720 threshold in `app_shell`.
  static const double medium = 720;

  /// At or above this the rail expands to its full width and data surfaces
  /// (tables, two-column detail pages) can use the extra room. The former 900
  /// threshold in `inspections_screen` / `test_history_tab`.
  static const double expanded = 1024;

  /// Convenience predicates over a [BuildContext].
  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).width < compact;

  static bool isMedium(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width >= medium && width < expanded;
  }

  static bool isExpanded(BuildContext context) =>
      MediaQuery.sizeOf(context).width >= expanded;
}
