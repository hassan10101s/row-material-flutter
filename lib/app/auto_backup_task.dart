import 'dart:io';

import 'package:flutter/widgets.dart' show debugPrint;
import 'package:workmanager/workmanager.dart';

import '../core/platform/auto_backup_scheduler.dart';
import 'background_tasks.dart'
    show backgroundTaskDispatcher, ensureBackgroundInitialized;

/// The Android periodic-backup adapter and its workmanager entry point.
///
/// Lives in the app layer because workmanager's dispatcher runs in a
/// **separate isolate** that never executed `main()`: `getIt` is empty there
/// and the organization binding has to be redone before there is a database to
/// back up. The port itself is `core/platform/auto_backup_scheduler.dart`.
class AndroidBackupScheduler implements AutoBackupScheduler {
  const AndroidBackupScheduler();

  /// Stable across versions - workmanager dedupes on it, and [cancel] matches
  /// the name [schedule] registered.
  static const String taskName = 'material_lab_auto_backup';

  /// Android clamps a periodic request to 15 minutes unless the app asks for a
  /// foreground service, which a backup does not justify. The *policy* - how
  /// many automatic backups to keep - belongs to `BackupManager`
  /// (`_autoBackupRetention`); this only guarantees the process wakes up.
  static const Duration frequency = Duration(minutes: 15);

  @override
  bool get isScheduled => Platform.isAndroid;

  @override
  Future<void> schedule() async {
    if (!isScheduled) return;
    try {
      // Shared dispatcher (see background_tasks.dart): workmanager allows
      // only one per process, shared with the notification poll.
      await ensureBackgroundInitialized();
      await Workmanager().registerPeriodicTask(
        taskName,
        taskName,
        frequency: frequency,
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } on Object catch (error) {
      // A device that refuses background work is a degraded device, not a
      // broken app. The next foreground launch retries, and the UI reports
      // `isScheduled` so the user is not told a backup is coming when none is.
      debugPrint('[backup] could not schedule the periodic task: $error');
    }
  }

  @override
  Future<void> cancel() async {
    if (!isScheduled) return;
    try {
      await Workmanager().cancelByUniqueName(taskName);
    } on Object {
      // Nothing was registered.
    }
  }
}

/// Legacy alias: the single shared dispatcher lives in `background_tasks.dart`.
/// Kept so any existing native registration referencing this name keeps
/// resolving; it forwards to the shared dispatcher.
@pragma('vm:entry-point')
void autoBackupCallbackDispatcher() => backgroundTaskDispatcher();
