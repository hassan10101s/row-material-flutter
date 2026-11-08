import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'app_adaptive.dart';
import 'app_top_app_bar.dart';
import '../animations/app_animations.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// The single window chrome every dialog in the app inherits.
///
/// A white, top-anchored-feeling window (the multi-window desktop idea): an
/// icon tile + title header, a close button, a scrollable body and an
/// optional end-aligned action footer. One look for every edit, opener and
/// confirmation anywhere in the program — no screen keeps its own dialog
/// style.
///
/// * Desktop / wide screens: [showAppWindow] centers the window with a
///   [AppWindowSize] max width.
/// * Large content: [showAppContent] pushes a full page on phones and uses
///   the same window on desktop.
/// * Short interactions: [showAppOverlay] uses a mobile bottom sheet.
enum AppWindowSize {
  /// Small forms (unit / parameter / confirm editors): 440dp.
  sm(440),

  /// Medium editors (products, analyses, inventory): 640dp.
  md(640),

  /// Large editors (material editor): 880dp.
  lg(880);

  const AppWindowSize(this.maxWidth);

  final double maxWidth;
}

class AppWindow extends StatelessWidget {
  const AppWindow({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.accent,
    this.subtitle,
    this.actions,
    this.leadingActions,
    this.size = AppWindowSize.md,
    this.maxWidth,
    this.height,
    this.showClose = true,
    this.scrollBody = true,
    this.fullScreen = false,
    this.onRequestClose,
  });

  final String title;
  final IconData? icon;
  final Color? accent;
  final String? subtitle;
  final Widget child;

  /// End-aligned footer buttons (Save / Apply / OK).
  final List<Widget>? actions;

  /// Start-aligned footer buttons (a "Clear all" beside Cancel/Apply).
  final List<Widget>? leadingActions;
  final AppWindowSize size;

  /// Overrides [size] when a dialog has an established width worth keeping.
  final double? maxWidth;
  final double? height;
  final bool showClose;

  /// False for bodies that manage their own scrolling (an `Expanded` +
  /// internal `SingleChildScrollView`, like the material editor): the body
  /// is placed directly instead of inside the window scroll view, where an
  /// `Expanded` would take unbounded constraints and explode.
  final bool scrollBody;

  /// Selected by the feature's platform authority. Large mobile content
  /// occupies a pushed page; desktop keeps the same window chrome.
  final bool fullScreen;

  /// Replaces the direct pop of the close button. Provided by guarded
  /// surfaces (`showAppContent` with an [AppContentGuard]): the editor sets
  /// [AppContentGuard.canClose] false while there is unsaved input and the
  /// consult happens here, so the header close button follows the same
  /// rules as the system back gesture.
  final void Function()? onRequestClose;

