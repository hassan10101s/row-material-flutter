import 'dart:io';

import 'package:flutter/widgets.dart' show WidgetsFlutterBinding, debugPrint;
import 'package:workmanager/workmanager.dart';

import '../core/platform/platform_capability.dart';

import '../core/sync/sync_engine.dart';
import '../di/service_locator.dart';
import '../features/backup/data/backup_manager.dart';
import '../features/notifications/data/notification_service.dart';
import 'app_bootstrap.dart';
import 'auto_backup_task.dart';
import 'headless.dart';
import 'notif_poll_task.dart';

bool _workmanagerInitialized = false;

/// Single workmanager dispatcher for the whole app.
///
/// workmanager allows exactly ONE callback dispatcher per process: the backup
/// scheduler and the notification poll must share it, otherwise the second
/// `initialize()` throws and one of the two tasks never runs. Both task names
/// are routed here; unknown names succeed silently.
@pragma('vm:entry-point')
void backgroundTaskDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      if (task == AndroidNotifPollScheduler.taskName) {
        isHeadlessBackground = true;
        await appBootstrap();
        try {
          await getIt<SyncEngine>().syncNow(
            reason: 'notif-poll',
            pullOnly: true,
          );
        } on Object catch (e) {
          debugPrint('[notif] background pull skipped: $e');
        }
        final service = getIt<NotificationService>();
        await service.initOs(requestPermission: false);
        final found = await service.checkForNew(showOs: false);
        await service.showOsNotifications(found);
        // appBootstrap() starts the sync engine when the session is ready:
        // stop it before the isolate exits so its timers do not keep the
        // database open and contend with the foreground process on the
        // next poll (SQLITE_BUSY / BEGIN EXCLUSIVE stalls).
        try {
          getIt<SyncEngine>().stop();
        } on Object catch (e) {
          debugPrint('[notif] background engine stop skipped: $e');
        }
        return true;
      }
      if (task == AndroidBackupScheduler.taskName) {
        isHeadlessBackground = true;
        await appBootstrap();
        await getIt<BackupManager>().autoBackup();
        return true;
      }
      return true;
    } on Object catch (e) {
      // Success on failure: returning false retries with backoff forever,
      // and a revoked key / missing org would retry without end.
      debugPrint('[background] task $task failed: $e');
      return true;
    }
  });
}

/// Idempotent initializer shared by every scheduler: the second caller in the
/// same process is a no-op instead of a throwing re-initialize.
///
/// Desktop best-practice: hard no-op off Android. `workmanager` has no Windows
/// registrant (no MSIX/EXE background task), so calling `initialize` there
/// throws `MissingPluginException`. [PlatformCapability.canScheduleBackground]
/// is the single gate; schedulers additionally guard via their own `isScheduled`.
Future<void> ensureBackgroundInitialized() async {
  if (!PlatformCapability.canScheduleBackground) {
    debugPrint('[background] skipped: workmanager is Android-only '
        '(platform=${Platform.operatingSystem})');
    return;
  }
  if (_workmanagerInitialized) return;
  try {
    await Workmanager().initialize(backgroundTaskDispatcher);
    _workmanagerInitialized = true;
  } on Object catch (e) {
    // Never crash boot for a background convenience (esp. sideloaded EXE
    // without the MSIX background-task declaration).
    debugPrint('[background] initialize skipped: $e');
  }
}
