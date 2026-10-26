import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/auth/session_source.dart';
import '../../../core/sync/remote/push_registration.dart';
import '../domain/push_event.dart';
import 'notification_delivery_store.dart';
import 'notification_service.dart';

/// Data-only high-priority pushes use the same durable delivery ledger as the
/// foreground and poll paths. No organization bootstrap or full sync is needed.
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  final event = PushEvent.fromData(message.data);
  // Legacy notification+data messages are already displayed by the OS.
  if (event == null) return;
  final delivery = NotificationDeliveryStore();
  try {
    if (!await delivery.claim(event)) return;
    if (message.notification != null) {
      await delivery.complete(event);
      return;
    }
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            NotificationService.channelId,
            NotificationService.channelName,
            description: NotificationService.channelDescription,
            importance: Importance.high,
          ),
        );
    final title = '${message.data['title'] ?? 'Material Lab'}';
    final body = '${message.data['body'] ?? ''}';
    await plugin.show(
      NotificationDeliveryStore.notificationId(event),
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          NotificationService.channelId,
          NotificationService.channelName,
          channelDescription: NotificationService.channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          tag: NotificationDeliveryStore.tag(event),
          onlyAlertOnce: true,
          styleInformation: BigTextStyleInformation(body),
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: event.payload,
    );
    await delivery.complete(event);
  } on Object catch (e) {
    try {
      await delivery.release(event);
    } on Object {
      /* Best effort. */
    }
    debugPrint('[fcm] background delivery failed: $e');
  } finally {
    await delivery.close();
  }
}

/// Foreground/tap lifecycle and private per-device token registration.
/// Closing the app keeps the binding so background delivery continues.
class FcmPushService {
  FcmPushService({
    required this.notifications,
    required this.source,
    required this.registration,
  });
  final NotificationService notifications;
  final SessionSource source;
  final PushRegistration registration;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _ready = false;
  Future<void>? _initializing;
  Future<void> _bindingWork = Future.value();
  String? _token;

  static void registerBackgroundHandler() {
    if (Platform.isAndroid || Platform.isIOS) {
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    }
  }

  Future<void> init() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (_ready) return;
    final pending = _initializing;
    if (pending != null) return pending;
    final work = _init();
    _initializing = work;
    try {
      await work;
    } finally {
      _initializing = null;
    }
  }

  Future<void> _init() async {
    try {
      registerBackgroundHandler();
      // Local presentation owns foreground alerts on both platforms.
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
            alert: false,
            badge: false,
            sound: false,
          );
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      _subscriptions.add(
        FirebaseMessaging.onMessage.listen((message) async {
          try {
            final event = PushEvent.fromData(message.data);
            if (event == null) return;
            await notifications.showOsNotificationsFromPush(
              title:
                  message.notification?.title ??
                  '${message.data['title'] ?? 'Material Lab'}',
              body:
                  message.notification?.body ?? '${message.data['body'] ?? ''}',
              event: event,
            );
          } on Object catch (e) {
            debugPrint('[fcm] foreground delivery failed: $e');
          }
        }),
      );
      _subscriptions.add(
        FirebaseMessaging.onMessageOpenedApp.listen((message) {
          final event = PushEvent.fromData(message.data);
          if (event != null) {
            unawaited(notifications.deliverPushPayload(event.payload));
          }
        }),
      );
      _subscriptions.add(
        FirebaseMessaging.instance.onTokenRefresh.listen((token) {
          unawaited(_registerToken(token));
        }),
      );
      _ready = true;
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      final initialEvent = initial == null
          ? null
          : PushEvent.fromData(initial.data);
      if (initialEvent != null) {
        await notifications.deliverPushPayload(initialEvent.payload);
      }
      await _registerToken(await FirebaseMessaging.instance.getToken());
    } on Object catch (e) {
      debugPrint('[fcm] init failed: $e');
    }
  }

  Future<void> _registerToken(String? token) async {
    if (token == null || token.isEmpty) return;
    try {
      final binding = await notifications.deliveryStore.binding();
      if (binding == null) return;
      final previous = _token;
      await registration.register(
        organizationId: binding.organizationId,
        uid: binding.uid,
        deviceId: binding.deviceId,
        token: token,
      );
      _token = token;
      if (previous != null && previous != token) {
        await registration.unregister(
          organizationId: binding.organizationId,
          uid: binding.uid,
          token: previous,
        );
      }
    } on Object catch (e) {
      debugPrint('[fcm] token registration failed: $e');
    }
  }

  Future<void> setOrganization(String? organizationId) {
    if (!Platform.isAndroid && !Platform.isIOS) return Future.value();
    // Capture this session before another bind can replace it.
    final session = source.session;
    final next =
        organizationId == null ||
            organizationId.isEmpty ||
            !session.isSignedIn ||
            session.organizationId != organizationId
        ? null
        : PushBinding(
            organizationId: organizationId,
            uid: session.uid,
            deviceId: session.deviceId,
            samples: session.can(Permission.samplesRead),
            lab: session.can(Permission.labResultsRead),
          );
    _bindingWork = _bindingWork.catchError((Object _) {}).then((_) async {
      final previous = await notifications.deliveryStore.binding();
      // Disable delivery first, including on an offline sign-out.
      await notifications.deliveryStore.bind(next);
      // Legacy topic cleanup must never prevent a current token registration.
      try {
        if (previous != null) {
          await FirebaseMessaging.instance.unsubscribeFromTopic(
            'org_${previous.organizationId}',
          );
        }
        if (next != null) {
          await FirebaseMessaging.instance.unsubscribeFromTopic(
            'org_${next.organizationId}',
          );
        }
      } on Object catch (e) {
        debugPrint('[fcm] legacy topic cleanup failed: $e');
      }
      if (previous != null &&
          _token != null &&
          (next?.organizationId != previous.organizationId ||
              next?.uid != previous.uid)) {
        try {
          await registration.unregister(
            organizationId: previous.organizationId,
            uid: previous.uid,
            token: _token!,
          );
        } on Object catch (e) {
          debugPrint('[fcm] old token cleanup failed: $e');
        }
      }
      if (next != null && _ready) {
        await _registerToken(
          _token ?? await FirebaseMessaging.instance.getToken(),
        );
      }
    });
    return _bindingWork;
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _ready = false;
  }
}
