import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/notifications_port.dart';
import '../domain/notification_item.dart';

/// Bell-badge state fed by the [NotificationsPort] (the data-layer
/// `NotificationService`, behind its contract). Mobile only.
class NotificationController extends ChangeNotifier {
  NotificationController(this.service);

  final NotificationsPort service;

  List<NotificationItem> items = const [];
  int unread = 0;
  bool inspectionEnabled = true;
  bool labEnabled = true;
  Timer? _timer;
  int _generation = 0;

  void resetForSession() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    items = const [];
    unread = 0;
    notifyListeners();
  }

  Future<void> refresh({bool showOs = false}) async {
    final generation = _generation;
    final found = await service.checkForNew(
      inspectionEnabled: inspectionEnabled,
      labEnabled: labEnabled,
      showOs: showOs,
    );
    if (generation != _generation) return;
    if (found.isNotEmpty || items.isEmpty) {
      // One wait for both bell reads instead of two sequential round trips.
      final settled = await Future.wait([
        service.recent(),
        service.unreadCount(),
      ]);
      if (generation != _generation) return;
      items = settled[0] as List<NotificationItem>;
      unread = settled[1] as int;
    } else {
      final count = await service.unreadCount();
      if (generation != _generation) return;
      unread = count;
    }
    notifyListeners();
  }

  Future<void> load() async {
    final generation = _generation;
    final settled = await Future.wait([
      service.recent(),
      service.unreadCount(),
    ]);
    if (generation != _generation) return;
    items = settled[0] as List<NotificationItem>;
    unread = settled[1] as int;
    notifyListeners();
  }

  void startAutoRefresh({
    Duration interval = const Duration(seconds: 30),
    bool showOs = false,
  }) {
    _timer?.cancel();
    _timer = Timer.periodic(
      interval,
      (_) => unawaited(refresh(showOs: showOs)),
    );
  }

  Future<void> markRead(NotificationItem item) async {
    final generation = _generation;
    await service.markRead(item.id);
    if (generation == _generation) await load();
  }

  Future<void> markAllRead() async {
    final generation = _generation;
    await service.markAllRead();
    if (generation == _generation) await load();
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    super.dispose();
  }
}
