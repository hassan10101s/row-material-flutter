import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';

enum AppFeedbackType { neutral, success, error, info }

class AppFeedback {
  static void show(
    BuildContext context,
    String message, {
    bool isError = false,
    AppFeedbackType type = AppFeedbackType.neutral,
    int durationSeconds = 4,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    final Color bg = switch (type) {
      AppFeedbackType.error => AppColors.danger,
      AppFeedbackType.success => AppColors.success,
      AppFeedbackType.info => AppColors.primary,
      AppFeedbackType.neutral => AppColors.surfaceDeep,
    };
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: type == AppFeedbackType.neutral && !isError
            ? AppColors.surfaceDeep
            : bg,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: durationSeconds),
      ),
    );
  }

  static void success(BuildContext context, String message) =>
      show(context, message, type: AppFeedbackType.success);

  static void error(BuildContext context, String message) =>
      show(context, message, isError: true, type: AppFeedbackType.error);

  static void info(BuildContext context, String message) =>
      show(context, message, type: AppFeedbackType.info);
}