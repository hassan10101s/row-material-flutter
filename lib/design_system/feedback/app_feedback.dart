import 'package:flutter/material.dart';

import '../tokens/app_colors.dart';

class AppFeedback {
  static void show(
    BuildContext context,
    String message, {
    bool isError = false,
    int durationSeconds = 4,
  }) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppColors.danger : AppColors.surfaceDeep,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: durationSeconds),
      ),
    );
  }

  static void success(BuildContext context, String message) =>
      show(context, message);

  static void error(BuildContext context, String message) =>
      show(context, message, isError: true);
}