import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/constants/app_strings.dart';
import 'app_adaptive.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_button.dart';
import 'app_window.dart';

/// Confirmation dialog consistent with the app design system.
/// Returns `true` when the user confirms.
///
/// Desktop keeps the unified [AppWindow] chrome byte-for-byte; phones get
/// the same content as a bottom sheet with 48dp actions (no cramped
/// 440px dialog + keyboard).
Future<bool> showAppConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
  bool danger = false,
  IconData icon = Icons.help_outline,
}) async {
  final wide = appUsesDesktopChrome(context);
  if (wide) {
    final result = await showAppWindow<bool>(
      context,
      title: title,
      icon: icon,
      accent: danger ? AppColors.danger : AppColors.primary,
      size: AppWindowSize.sm,
      // Builder (not the caller's context): the buttons must pop the
      // dialog route. With shell branch navigators, `Navigator.of(context)`
      // from the caller resolves to the *page* navigator, so popping here
      // used to close the page itself with a bool result (bool vs page
      // type crash) instead of dismissing the dialog.
      actions: [
        Builder(
          builder: (dialogContext) => AppButton(
            label: cancelLabel ?? AppText.t('إلغاء', 'Cancel'),
            style: AppButtonStyle.secondary,
            onPressed: () => Navigator.of(dialogContext).pop(false),
          ),
        ),
        Builder(
          builder: (dialogContext) => AppButton(
            label: confirmLabel ?? AppText.t('تأكيد', 'Confirm'),
            style: danger ? AppButtonStyle.danger : AppButtonStyle.primary,
            onPressed: () => Navigator.of(dialogContext).pop(true),
          ),
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
  final result = await showAppOverlay<bool>(
    context,
    title: title,
    icon: icon,
    accent: danger ? AppColors.danger : AppColors.primary,
    size: AppWindowSize.sm,
    builder: (context, close) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          message,
          style: TextStyle(
            fontSize: 14.spMax,
            height: 1.5,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: AppSpacing.mobileCtaHeight,
                child: AppButton(
                  label: cancelLabel ?? AppText.t('إلغاء', 'Cancel'),
                  style: AppButtonStyle.secondary,
                  onPressed: () => close(false),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              flex: 2,
              child: SizedBox(
                height: AppSpacing.mobileCtaHeight,
                child: AppButton(
                  label: confirmLabel ?? AppText.t('تأكيد', 'Confirm'),
                  style: danger
                      ? AppButtonStyle.danger
                      : AppButtonStyle.primary,
                  onPressed: () => close(true),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Simple alert dialog consistent with the app design system.
///
/// Desktop keeps the unified [AppWindow] chrome; phones get the same content
/// as a bottom sheet (previously this always built a fixed 440dp dialog, which
/// overflowed a 400dp phone once the keyboard appeared).
Future<void> showAppAlert(
  BuildContext context, {
  required String title,
  String? message,
  String? okLabel,
  IconData icon = Icons.info_outline,
}) {
  final wide = appUsesDesktopChrome(context);
  if (wide) {
    return showAppWindow<void>(
      context,
      title: title,
      icon: icon,
      accent: AppColors.info,
      size: AppWindowSize.sm,
      actions: [
        Builder(
          builder: (dialogContext) => AppButton(
            label: okLabel ?? AppText.t('حسناً', 'OK'),
            style: AppButtonStyle.secondary,
            onPressed: () => Navigator.of(dialogContext).pop(),
          ),
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
  return showAppOverlay<void>(
    context,
    title: title,
    icon: icon,
    accent: AppColors.info,
    size: AppWindowSize.sm,
    builder: (context, close) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message != null)
          Text(
            message,
            style: TextStyle(
              fontSize: 14.spMax,
              height: 1.6,
              color: AppColors.textMuted,
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        SizedBox(
          height: AppSpacing.mobileCtaHeight,
          child: AppButton(
            label: okLabel ?? AppText.t('حسناً', 'OK'),
            expanded: true,
            onPressed: () => close(),
          ),
        ),
      ],
    ),
  );
}
