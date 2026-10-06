import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import 'app_button.dart';
import 'app_window.dart';

/// Confirmation dialog consistent with the app design system.
/// Returns `true` when the user confirms.
///
/// Renders in the unified [AppWindow] chrome like every other dialog.
Future<bool> showAppConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
  bool danger = false,
  IconData icon = Icons.help_outline,
}) async {
  final result = await showAppWindow<bool>(
    context,
    title: title,
    icon: icon,
    accent: danger ? AppColors.danger : AppColors.primary,
    size: AppWindowSize.sm,
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(cancelLabel ?? 'إلغاء'),
      ),
      AppButton(
        label: confirmLabel ?? 'تأكيد',
        style: danger ? AppButtonStyle.danger : AppButtonStyle.primary,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
    child: Text(
      message,
      style: TextStyle(
        fontSize: 14.spMax,
        height: 1.5,
        color: AppColors.textMuted,
      ),
    ),
  );
  return result ?? false;
}

/// Simple alert dialog consistent with the app design system.
///
/// Renders in the unified [AppWindow] chrome like every other dialog.
Future<void> showAppAlert(
  BuildContext context, {
  required String title,
  String? message,
  String? okLabel,
  IconData icon = Icons.info_outline,
}) {
  return showAppWindow<void>(
    context,
    title: title,
    icon: icon,
    accent: AppColors.info,
    size: AppWindowSize.sm,
    actions: [
      AppButton(
        label: okLabel ?? 'حسناً',
        style: AppButtonStyle.secondary,
        onPressed: () => Navigator.of(context).pop(),
      ),
    ],
    child: message == null
        ? const SizedBox.shrink()
        : Text(
            message,
            style: TextStyle(
              fontSize: 14.spMax,
              height: 1.5,
              color: AppColors.textMuted,
            ),
          ),
  );
}
