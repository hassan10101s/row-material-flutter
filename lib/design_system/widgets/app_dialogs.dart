import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../widgets/app_button.dart';

/// Confirmation dialog consistent with the app design system.
/// Returns `true` when the user confirms.
Future<bool> showAppConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String? confirmLabel,
  String? cancelLabel,
  bool danger = false,
  IconData icon = Icons.help_outline,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (c) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      backgroundColor: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: (danger ? AppColors.danger : AppColors.primary)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppRadii.md),
                    ),
                    child: Icon(
                      icon,
                      size: 20.r,
                      color: danger ? AppColors.danger : AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 16.spMax,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textStrong,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                message,
                style: TextStyle(
                  fontSize: 14.spMax,
                  height: 1.5,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(c).pop(false),
                    child: Text(cancelLabel ?? 'إلغاء'),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  AppButton(
                    label: confirmLabel ?? 'تأكيد',
                    style: danger ? AppButtonStyle.danger : AppButtonStyle.primary,
                    onPressed: () => Navigator.of(c).pop(true),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return result ?? false;
}

/// Simple alert dialog consistent with the app design system.
Future<void> showAppAlert(
  BuildContext context, {
  required String title,
  String? message,
  String? okLabel,
  IconData icon = Icons.info_outline,
}) async {
  await showDialog<void>(
    context: context,
    builder: (c) => Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      backgroundColor: AppColors.surface,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 22.r, color: AppColors.info),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 16.spMax,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textStrong,
                      ),
                    ),
                  ),
                ],
              ),
              if (message != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 14.spMax,
                    height: 1.5,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.xl),
              Align(
                alignment: Alignment.centerRight,
                child: AppButton(
                  label: okLabel ?? 'حسناً',
                  style: AppButtonStyle.secondary,
                  onPressed: () => Navigator.of(c).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}