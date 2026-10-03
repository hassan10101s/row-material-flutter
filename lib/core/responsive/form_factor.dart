import 'package:flutter/foundation.dart';

/// Which of the two authored experiences to build.
///
/// This is deliberately a **platform** decision and never a width decision.
/// See [AppFormFactor.resolve] for why.
enum AppFormFactor {
  /// Phone. Bottom navigation, single-column stacks, card lists instead of
  /// tables, full-screen routes instead of fixed-size dialogs.
  mobile,

  /// Windows desktop. Persistent sidebar, top bar, data tables, multi-column
  /// forms and keyboard shortcuts.
  desktop;

  bool get isMobile => this == AppFormFactor.mobile;

  bool get isDesktop => this == AppFormFactor.desktop;
}

/// Resolution of the form factor, done exactly once per process.
abstract final class FormFactor {
  /// The resolved form factor, or `null` before [resolve] has run.
  ///
  /// `null` is a real state, not an oversight: the router needs a value to
  /// dispatch on and it runs before the widget tree exists, so a widget that
  /// reaches for the scope is reading a value that was already decided.
  static AppFormFactor? _resolved;

  /// Decides the form factor from the **target platform**.
  ///
  /// Why not from the window width:
  ///
  ///  * `ScreenUtilInit.designSize` is a process-wide singleton established in
  ///    `main()` before `runApp`. A width-derived choice would either be stale
  ///    after the first resize, or would require re-initialising ScreenUtil
  ///    mid-flight and re-scaling all ~400 `.w`/`.spMax` call sites underneath
  ///    the user.
  ///  * A width-derived choice is wrong for a *snapped* desktop window. A
  ///    Windows user who launches with the window occupying half the screen
  ///    (<1000 logical px) would be handed the phone design size - the
  ///    280dp sidebar would become 672dp.
  ///  * The router dispatches on this value from `pageBuilder`, which does not
  ///    re-run on resize.
  ///
  /// The one exception is a *wide enough* window on a desktop platform, which
  /// is still desktop. There is deliberately no "compact desktop" experience.
  static AppFormFactor resolve() {
    return _resolved ??= switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS => AppFormFactor.mobile,
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.fuchsia => AppFormFactor.desktop,
    };
  }

  /// The resolved form factor, or [AppFormFactor.desktop] if [resolve] has not
  /// run. Defaults to desktop so that any code path that somehow builds before
  /// `main()` gets the historical behaviour rather than a phone layout.
  static AppFormFactor get current =>
      _resolved ?? (resolve());

  @visibleForTesting
  static void debugSet(AppFormFactor? value) => _resolved = value;
}
