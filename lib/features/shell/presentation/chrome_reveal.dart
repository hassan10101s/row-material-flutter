import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Scroll-driven reveal state for the phone shell's chrome.
///
/// Vertical scroll notifications bubble up out of any scrollable inside the
/// shell body - `ListView`, `CustomScrollView`, `AppInfiniteList`, sheets and
/// dashboards alike - so one controller covers every screen without any of
/// them wiring a scroll controller. Horizontal scrollers (filter chip rows,
/// the bento band) are filtered out by axis direction.
///
/// Two inputs drive [visible]:
///  * scroll gestures - scrolling down conceals after a little travel, while
///    scrolling up, or pulling the content down past the top edge (the same
///    gesture that feeds pull-to-refresh), reveals again;
///  * [forced], which the shell raises while its drawer is open so the chrome
///    slides back in instead of animating under the drawer scrim.
class ChromeVisibilityController extends ChangeNotifier {
  ChromeVisibilityController() : _scrollVisible = true;

  /// Downward travel past the top edge required before a scroll conceals the
  /// chrome, so a small rest-drag at the very top of a list does not blink
  /// the bars away.
  static const double _concealAfter = 24;

  bool _scrollVisible;
  bool _forced = false;

  bool get visible => _scrollVisible || _forced;

  set forced(bool value) {
    if (_forced == value) return;
    _forced = value;
    notifyListeners();
  }

  /// Reveals the chrome - used when a navigation lands a fresh page whose
  /// scroll starts at the top.
  void reveal() => _apply(true);

  /// Consumes vertical scroll notifications. Always returns `false` so the
  /// notification keeps bubbling to ancestor listeners.
  bool handleScrollNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    final isVertical =
        metrics.axisDirection == AxisDirection.down ||
        metrics.axisDirection == AxisDirection.up;
    if (!isVertical) return false;

    var next = _scrollVisible;
    // Direction notifications arrive when a gesture starts, often at offset
    // zero. Check actual travel too, once the drag crosses the threshold.
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final delta = notification.scrollDelta ?? 0;
      if (delta > 0 &&
          metrics.pixels > metrics.minScrollExtent + _concealAfter) {
        next = false;
      } else if (delta < 0) {
        next = true;
      }
    }
    if (notification is UserScrollNotification) {
      if (notification.direction == ScrollDirection.reverse &&
          metrics.pixels > metrics.minScrollExtent + _concealAfter) {
        next = false;
      } else if (notification.direction == ScrollDirection.forward) {
        next = true;
      }
    }
    // Dragging or rubber-banding the content downward at the top edge always
    // reveals, even mid-gesture that had concealed - hiding chrome while the
    // user fights their way back up would read as broken, not tidy.
    if (metrics.pixels <= metrics.minScrollExtent) {
      if (notification is OverscrollNotification &&
          notification.overscroll < 0) {
        next = true;
      } else if (notification is ScrollUpdateNotification &&
          notification.dragDetails != null &&
          (notification.scrollDelta ?? 0) < 0) {
        next = true;
      }
    }
    _apply(next);
    return false;
  }

  void _apply(bool value) {
    if (_scrollVisible == value) return;
    _scrollVisible = value;
    notifyListeners();
  }
}

/// Which edge of the screen a [ChromeReveal] folds its child toward.
enum ChromeRevealEdge { top, bottom }

/// Folds its child away toward [edge] while hidden, and back out on reveal.
///
/// The child is **always built and laid out**: a `ClipRect` plus an animated
/// `heightFactor` shrink the visible box while a matching fractional
/// translation slides the child out along the same edge, so widget state,
/// keys and finders all survive the hidden state - and a caller that never
/// scrolls simply sees the chrome as it is.
///
/// A zero [duration] (as reduced motion resolves to through `AppMotion.of`)
/// collapses instantly.
class ChromeReveal extends StatefulWidget {
  const ChromeReveal({
    super.key,
    required this.visible,
    required this.edge,
    required this.duration,
    required this.child,
  });

  final bool visible;
  final ChromeRevealEdge edge;
  final Duration duration;
  final Widget child;

  @override
  State<ChromeReveal> createState() => _ChromeRevealState();
}

class _ChromeRevealState extends State<ChromeReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: widget.visible ? 1 : 0,
    );
  }

  @override
  void didUpdateWidget(covariant ChromeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        final t = Curves.easeOutCubic
            .transform(_controller.value)
            .clamp(0.0, 1.0);
        final down = widget.edge == ChromeRevealEdge.bottom;
        return ClipRect(
          child: Align(
            alignment: down ? Alignment.bottomCenter : Alignment.topCenter,
            heightFactor: t,
            child: FractionalTranslation(
              translation: Offset(0, down ? 1 - t : t - 1),
              child: child,
            ),
          ),
        );
      },
    );
  }
}
