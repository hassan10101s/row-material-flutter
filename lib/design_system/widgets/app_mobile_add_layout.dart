import 'app_add_floating_action_button.dart';
import 'package:flutter/material.dart';

/// Keeps the page's create action in one reachable location on phones.
/// Desktop callers keep their existing inline action.
class AppMobileAddLayout extends StatelessWidget {
  const AppMobileAddLayout({
    super.key,
    required this.child,
    required this.tooltip,
    required this.floating,
    this.onAdd,
  });
  final bool floating;
  final Widget child;
  final String tooltip;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    if (!floating || onAdd == null) return child;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Padding(padding: const EdgeInsets.only(bottom: 80), child: child),
      floatingActionButton: AppAddFloatingActionButton(
        tooltip: tooltip,
        onPressed: onAdd,
      ),
    );
  }
}
