import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';
import '../tokens/app_colors.dart';
import 'app_window.dart';

/// The "really delete this?" confirmation used by every master-data tab.
///
/// These tabs all delete by name, and every one of them needs the same wording
/// and the same danger colour. When that lives in a dialog per tab, the fourth
/// tab gets a green confirm button because somebody copy-pasted it. So it lives
/// here once and the variants cannot drift.
///
/// Renders in the unified [AppWindow] chrome like every other dialog.
class AppDeleteConfirmDialog extends StatelessWidget {
  const AppDeleteConfirmDialog({
    super.key,
    required this.title,
    required this.name,
    this.cancelLabel,
    this.confirmLabel,
  });

  /// What kind of thing is being deleted - shown as the dialog title.
  final String title;

  /// The thing's name, quoted in the question so the user can see *which* row
  /// they are about to remove.
  final String name;

  final String? cancelLabel;
  final String? confirmLabel;

  /// Shows the dialog and resolves to `true` only if the user confirmed.
  ///
  /// Every caller ends up with the same guard clause afterwards, so it lives
  /// here too - a caller that forgets to check the result would delete a row
  /// just for dismissing the dialog.
  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String name,
    String? cancelLabel,
    String? confirmLabel,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AppDeleteConfirmDialog(
        title: title,
        name: name,
        cancelLabel: cancelLabel,
        confirmLabel: confirmLabel,
      ),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    return AppWindow(
      title: title,
      icon: Icons.delete_outline,
      accent: AppColors.danger,
      size: AppWindowSize.sm,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(cancelLabel ?? AppStrings.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel ?? AppStrings.delete),
        ),
      ],
      child: Text('${AppText.t('حذف', 'Delete')} "$name"؟'),
    );
  }
}
