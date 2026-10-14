import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_service.dart';

/// Killed-app push path (FCM).
///
/// Why this file exists: `Workmanager` periodic polls (15 min, in
/// `notif_poll_task.dart`) only run while Android lets the app live in the
/// background. Once the user swipes the app away / the OEM kills it / Doze
/// stops jobs, polls stop too. FCM is delivered by Google Play services, not
/// by our process, so it arrives even when the app is force-stopped and shows
/// a system tray notification without any of our code running.
///
/// Architecture:
/// ```
/// Firestore write (samples / labResults / productBatchSamples)
///   -> Cloud Function `functions/index.js` (onDocumentCreated)
///   -> FCM send to topic `org_<orgId>` (notification + data payload)
///   -> Android system tray (killed) / onMessage (foreground) /
///      background handler below (background, data-only)
///   -> tap -> payload `inspection:<id>` / `lab:<id>` -> router deep-link
/// ```
///
/// The Cloud Function builds the same useful bilingual body as
/// [NotificationService] (supplier • qty • verdict • result) so the push is
/// informative on its own.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } on Object catch (_) {
    // Already initialized in the foreground isolate or no Default options
    // on this build flavor: still try to show the notification below.
  }
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(const InitializationSettings(android: android));
    const channel = AndroidNotificationChannel(
      NotificationService.channelId,
      NotificationService.channelName,
      description: NotificationService.channelDescription,
      importance: Importance.high,
    );
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
    final data = message.data;
    final title = message.notification?.title ??
        '${data['title'] ?? 'MaterialLab'}';
    final body =
        message.notification?.body ?? '${data['body'] ?? ''}'.trim();
    final payload = '${data['payload'] ?? ''}'.trim();
    await plugin.show(
      message.hashCode,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          NotificationService.channelId,
          NotificationService.channelName,
          channelDescription: NotificationService.channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          styleInformation:
              body.isEmpty ? null : BigTextStyleInformation(body),
        ),
      ),
      payload: payload.isEmpty ? null : payload,
    );
  } on Object catch (e) {
    debugPrint('[fcm] background show skipped: $e');
  }
}

/// Foreground + tap + token/topic manager. Mobile only; every method is a
/// no-op on desktop and never throws (push must not break boot).
class FcmPushService {
  FcmPushService({required this.notifications});

  final NotificationService notifications;

  bool _ready = false;
  String? _topic;

  /// Call once after [NotificationService.initOs], post-first-frame.
  /// Registers the background handler, asks permission (Android 13+ / iOS),
  /// shows foreground messages as local notifications, and routes taps.
  Future<void> init({
    Future<void> Function(String payload)? onTap,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (_ready) return;
    try {
      FirebaseMessaging.onBackgroundMessage(
        firebaseMessagingBackgroundHandler,
      );
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      // Foreground: FCM does NOT show a tray automatically — render it
      // through the same channel so it looks identical to killed-app pushes.
      FirebaseMessaging.onMessage.listen((message) async {
        try {
          final data = message.data;
          final title = message.notification?.title ??
              '${data['title'] ?? 'MaterialLab'}';
          final body =
              message.notification?.body ?? '${data['body'] ?? ''}'.trim();
          final payload = '${data['payload'] ?? ''}'.trim();
          if (payload.isNotEmpty) {
            // Remember deep-link even if the user taps the bell instead.
            notifications.pendingPayload = payload;
          }
          await notifications.initOs(requestPermission: false);
          await notifications.showOsNotificationsFromPush(
            title: title,
            body: body,
            payload: payload.isEmpty ? null : payload,
          );
        } on Object catch (e) {
          debugPrint('[fcm] foreground show skipped: $e');
        }
      });
      // Background tap (app was in background, not killed).
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        final payload = '${message.data['payload'] ?? ''}'.trim();
        if (payload.isNotEmpty) {
          notifications.pendingPayload = payload;
          onTap?.call(payload);
        }
      });
      // Killed-app tap: system launched the app from the tray.
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      final initialPayload =
          '${initial?.data['payload'] ?? ''}'.trim();
      if (initialPayload.isNotEmpty) {
        notifications.pendingPayload = initialPayload;
      }
      // Token refresh: Cloud Functions target topics, so no server upload is
      // strictly required; keep the hook for future per-device sends.
      FirebaseMessaging.instance.onTokenRefresh.listen((_) {});
      _ready = true;
    } on Object catch (e) {
      debugPrint('[fcm] init skipped: $e');
    }
  }

  /// Subscribe this device to `org_<orgId>` so the Cloud Function fan-out
  /// reaches every member device even when the app is killed. Call on every
  /// org bind / app start; unsubscribes the previous org automatically.
  Future<void> setOrganization(String? orgId) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      final next =
          (orgId == null || orgId.isEmpty) ? null : 'org_$orgId';
      if (_topic != null && _topic != next) {
        try {
          await FirebaseMessaging.instance.unsubscribeFromTopic(_topic!);
        } on Object catch (e) {
          debugPrint('[fcm] unsubscribe skipped: $e');
        }
      }
      _topic = next;
      if (next != null) {
        await FirebaseMessaging.instance.subscribeToTopic(next);
        debugPrint('[fcm] subscribed to $next');
      }
    } on Object catch (e) {
      debugPrint('[fcm] topic skipped: $e');
    }
  }

  Future<void> dispose() async {
    if (_topic != null) {
      try {
        await FirebaseMessaging.instance.unsubscribeFromTopic(_topic!);
      } on Object {
        // Best effort.
      }
      _topic = null;
    }
  }
}
