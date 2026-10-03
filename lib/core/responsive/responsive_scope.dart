import 'package:flutter/widgets.dart';

import 'form_factor.dart';
import 'layout_spec.dart';

/// Carries the resolved [LayoutSpec] down the tree.
///
/// Placed **above** `MaterialApp` so that `Dialog`, `Menu` and any other
/// overlay - which are inserted into the navigator's subtree rather than
/// inheriting the caller's scope - still resolve the same metrics as the page
/// that opened them. A dialog that disagreed with its page about the form
/// factor would be the hardest kind of bug to reproduce.
class ResponsiveScope extends InheritedWidget {
  const ResponsiveScope({
    super.key,
    required this.spec,
    required super.child,
  });

  /// Resolves the platform form factor itself. Used by `main()`.
  ResponsiveScope.forPlatform({super.key, required super.child})
      : spec = LayoutSpec.of(FormFactor.resolve());

  final LayoutSpec spec;

  static LayoutSpec of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ResponsiveScope>();
    assert(scope != null, 'No ResponsiveScope above this widget.');
    return scope!.spec;
  }

  @override
  bool updateShouldNotify(ResponsiveScope oldWidget) =>
      oldWidget.spec != spec;
}

extension ResponsiveContext on BuildContext {
  /// The form-factor metrics for this subtree.
  LayoutSpec get layout => ResponsiveScope.of(this);

  bool get isMobile => ResponsiveScope.of(this).isMobile;

  bool get isDesktop => ResponsiveScope.of(this).isDesktop;
}