  @override
  Widget build(BuildContext context) {
    if (fullScreen) {
      return Scaffold(
        backgroundColor: AppColors.surface,
        appBar: AppTopAppBar(title: title),
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (subtitle?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pageMobile,
                    AppSpacing.sm,
                    AppSpacing.pageMobile,
                    0,
                  ),
                  child: Text(
                    subtitle!,
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              Expanded(
                child: scrollBody
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.pageMobile,
                          AppSpacing.sm,
                          AppSpacing.pageMobile,
                          AppSpacing.pageMobile,
                        ),
                        child: child,
                      )
                    : Padding(
                        padding: const EdgeInsets.all(AppSpacing.pageMobile),
                        child: child,
                      ),
              ),
              if (_hasFooter) footer(leading: leadingActions, actions: actions),
            ],
          ),
        ),
      );
    }
    final width = maxWidth ?? size.maxWidth;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: AppColors.surface,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.xl),
        side: BorderSide(color: AppColors.borderMuted),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          maxHeight: MediaQuery.of(context).size.height - 48,
        ),
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AppWindowHeader(
                title: title,
                subtitle: subtitle,
                icon: icon,
                accent: accent,
                showClose: showClose,
                onRequestClose: onRequestClose,
              ),
              Divider(height: 1, color: AppColors.borderMuted),
              if (scrollBody)
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: child,
                  ),
                )
              else
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: child,
                  ),
                ),
              if (_hasFooter) ...[
                Divider(height: 1, color: AppColors.borderMuted),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  child: _footerRow(leading: leadingActions, actions: actions),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  bool get _hasActions => actions != null && actions!.isNotEmpty;
  bool get _hasLeading => leadingActions != null && leadingActions!.isNotEmpty;
  bool get _hasFooter => _hasActions || _hasLeading;

  static List<Widget> _spaced(List<Widget>? items) {
    final out = <Widget>[];
    final list = items ?? const <Widget>[];
    for (var i = 0; i < list.length; i++) {
      if (i > 0) out.add(const SizedBox(width: AppSpacing.sm));
      out.add(list[i]);
    }
    return out;
  }

  /// The footer row, shared with bodies that keep their own footing (a sheet
  /// whose buttons must scroll with its content): same divider, padding and
  /// leading/actions split as the window footer above.
  ///
  /// Sized for one or two actions per side in a 376dp footer. A third button
  /// overflows the row on narrow windows — fold those manually in a [Wrap]
  /// instead of adding them here.
  static Widget footer({List<Widget>? leading, List<Widget>? actions}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, color: AppColors.borderMuted),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: _footerRow(leading: leading, actions: actions),
        ),
      ],
    );
  }

  /// `leading` stays start-aligned, `actions` end-aligned. The spacer exists
  /// only when both sides are present: with actions alone it would steal
  /// width from `Expanded` buttons that are meant to fill the row.
  ///
  /// Stays a [Row] on purpose: callers pass `Expanded` footers (full-width
  /// mobile CTAs) and `Expanded` requires `FlexParentData` — a [Wrap] would
  /// crash those with an incompatible-ParentData error. Keep footers to two
  /// actions per side; longer sets should fold manually in a [Wrap] at the
  /// call site instead of adding them here.
  static Widget _footerRow({List<Widget>? leading, List<Widget>? actions}) {
    final hasLeading = leading != null && leading.isNotEmpty;
    final hasActions = actions != null && actions.isNotEmpty;
    final children = [...?leading, ...?actions];
    // Expanded mobile actions need Flex parent data. Ordinary actions can
    // flow vertically on small windows and with enlarged text.
    if (!children.any((child) => child is Flexible)) {
      if (hasLeading && hasActions) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: OverflowBar(
                alignment: MainAxisAlignment.start,
                overflowAlignment: OverflowBarAlignment.start,
                spacing: AppSpacing.sm,
                overflowSpacing: AppSpacing.sm,
                children: leading,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                spacing: AppSpacing.sm,
                overflowSpacing: AppSpacing.sm,
                children: actions,
              ),
            ),
          ],
        );
      }
      return OverflowBar(
        alignment: hasLeading ? MainAxisAlignment.start : MainAxisAlignment.end,
        overflowAlignment: OverflowBarAlignment.end,
        spacing: AppSpacing.sm,
        overflowSpacing: AppSpacing.sm,
        children: children,
      );
    }
    return Row(
      mainAxisAlignment: hasLeading
          ? MainAxisAlignment.start
          : MainAxisAlignment.end,
      children: [
        ..._spaced(leading),
        if (hasLeading && hasActions) const Spacer(),
        ..._spaced(actions),
      ],
    );
  }
}

