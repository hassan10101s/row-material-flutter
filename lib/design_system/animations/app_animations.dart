import 'package:flutter/material.dart';

/// In-app page route with a subtle fade + slide transition.
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({
    super.settings,
    required WidgetBuilder builder,
    Duration duration = const Duration(milliseconds: 240),
  }) : super(
          transitionDuration: duration,
          reverseTransitionDuration: Duration(milliseconds: duration.inMilliseconds ~/ 2),
          pageBuilder: (context, animation, secondaryAnimation) => builder(context),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final slide = SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.018),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
              child: child,
            );
            return FadeTransition(opacity: animation, child: slide);
          },
        );
}

/// Convenience builder for [AppPageRoute] with a named route / screen.
Route<T> appPageRoute<T>(Widget child, {RouteSettings? settings}) =>
    AppPageRoute<T>(settings: settings, builder: (_) => child);

/// A [Page] backed by [AppPageRoute], suitable for go_router [GoRoute.pageBuilder].
class AppPage<T> extends Page<T> {
  const AppPage({
    required this.builder,
    this.duration = const Duration(milliseconds: 240),
    super.key,
    super.name,
  });

  final WidgetBuilder builder;
  final Duration duration;

  @override
  Route<T> createRoute(BuildContext context) =>
      AppPageRoute<T>(settings: this, builder: builder, duration: duration);
}

/// Fades + slides its child in once, with an optional delay.
class AppEntrance extends StatefulWidget {
  final Widget child;
  final Duration duration;
  final Duration delay;
  final Offset offset;
  final Curve curve;

  const AppEntrance({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 320),
    this.delay = Duration.zero,
    this.offset = const Offset(0, 0.02),
    this.curve = Curves.easeOutCubic,
  });

  @override
  State<AppEntrance> createState() => _AppEntranceState();
}

class _AppEntranceState extends State<AppEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
      value: 0,
    );
    if (widget.delay > Duration.zero) {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = CurvedAnimation(parent: _controller, curve: widget.curve);
    final slide = SlideTransition(
      position: Tween<Offset>(begin: widget.offset, end: Offset.zero)
          .animate(animation),
      child: widget.child,
    );
    return FadeTransition(opacity: animation, child: slide);
  }
}

/// Staggers a list of children so each one enters after the previous one.
class AppStagger extends StatefulWidget {
  final List<Widget> children;
  final Duration itemDuration;
  final Duration interval;
  final Offset offset;

  const AppStagger({
    super.key,
    required this.children,
    this.itemDuration = const Duration(milliseconds: 300),
    this.interval = const Duration(milliseconds: 60),
    this.offset = const Offset(0, 0.02),
  });

  @override
  State<AppStagger> createState() => _AppStaggerState();
}

class _AppStaggerState extends State<AppStagger>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.itemDuration +
          widget.interval * (widget.children.length - 1),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.children.length;
    if (count == 0) return const SizedBox.shrink();
    final intervalShare = widget.interval.inMilliseconds /
        _controller.duration!.inMilliseconds;
    final itemShare = widget.itemDuration.inMilliseconds /
        _controller.duration!.inMilliseconds;
    final children = <Widget>[];
    for (var i = 0; i < count; i++) {
      final start = intervalShare * i;
      final animation = CurvedAnimation(
        parent: _controller,
        curve: Interval(start, (start + itemShare).clamp(0.0, 1.0),
            curve: Curves.easeOutCubic),
      );
      children.add(SlideTransition(
        position: Tween<Offset>(begin: widget.offset, end: Offset.zero)
            .animate(animation),
        child: FadeTransition(opacity: animation, child: widget.children[i]),
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// Shimmer sweep for skeleton loading states.
class AppShimmer extends StatefulWidget {
  final Widget child;
  final Color? baseColor;
  final Color? highlightColor;

  const AppShimmer({
    super.key,
    required this.child,
    this.baseColor,
    this.highlightColor,
  });

  @override
  State<AppShimmer> createState() => _AppShimmerState();
}

class _AppShimmerState extends State<AppShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final base = widget.baseColor ??
        (brightness == Brightness.dark
            ? const Color(0xFF243147)
            : const Color(0xFFE8ECF1));
    final highlight = widget.highlightColor ??
        (brightness == Brightness.dark
            ? const Color(0xFF334155)
            : const Color(0xFFF4F7FB));
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            final dx = bounds.width * (2 * _controller.value - 1);
            return LinearGradient(
              colors: [base, highlight, base],
              stops: const [0.3, 0.5, 0.7],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              transform: _SlideGradientTransform(dx),
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

class _SlideGradientTransform extends GradientTransform {
  const _SlideGradientTransform(this.offset);
  final double offset;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(offset, 0, 0);
}