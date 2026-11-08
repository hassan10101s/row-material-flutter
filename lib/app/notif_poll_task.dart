import 'dart:io';

import 'package:workmanager/workmanager.dart';

import 'background_tasks.dart' show backgroundTaskDispatcher;

/// Android periodic new-item poll (mobile-only) — the OFFLINE fallback.
///
/// Primary killed-app path is FCM push (see `fcm_push_service.dart`): Play
/// services can wake the background
/// handler after ordinary process termination. Android Settings force-stop
/// requires reopening the app. This poll covers the offline /
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
    await cancel();
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
