import 'notification_item.dart';

/// The notification surface presentation is allowed to see.
///
/// Implementation: `data/notification_service.dart` (`NotificationService`),
/// a data-layer class that owns the OS plugin handles and the seen-marker
/// bookkeeping. Presenting layers get this contract instead, so the bell and
/// the shell never drag the `flutter_local_notifications` plugin graph into
/// their type world. Registered in the DI as the same instance
/// `NotificationService` (see `di/service_locator.dart`).
abstract class NotificationsPort {
  // ── Bell data ─────────────────────────────────────────────────────────

  /// Scans the local ledgers for items newer than the stored seen markers,
  /// stores and returns the new ones (respecting both toggles).
  Future<List<NotificationItem>> checkForNew({
    required bool inspectionEnabled,
    required bool labEnabled,
    bool showOs = false,
  });

  /// Most recent rows for the bell list, newest first.
  Future<List<NotificationItem>> recent({int limit = 30});

  /// Count of rows with `read_at` empty.
  Future<int> unreadCount();

  /// Stamp one row as read.
  Future<void> markRead(int id);

  /// Stamp every row as read (the bell "mark all" action).
  Future<void> markAllRead();

  // ── Deep-link routing ─────────────────────────────────────────────────

  /// The payload of a tapped OS notification that arrived before any
  /// listener was attached (killed-app cold start), or null.
  String? get pendingPayload;

  /// Consume the pending payload: set null so a re-run does not re-route.
  set pendingPayload(String? value);

  /// Attach a mid-session tap handler.
  void addPayloadListener(void Function(String payload) callback);

  /// Detach a handler attached with [addPayloadListener].
  void removePayloadListener(void Function(String payload) callback);
}