class _AppWindowHeader extends StatelessWidget {
  const _AppWindowHeader({
    required this.title,
    this.subtitle,
    this.icon,
    this.accent,
    this.showClose = true,
    this.onRequestClose,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Color? accent;
  final bool showClose;
  final void Function()? onRequestClose;

  @override
  Widget build(BuildContext context) {
    final accentColor = accent ?? AppColors.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Icon(icon, size: 20.r, color: accentColor),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 17.spMax,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textStrong,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.spMax,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (showClose)
            IconButton(
              tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
              constraints: BoxConstraints.tightFor(
                width: appControlHeight(context),
                height: appControlHeight(context),
              ),
              onPressed:
                  onRequestClose ?? () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}

/// Shared chrome for stateful dialogs as well as simple overlay builders.
/// The caller keeps its providers/controllers and its existing return value.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.child,
    this.icon,
    this.subtitle,
    this.accent,
    this.actions,
    this.leadingActions,
    this.size = AppWindowSize.sm,
    this.scrollBody = true,
    this.height,
  });

  final String title;
  final Widget child;
  final IconData? icon;
  final String? subtitle;
  final Color? accent;
  final List<Widget>? actions;
  final List<Widget>? leadingActions;
  final AppWindowSize size;
  final bool scrollBody;
  final double? height;

  @override
  Widget build(BuildContext context) => appAdaptiveVariant(
    context,
    desktop: (_) => AppWindow(
      title: title,
      subtitle: subtitle,
      icon: icon,
      accent: accent,
      size: size,
      actions: actions,
      leadingActions: leadingActions,
      scrollBody: scrollBody,
      height: height,
      child: child,
    ),
    mobile: (_) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: height,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AppWindowHeader(
                title: title,
                subtitle: subtitle,
                icon: icon,
                accent: accent,
              ),
              Divider(height: 1, color: AppColors.borderMuted),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: scrollBody
                      ? SingleChildScrollView(child: child)
                      : child,
                ),
              ),
              if ((actions?.isNotEmpty ?? false) ||
                  (leadingActions?.isNotEmpty ?? false))
                AppWindow.footer(leading: leadingActions, actions: actions),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Opens the same dialog content as a desktop window or a mobile sheet.
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => appUsesDesktopChrome(context)
    ? showDialog<T>(
        context: context,
        barrierDismissible: barrierDismissible,
        builder: builder,
      )
    : showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        isDismissible: barrierDismissible,
        enableDrag: barrierDismissible,
        builder: builder,
      );

/// Mutable back/close guard for a unified editor surface (`showAppContent`).
///
/// The editor flips [canClose] as its dirty state changes — the surface
/// rebuilds around it, so a plain assignment (no `setState`) is enough.
/// While [canClose] is false, both the system back gesture and the window
/// close button are intercepted and [confirmDiscard] decides: a confirmed
/// discard pops the surface, cancelling keeps it open with all input intact.
class AppContentGuard extends ChangeNotifier {
  AppContentGuard({this.confirmDiscard});

  /// Called when a pop is attempted with unsaved input. Return `true` to
  /// discard and pop, `false` to stay open. Typically `showAppConfirm`
  /// ("تجاهل التعديلات؟").
  final Future<bool> Function()? confirmDiscard;

  bool _canClose = true;
  bool _confirming = false;

  /// Whether the surface may pop right now. Editors set this to `false`
  /// from `_markDirty` and back to `true` after a successful save/reset.
  bool get canClose => _canClose;

  set canClose(bool value) {
    if (_canClose == value) return;
    _canClose = value;
    notifyListeners();
  }

  /// Consulted by the surface before a close (system back or the header
  /// close button). Returns immediately when [canClose]; otherwise awaits
  /// the discard confirmation. When it resolves `true` the caller pops the
  /// surface itself.
  Future<bool> resolveClose() async {
    if (_confirming) return false;
    if (_canClose) return true;
    _confirming = true;
    try {
      return confirmDiscard == null ? false : await confirmDiscard!();
    } finally {
      _confirming = false;
    }
  }
}

/// Registers [guard] on the enclosing route so back gestures follow
/// [AppContentGuard.canClose]. Also public for editors embedded in an owned
/// route (a full page pushed by the feature itself) that still want the
/// shared guard behaviour.
class AppContentPopScope<T> extends StatelessWidget {
  const AppContentPopScope({
    super.key,
    required this.guard,
    required this.child,
  });

  final AppContentGuard guard;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: guard,
      builder: (context, _) => PopScope<Object?>(
        canPop: guard.canClose,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop || guard.canClose) return;
          if (await guard.resolveClose()) {
            if (context.mounted) Navigator.of(context).pop();
          }
        },
        child: child,
      ),
    );
  }
}

