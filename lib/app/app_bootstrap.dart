import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show debugPrint;

import '../core/firebase/firebase_bootstrap.dart';
import '../core/network/connectivity_service.dart';
import '../core/sync/sync_engine.dart';
import '../core/sync/sync_queue.dart';
import '../di/service_locator.dart';
import '../features/notifications/data/fcm_push_service.dart';
import '../features/notifications/data/notification_service.dart';
import '../features/notifications/presentation/notification_controller.dart';
import 'headless.dart';
import 'notif_poll_task.dart';
import 'auth_gate.dart';
import '../features/auth/domain/auth_repository.dart';

/// Startup sequence (plan §8.1 + §6.5).
///
/// ```
/// boot → FirebaseBootstrap
///      → restoreSession()          (online: users/{uid} · offline: session cache)
///      → bindOrg(orgId)            (per-organization database, then the seeds
///                                   below run against it, then the sync engine)
///      → SyncEngine.start()
/// ```
/// Everything after [FirebaseBootstrap.initialize] is safe without Firebase: the
/// app degrades to the cached session or to the `needsBootstrap` state.
Future<void> appBootstrap() async {
  await initServiceLocator();
  if (!isHeadlessBackground && getIt<FirebaseBootstrapResult>().isReady) {
    FcmPushService.registerBackgroundHandler();
  }

  final auth = getIt<AuthRepository>();
  await registerOrganizationBinder(auth);

  // Keep the shell + router guards in sync with the auth state stream
  // (sign-in, sign-out, organization switch, refresh failures).
  getIt<AuthGate>().start();

  // Auth must know reachability before choosing the cached-session path.
  // Previously connectivity only started inside sync, after auth restoration.
  final connectivity = getIt<ConnectivityService>();
  await connectivity.refresh();
  if (!isHeadlessBackground) connectivity.start();
  final state = await auth.restoreSession();
  debugPrint('[bootstrap] auth state: ${state.name}');

  if (state == AuthState.needsBootstrap) {
    debugPrint(
      '[bootstrap] firebase missing: ${getIt<FirebaseBootstrapResult>().missingKeys}',
    );
    return;
  }

  if (state == AuthState.ready) {
    startSyncEngine();
    // Notifications are deliberately NOT awaited here: plugin init plus the
    // bell scans would hold up the first frame behind the FFI lock. `main()`
    // runs [startNotifications] after the first frame; headless background
    // isolates drive the service directly and never call it.
  }
}

/// Mobile-only: OS plugin init + first scan + pull/local hooks.
/// No-op on desktop so Windows builds never touch the plugin, and no-op in
/// the headless background isolate (the dispatcher drives the scan + show
/// directly; timers and re-scheduling belong to the foreground process).
Future<void> startNotifications() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  if (isHeadlessBackground) return;
  try {
    final service = getIt<NotificationService>();
    await service.initOs(requestPermission: false);
    final controller = getIt<NotificationController>();
    final engine = getIt<SyncEngine>();
    // Remote rows (other devices) -> bell + OS notification after every pull
    // with applied rows. showOs must be true here: with false (the old code)
    // foreground pulls only updated the in-app bell and the system tray
    // stayed silent until the 15-min background poll ran.
    engine.onPullApplied = () => controller.refresh(showOs: true);
    // Own saves -> bell within seconds. Chains the engine's debounced push
    // (buildSyncEngine sets onEnqueued to scheduleSync).
    final queue = getIt<SyncQueue>();
    queue.onEnqueued = () {
      engine.scheduleSync();
      unawaited(controller.refresh());
    };
    // One pass, not two: `refresh` already loads `recent` + `unread` when the
    // bell starts empty, so the extra `load()` was two duplicate DB trips on
    // every mobile start.
    await controller.refresh();
    // The 30 s tick also surfaces OS notifications: own saves are already
    // watermarked silently by the onEnqueued hook above, so only rows from
    // other devices reach showOs here.
    controller.startAutoRefresh(showOs: true);
    // Push delivery uses private registered devices. Android force-stop from
    // settings still requires reopening the app; periodic polls are a fallback.
    try {
      final fcm = getIt<FcmPushService>();
      await fcm.init();
      final orgId = getIt<AuthRepository>().session.organizationId;
      await fcm.setOrganization(orgId.isEmpty ? null : orgId);
    } on Object catch (e) {
      debugPrint('[bootstrap] fcm skipped: $e');
    }
    // Background poll so closed-app arrivals surface as OS notifications.
    try {
      await const AndroidNotifPollScheduler().schedule();
    } on Object catch (e) {
      debugPrint('[bootstrap] notif poll schedule skipped: $e');
    }
  } on Object catch (e) {
    debugPrint('[bootstrap] notifications skipped: $e');
  }
}

/// Runs the per-organization side effects. The callback itself lives in
/// `registerOrganizationBinder` (service_locator) so the repository never has
/// to import a feature module.
void startSyncEngine() {
  // Workmanager owns one awaited pull/backup. Starting the foreground loop
  // here launched an unawaited extra cycle that could outlive its engine.
  if (isHeadlessBackground) return;
  getIt<SyncEngine>().start();
}

/// Sign out and clear the in-memory session after a database restore.
Future<void> resetAfterRestore() async {
  final auth = getIt<AuthRepository>();
  await auth.signOut();
}

/// Local → remote calls are impossible after a sign-out.
bool get isWritableSession {
  final auth = getIt<AuthRepository>();
  return auth.state == AuthState.ready;
}
