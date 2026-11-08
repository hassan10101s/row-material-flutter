import 'package:flutter/material.dart';
import './app_tooltip.dart';

/// A compact, tappable explanation. Works without a hover-capable pointer.
class AppInfoButton extends StatefulWidget {
  const AppInfoButton({
    super.key,
    required this.message,
    required this.label,
    this.icon,
    this.accent,
  });
  final String message;
  final String label;
  final IconData? icon;
  final Color? accent;
  @override
  State<AppInfoButton> createState() => _AppInfoButtonState();
}

class _AppInfoButtonState extends State<AppInfoButton> {
  final _tooltip = GlobalKey<TooltipState>();
  @override
  Widget build(BuildContext context) => AppTooltip(
    tooltipKey: _tooltip,
    message: widget.message,
    triggerMode: TooltipTriggerMode.manual,
    showDuration: const Duration(seconds: 12),
    child: Semantics(label: widget.label, button: true, child: IconButton(
      onPressed: () => _tooltip.currentState?.ensureTooltipVisible(),
      icon: Icon(
        widget.icon ?? Icons.science_outlined,
        size: 18,
        color: widget.accent,
      ),
    )),
  );
}