/// The unified content surface: [child] inside the shared [AppWindow] chrome,
/// completing with whatever the surface pops with (same contract as
/// [showDialog]).
///
/// * Desktop windows: a centered [AppWindowSize] window.
/// * Phones: a full page pushed on the navigator with back navigation —
///   long forms and large details never turn into a cramped sheet. Short
///   confirmations and temporary messages keep using showAppOverlay /
///   showAppConfirm.
///
/// [fullScreen] defaults to the platform authority (`appUsesDesktopChrome`),
/// so call sites rarely need to pass it: only flows whose content is large
/// on *both* forms (or explicitly windowed on both) override it.
///
/// Pass a [guard] to protect unsaved input: the surface then follows
/// [AppContentGuard.canClose] for the system back gesture and the window
/// close button alike.
Future<T?> showAppContent<T>(
  BuildContext context, {
  bool? fullScreen,
  required String title,
  required Widget Function(
    BuildContext context,
    void Function([T? result]) close,
  )
  builder,
  IconData? icon,
  String? subtitle,
  AppWindowSize size = AppWindowSize.md,
  double? maxWidth,
  double? height,
  bool scrollBody = true,
  List<Widget> Function(BuildContext context, void Function([T? result]) close)?
  actionsBuilder,
  AppContentGuard? guard,
}) {
  final usesFullScreen = fullScreen ?? !appUsesDesktopChrome(context);
  Widget surface(BuildContext ctx) {
    void close([T? result]) => Navigator.of(ctx).pop(result);
    Widget window = AppWindow(
      fullScreen: usesFullScreen,
      title: title,
      icon: icon,
      subtitle: subtitle,
      size: size,
      maxWidth: maxWidth,
      height: height,
      scrollBody: scrollBody,
      actions: actionsBuilder?.call(ctx, close),
      onRequestClose: guard == null
          ? null
          : () async {
              if (await guard.resolveClose()) {
                if (ctx.mounted) Navigator.of(ctx).pop();
              }
            },
      child: builder(ctx, close),
    );
    if (guard != null) {
      window = AppContentPopScope<T>(guard: guard, child: window);
    }
    return window;
  }

  return showAppContentSurface<T>(
    context,
    fullScreen: usesFullScreen,
    builder: (ctx, _) => surface(ctx),
  );
}

/// Shared route selection for content that already owns its window/scaffold.
/// This avoids nested headers in existing feature screens.
Future<T?> showAppContentSurface<T>(
  BuildContext context, {
  bool? fullScreen,
  required Widget Function(BuildContext context, bool fullScreen) builder,
}) {
  final page = fullScreen ?? !appUsesDesktopChrome(context);
  Widget surface(BuildContext ctx) => builder(ctx, page);
  return page
      ? Navigator.of(context).push<T>(AppPageRoute(builder: surface))
      : showDialog<T>(context: context, builder: surface);
}

Future<T?> showAppWindow<T>(
  BuildContext context, {
  required String title,
  required Widget child,
  IconData? icon,
  Color? accent,
  String? subtitle,
  List<Widget>? actions,
  AppWindowSize size = AppWindowSize.md,
  double? maxWidth,
  double? height,
  bool barrierDismissible = true,
  bool scrollBody = true,
  List<Widget>? leadingActions,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (_) => AppWindow(
      title: title,
      icon: icon,
      accent: accent,
      subtitle: subtitle,
      actions: actions,
      leadingActions: leadingActions,
      size: size,
      maxWidth: maxWidth,
      height: height,
      scrollBody: scrollBody,
      child: child,
    ),
  );
}

/// Adaptive overlay: the unified window on desktop widths, a bottom sheet
/// with the same content on phones.
///
/// Use this for filter/action sheets that today are `showModalBottomSheet`
/// everywhere (and so look broken on a 1080p window). The content builder
/// receives a close callback that pops the overlay with [result].
///
/// [actions]/[leadingActions] render as the window footer on desktop and
/// as an end-aligned action row at the sheet's foot on phones, so converting
/// a `showAppWindow` call into this is pixel-identical on desktop: same
/// [AppWindow], same title, same footer.
Future<T?> showAppOverlay<T>(
  BuildContext context, {
  required String title,
  required Widget Function(
    BuildContext context,
    void Function([T? result]) close,
  )
  builder,
  IconData? icon,
  Color? accent,
  AppWindowSize size = AppWindowSize.sm,
  List<Widget>? actions,
  List<Widget>? leadingActions,
  bool scrollBody = true,
  double? height,
}) {
  return showAppDialog<T>(
    context,
    builder: (_) => AppDialog(
      title: title,
      icon: icon,
      accent: accent,
      size: size,
      actions: actions,
      leadingActions: leadingActions,
      scrollBody: scrollBody,
      height: height,
      child: Builder(
        builder: (overlayContext) => builder(
          overlayContext,
          ([T? result]) => Navigator.of(overlayContext).pop(result),
        ),
      ),
    ),
  );
}
