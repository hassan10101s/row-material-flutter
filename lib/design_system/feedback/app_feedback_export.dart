import 'dart:async' show unawaited;
import 'dart:io' show File, Platform;

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
  ///
  /// Mobile storage rule: phone exports are staged temp files (see
  /// `ReportService.saveReport`). Once this sheet closes, the file is
  /// scheduled for deferred deletion — the viewer/share target gets a grace
  /// window to finish reading, then it is removed so the sandbox never
  /// accumulates invisible exports. Desktop files are permanent and untouched.
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
    // All feedback now goes through the top AppFeedback overlay, so there is
    // no bottom ScaffoldMessenger snackbar left to hide here.

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

    // Phones keep the bottom sheet (thumb reach); desktops get a centered
    // half-screen dialog — a bottom sheet on a 1080p window looks broken and
    // forces the eye to the very bottom edge for two buttons.
    if (Platform.isAndroid || Platform.isIOS) {
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => _ExportSheet(
          filePath: filePath,
          documentName: documentName,
          delivery: delivery,
        ),
      );
      // Sheet gone = user opened and/or shared (or dismissed). Either way the
      // staged temp copy has served its purpose — remove it after a grace
      // window so the external viewer/share target finishes reading first.
      _deleteStagedAfterUse(filePath);
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding:
            const EdgeInsets.symmetric(horizontal: 64, vertical: 48),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            child: _ExportSheet(
              filePath: filePath,
              documentName: documentName,
              delivery: delivery,
            ),
          ),
        ),
      ),
    );
  }

  /// Whether [filePath] is a staged ephemeral share file (mobile temp cache).
  /// Only these are ever auto-deleted or treated as expirable — permanent
  /// desktop exports and user-configured folders are always passed through.
  static bool isStagedShareFile(String filePath) {
    final lowered = filePath.toLowerCase().replaceAll('\\', '/');
    return lowered.contains('/material_lab_share/') ||
        lowered.contains('/material_lab_pdf_') ||
        lowered.contains('/cache/');
  }

  /// Deferred deletion of a staged mobile share file. Only touches staged
  /// paths (see [isStagedShareFile]) — permanent desktop exports and
  /// user-configured folders are never deleted here.
  ///
  /// The grace delay lets the external viewer (OpenFilex) or the share-sheet
  /// target finish reading: both are handed the path and read lazily after
  /// our `reveal`/`share` future completes. Fire-and-forget on purpose.
  static void _deleteStagedAfterUse(
    String filePath, {
    Duration grace = const Duration(minutes: 2),
  }) {
    if (!isStagedShareFile(filePath)) return;
    unawaited(
      Future<void>.delayed(grace).then((_) async {
        try {
          final file = File(filePath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }),
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
                // Staged temp files are deleted after use (mobile storage
                // rule): a reopened sheet may point at a pruned file. Only
                // staged paths get this check — permanent exports and test
                // doubles pass straight through to the delivery port.
                if (AppFeedbackExport.isStagedShareFile(filePath) &&
                    !await File(filePath).exists()) {
                  if (!context.mounted) return;
                  AppFeedback.info(
                    context,
                    AppText.t(
                      'انتهت صلاحية الملف المؤقت — أعد إنشاء التقرير',
                      'Temporary file expired — please re-export the report',
                    ),
                  );
                  return;
                }
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
                if (AppFeedbackExport.isStagedShareFile(filePath) &&
                    !await File(filePath).exists()) {
                  if (!context.mounted) return;
                  AppFeedback.info(
                    context,
                    AppText.t(
                      'انتهت صلاحية الملف المؤقت — أعد إنشاء التقرير',
                      'Temporary file expired — please re-export the report',
                    ),
                  );
                  return;
                }
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
