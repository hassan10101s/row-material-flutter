import 'package:flutter/widgets.dart';

/// Motion durations and curves.
///
/// Always read a duration through [of] rather than using a constant directly:
/// [of] collapses to [Duration.zero] when the user has asked the OS for
/// reduced motion, so every animated widget in the app becomes instant for
/// free. `MediaQuery.disableAnimations` was previously read nowhere in the
/// codebase, which left `AppShimmer` sweeping forever and every
/// `AnimatedScale` / `AnimatedSize` running unconditionally.
class AppMotion {
  /// Hover feedback, ripples, small state flips.
  static const Duration fast = Duration(milliseconds: 120);

  /// Chevrons, expand/collapse, page transitions.
  static const Duration normal = Duration(milliseconds: 200);

  /// Entrances, staggered lists, dialogs.
  static const Duration slow = Duration(milliseconds: 320);

  /// Skeleton shimmer sweep.
  static const Duration shimmer = Duration(milliseconds: 1400);

  /// Number of milliseconds to actually wait, honouring the platform's
  /// reduced-motion setting.
  ///
  /// Widgets still hand the result to an `Animated*` widget; a zero duration
  /// makes them jump straight to the end state instead of tweening.
  static Duration of(BuildContext context, Duration duration) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

  /// Whether looping animations (the shimmer) may run at all.
  static bool get isAnimationsDisabled =>
      WidgetsBinding.instance.platformDispatcher.accessibilityFeatures
          .disableAnimations;
}
