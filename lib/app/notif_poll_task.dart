import 'dart:io';

import 'package:flutter/widgets.dart' show debugPrint;
import 'package:workmanager/workmanager.dart';

import 'background_tasks.dart'
    show backgroundTaskDispatcher, ensureBackgroundInitialized;

/// Android periodic new-item poll (mobile-only) — the OFFLINE fallback.
///
/// Primary killed-app path is FCM push (see `fcm_push_service.dart` + Cloud
/// Function `functions/index.js`): Play services deliver it even when the app
/// is force-stopped, where no poll can run. This poll covers the offline /
/// FCM-less gap: every 15 min (Android clamp) it pulls remote rows, then shows
/// one OS notification per new inspection / lab result. Tapping it opens the
/// matching screen via the payload handled in `AppShell` + `NotificationBell`.
///
/// Workmanager persists periodic work across reboots (it re-registers with
/// JobScheduler on RECEIVE_BOOT_COMPLETED internally), but a force-stop
/// clears it — `startNotifications()` re-schedules on every foreground start
/// to heal that. `ExistingPeriodicWorkPolicy.keep` avoids the cancel/schedule
/// storm on every boot.
///
/// Mirrors `auto_backup_task.dart`: workmanager runs this in a separate
/// isolate with empty getIt, so bootstrap is re-run first.
class AndroidNotifPollScheduler {
  const AndroidNotifPollScheduler();

  static const String taskName = 'material_lab_notif_poll';
  static const Duration frequency = Duration(minutes: 15);

  bool get isScheduled => Platform.isAndroid;

  Future<void> schedule() async {
    if (!isScheduled) return;
    try {
      // Shared dispatcher (see background_tasks.dart): workmanager allows
      // only one per process, shared with the auto-backup task.
      await ensureBackgroundInitialized();
      await Workmanager().registerPeriodicTask(
        taskName,
        taskName,
        frequency: frequency,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 5),
      );
    } on Object catch (e) {
      debugPrint('[notif] could not schedule poll task: $e');
    }
  }

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
void notifPollCallbackDispatcher() => backgroundTaskDispatcher();
