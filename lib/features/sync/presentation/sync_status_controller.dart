import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/sync/sync_metadata.dart';
import '../../../core/sync/sync_queue.dart';

/// Everything the topbar badge shows (plan §14-P8.1): the connectivity state,
/// how much is still waiting to be pushed and when the last exchange with the
/// server happened.
///
/// A plain value object on purpose: the widget takes it as a parameter so it
/// can be rendered in a test without any DI or database.
@immutable
class SyncBadgeStatus {
  const SyncBadgeStatus({
    required this.online,
    this.pending = 0,
    this.blocked = 0,
    this.lastSync,
  });

  final bool online;

  /// Rows in `sync_queue` with status `pending`/`in_flight`.
  final int pending;

  /// Rows parked as `failed`/`conflict` - they need a human.
  final int blocked;

  /// Last successful push or pull, whichever is more recent.
  final DateTime? lastSync;

  bool get hasWork => pending > 0 || blocked > 0;

  SyncBadgeStatus copyWith({
    bool? online,
    int? pending,
    int? blocked,
    DateTime? lastSync,
  }) =>
      SyncBadgeStatus(
        online: online ?? this.online,
        pending: pending ?? this.pending,
        blocked: blocked ?? this.blocked,
        lastSync: lastSync ?? this.lastSync,
      );
}

/// Feeds [SyncBadge] from the real services: the connectivity signal, the
/// queue counters and the sync metadata. Read-only - it never triggers a sync
/// itself, the badge only reports the truth (plan §14-P8.1).
class SyncStatusController extends ChangeNotifier {
  SyncStatusController({
    required this.queue,
    required this.metadata,
    required bool Function() isOnline,
    Stream<bool>? connectivityChanges,
    this.refreshInterval = const Duration(seconds: 20),
  })  : _isOnline = isOnline,
        _status = SyncBadgeStatus(online: isOnline()) {
    _subscription = connectivityChanges?.listen((online) {
      _status = _status.copyWith(online: online);
      notifyListeners();
      if (online) unawaited(refresh());
    });
  }

  final SyncQueue queue;
  final SyncMetadata metadata;
  final Duration refreshInterval;
  final bool Function() _isOnline;

  StreamSubscription<bool>? _subscription;
  Timer? _timer;
  SyncBadgeStatus _status;

  SyncBadgeStatus get status => _status;

  /// Starts the periodic refresh and reads the counters once.
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
    unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      final pending = await queue.countPending();
      final blocked = await queue.countBlocked();
      final push = await metadata.lastPushAt();
      final pull = await metadata.lastPullAt();
      final last = _latest(push, pull);
      final next = SyncBadgeStatus(
        online: _isOnline(),
        pending: pending,
        blocked: blocked,
        lastSync: last,
      );
      if (next.online != _status.online ||
          next.pending != _status.pending ||
          next.blocked != _status.blocked ||
          next.lastSync != _status.lastSync) {
        _status = next;
        notifyListeners();
      }
    } on Object {
      // A badge must never break the shell: keep the last known values.
    }
  }

  static DateTime? _latest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}
