import 'package:flutter/material.dart';
import '../../core/constants/app_strings.dart';

/// The shared create action for phone registers. Sibling tabs do not share
/// a Hero tag, so opening an editor cannot collide with another tab's button.
class AppAddFloatingActionButton extends StatelessWidget {
  const AppAddFloatingActionButton({
    super.key,
    required this.onPressed,
    this.tooltip,
  });

  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => FloatingActionButton(
    heroTag: null,
    tooltip: tooltip ?? AppText.t('إضافة', 'Add'),
    onPressed: onPressed,
    child: const Icon(Icons.add),
  );
}
