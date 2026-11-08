import 'package:flutter/material.dart';

/// A Tooltip that owns its semantics subtree — the app-wide Windows fix.
///
/// Every anchor node here is wrapped in [Semantics] with `container: true`
/// so another sibling's tooltip configuration can never absorb it. That
/// absorption is the defect in flutter/flutter#182444: a Tooltip's overlay is
/// grafted to its anchor through a traversal-parent identifier, and when the
/// identifier is silently dropped (adjacent/duplicate tooltips inside a
/// scrollable are the measured trigger) the overlay is serialized as an
/// orphan. The Windows accessibility bridge then rejects the entire update —
/// the console error `[ERROR:flutter/shell/platform/common/
/// accessibility_bridge.cc] Failed to update ui::AXTree, error: N will not be
/// in the tree and is not the new root` — which in release builds has killed
/// host apps.
///
/// Deliberately NOT [ExcludeSemantics] — that variant was measured to
/// produce MORE rejected updates, not fewer. `IconButton(tooltip:)` needs no
/// wrapping: a button anchor already gets its own node.
class AppTooltip extends StatelessWidget {
  const AppTooltip({
    super.key,
    this.message,
    this.richMessage,
    this.child,
    this.padding,
    this.margin,
    this.verticalOffset,
    this.preferBelow,
    this.decoration,
    this.textStyle,
    this.textAlign,
    this.waitDuration,
    this.showDuration,
    this.excludeFromSemantics = false,
    this.enableFeedback,
    this.triggerMode,
    this.tooltipKey,
  });

  /// Attached to the inner [Tooltip], so callers can hold a
  /// `GlobalKey<TooltipState>` (e.g. `ensureTooltipVisible`) without it
  /// landing on this wrapper and going dead.
  final Key? tooltipKey;

  final String? message;
  final InlineSpan? richMessage;
  final Widget? child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? verticalOffset;
  final bool? preferBelow;
  final Decoration? decoration;
  final TextStyle? textStyle;
  final TextAlign? textAlign;
  final Duration? waitDuration;
  final Duration? showDuration;
  final bool excludeFromSemantics;
  final bool? enableFeedback;
  final TooltipTriggerMode? triggerMode;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: Tooltip(
        key: tooltipKey,
        message: message,
        richMessage: richMessage,
        padding: padding,
        margin: margin,
        verticalOffset: verticalOffset,
        preferBelow: preferBelow,
        decoration: decoration,
        textStyle: textStyle,
        textAlign: textAlign,
        waitDuration: waitDuration,
        showDuration: showDuration,
        excludeFromSemantics: excludeFromSemantics,
        enableFeedback: enableFeedback,
        triggerMode: triggerMode,
        child: child,
      ),
    );
  }
}
