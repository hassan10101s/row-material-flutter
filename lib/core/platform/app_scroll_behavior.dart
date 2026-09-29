import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Scroll behaviour for a mouse-and-keyboard desktop app.
///
/// The default [MaterialScrollBehavior] is written for touch, and it shows on
/// desktop in two ways:
///
///  * No drag-to-scroll. A trackpad or mouse user who grabs the content cannot
///    scroll it, which is the gesture the OS itself uses for this.
///  * The overscroll "glow" is drawn on the top and bottom edges. That is the
///    Android stretch indicator leaking onto a Windows app.
///
/// Mouse wheel scrolling and the scrollbar are left alone; only the touch-only
/// affordances are replaced. Applied through `MaterialApp.scrollBehavior`; a
/// [ScrollConfiguration] wrapper would be redundant.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    // Replaced rather than removed outright: the content still clips and
    // absorbs overscroll gestures, it just no longer paints the touch glow.
    return child;
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();
}
