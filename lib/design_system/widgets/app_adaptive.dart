import 'package:flutter/widgets.dart';

import '../../core/responsive/form_factor.dart';
import '../../core/responsive/responsive_scope.dart';
import '../tokens/app_spacing.dart';

/// Picks the authored variant for the resolved form factor.
///
/// This is the *only* place a form-factor branch is allowed to live
/// (`test/architecture/responsive_guard_test.dart` rule 4), which is what keeps
/// the decision visible and singular instead of scattered through screens.
///
/// A feature's host widget is the whole of the dispatch:
///
/// ```dart
/// class ConstantsTab extends StatelessWidget {
///   const ConstantsTab({super.key});
///
///   @override
///   Widget build(BuildContext context) => appAdaptiveVariant(
///         context,
///         desktop: (_) => const DesktopConstantsTab(),
///         mobile: (_) => const MobileConstantsTab(),
///       );
/// }
/// ```
///
/// Both builders are plain closures, so a variant is only ever *constructed*
/// when it is the one being built: the phone build never pays for a
/// `DataTable` it will not render, and vice versa.
///
/// [context] is the host's own context. The returned widget becomes a child of
/// the host's element, so the host context is a correct ancestor for it -
/// providers, themes and inherited widgets all resolve exactly as they would
/// for any other child, and the variant never depends on something that exists
/// on only one form factor.
Widget appAdaptiveVariant(
  BuildContext context, {
  required WidgetBuilder desktop,
  required WidgetBuilder mobile,
}) {
  return appUsesDesktopChrome(context) ? desktop(context) : mobile(context);
}

/// Overlay policy follows the authored platform experience even on a narrow
/// desktop window or a landscape phone. The scope also supports previews.
bool appUsesDesktopChrome(BuildContext context) =>
    ResponsiveScope.maybeOf(context)?.isDesktop ?? FormFactor.current.isDesktop;

/// One density policy for shared controls; window width never shrinks targets.
double appControlHeight(BuildContext context, {bool compact = false}) =>
    appUsesDesktopChrome(context)
    ? (compact ? AppControlSizes.compact : AppControlSizes.regular)
    : AppControlSizes.touch;

/// Widget form of [appAdaptiveVariant], for call sites that prefer a child.
class AppAdaptive extends StatelessWidget {
  const AppAdaptive({super.key, required this.desktop, required this.mobile});

  final WidgetBuilder desktop;
  final WidgetBuilder mobile;

  @override
  Widget build(BuildContext context) =>
      appAdaptiveVariant(context, desktop: desktop, mobile: mobile);
}
