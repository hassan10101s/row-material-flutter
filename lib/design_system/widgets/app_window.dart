import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_breakpoints.dart';
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
/// * Phones: [showAppOverlay] keeps the native-feeling bottom sheet with the
///   same header/body/actions content, so the mobile experience does not turn
///   into a cramped desktop dialog.
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

  @override
  Widget build(BuildContext context) {
    final accentColor = accent ?? AppColors.primary;
    final width = maxWidth ?? size.maxWidth;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
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
              _header(context, accentColor),
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
  static Widget _footerRow({List<Widget>? leading, List<Widget>? actions}) {
    final hasLeading = leading != null && leading.isNotEmpty;
    final hasActions = actions != null && actions.isNotEmpty;
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

  Widget _header(BuildContext context, Color accentColor) {
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
              visualDensity: VisualDensity.compact,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
        ],
      ),
    );
  }
}

/// Shows [child] inside the unified [AppWindow] chrome and completes with
/// whatever the window pops with (same contract as [showDialog]).
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
}) {
  final wide = MediaQuery.of(context).size.width >= AppBreakpoints.medium;
  if (wide) {
    return showAppWindow<T>(
      context,
      title: title,
      icon: icon,
      accent: accent,
      size: size,
      child: Builder(
        builder: (context) => builder(
          context,
          ([T? result]) => Navigator.of(context).pop(result),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.page,
          0,
          AppSpacing.page,
          AppSpacing.page,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, color: accent ?? AppColors.primary),
                  const SizedBox(width: AppSpacing.sm),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                child: builder(
                  sheetContext,
                  ([T? result]) => Navigator.of(sheetContext).pop(result),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
