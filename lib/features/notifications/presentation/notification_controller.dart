import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/notification_service.dart';
import '../domain/notification_item.dart';

/// Bell-badge state fed by [NotificationService]. Mobile only.
class NotificationController extends ChangeNotifier {
  NotificationController(this.service);

  final NotificationService service;

  List<NotificationItem> items = const [];
  int unread = 0;
  bool inspectionEnabled = true;
  bool labEnabled = true;
  Timer? _timer;

  Future<void> refresh({bool showOs = false}) async {
    final found = await service.checkForNew(
      inspectionEnabled: inspectionEnabled,
      labEnabled: labEnabled,
      showOs: showOs,
    );
    if (found.isNotEmpty || items.isEmpty) {
      // One wait for both bell reads instead of two sequential round trips.
      final settled =
          await Future.wait([service.recent(), service.unreadCount()]);
      items = settled[0] as List<NotificationItem>;
      unread = settled[1] as int;
    } else {
      unread = await service.unreadCount();
    }
    notifyListeners();
  }

  Future<void> load() async {
    final settled =
        await Future.wait([service.recent(), service.unreadCount()]);
    items = settled[0] as List<NotificationItem>;
    unread = settled[1] as int;
    notifyListeners();
  }

  void startAutoRefresh({
    Duration interval = const Duration(seconds: 30),
    bool showOs = false,
  }) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(refresh(showOs: showOs)));
  }

  Future<void> markRead(NotificationItem item) async {
    await service.markRead(item.id);
    await load();
  }

  Future<void> markAllRead() async {
    await service.markAllRead();
    await load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
