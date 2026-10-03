import 'package:flutter/material.dart';

import '../../core/constants/app_strings.dart';
import '../../core/platform/file_delivery.dart';
import '../../di/platform_ports.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import 'app_feedback.dart';

/// Offering the file the app just wrote.
///
/// ## Why this exists
///
/// `AppFeedback.success(context, 'Saved to <path>')` is a dead end on a phone.
/// The export lives in `/data/user/0/<pkg>/files/MaterialLab/exports/...`, which
/// no file manager can open, so the user is told the file exists somewhere they
/// cannot reach. The share sheet is the only real way out of the sandbox.
///
/// On desktop the same call has to keep working, so the actions offered are
/// whatever [FileDelivery] reports it can actually do. When neither is
/// available the sheet says so plainly instead of presenting a button that goes
/// nowhere - the port's `canReveal` / `canShare` exist for exactly that.
class AppFeedbackExport {
  AppFeedbackExport._();

  /// Shows the delivery sheet for [filePath].
  static Future<void> actions(
    BuildContext context, {
    required String filePath,
    String? documentName,
  }) async {
    // The file is already written by this point, so the only thing left is
    // telling the user about it. A locator that has not been initialised (a
    // widget test, an early error path) must not turn that success into a crash,
    // so the port is resolved through the shared helper.
    final delivery = fileDelivery();
    final messenger = ScaffoldMessenger.maybeOf(context);
    // A banner is already on screen; a modal sheet on top of it would stack two
    // transient surfaces and hide the one that explains what happened.
    messenger?.hideCurrentSnackBar();

    if (!delivery.canReveal && !delivery.canShare) {
      AppFeedback.show(
        context,
        AppText.t(
          'تم إنشاء الملف لكن لا يمكن فتحه على هذا الجهاز',
          'The file was created but cannot be opened on this device',
        ),
        type: AppFeedbackType.info,
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => _ExportSheet(
        filePath: filePath,
        documentName: documentName,
        delivery: delivery,
      ),
    );
  }
}

class _ExportSheet extends StatelessWidget {
  const _ExportSheet({
    required this.filePath,
    required this.documentName,
    required this.delivery,
  });

  final String filePath;
  final String? documentName;
  final FileDelivery delivery;

  @override
  Widget build(BuildContext context) {
    final title = documentName ?? filePath.split(RegExp(r'[/\\]')).last;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              0,
              AppSpacing.page,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppText.t('تم إنشاء التقرير', 'Report created'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpacing.xxs),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (delivery.canReveal)
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: Text(AppText.t('فتح الملف', 'Open the file')),
              onTap: () async {
                final ok = await delivery.reveal(filePath);
                if (!context.mounted) return;
                final navigator = Navigator.of(context);
                if (ok) {
                  navigator.pop();
                } else {
                  // Keep the sheet open: the user may still want to share it.
                  AppFeedback.error(
                    context,
                    AppText.t(
                      'لا يوجد تطبيق يمكنه فتح هذا الملف',
                      'No app on this device can open this file',
                    ),
                  );
                }
              },
            ),
          if (delivery.canShare)
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: Text(AppText.t('مشاركة', 'Share')),
              onTap: () async {
                final ok = await delivery.share(filePath, subject: title);
                if (!context.mounted) return;
                if (ok) {
                  Navigator.of(context).pop();
                } else {
                  AppFeedback.error(
                    context,
                    AppText.t('تعذرت المشاركة', 'Could not share the file'),
                  );
                }
              },
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}
