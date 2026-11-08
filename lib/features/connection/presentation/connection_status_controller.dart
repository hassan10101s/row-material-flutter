import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/sync/sync_metadata.dart';

/// Connection and read-only cache refresh status. No upload controls.
@immutable
class ConnectionStatus {
  const ConnectionStatus({
    required this.online,
    this.lastSync,
    this.hasError = false,
    this.pullIncomplete = false,
  });

  final bool online;
  final bool hasError;
  final bool pullIncomplete;

  /// Last successful refresh of approved server data.
  final DateTime? lastSync;

  ConnectionStatus copyWith({
    bool? online,
    DateTime? lastSync,
    bool? hasError,
    bool? pullIncomplete,
  }) => ConnectionStatus(
    online: online ?? this.online,
    lastSync: lastSync ?? this.lastSync,
    hasError: hasError ?? this.hasError,
    pullIncomplete: pullIncomplete ?? this.pullIncomplete,
  );
}

/// Observes connectivity and download metadata; never sends business writes.
class ConnectionStatusController extends ChangeNotifier {
  ConnectionStatusController({
    required this.metadata,
    this.centralReady,
    this.onRefreshData,
    required bool Function() isOnline,
    Stream<bool>? connectivityChanges,
    this.refreshInterval = const Duration(seconds: 20),
  }) : _isOnline = isOnline,
       _status = ConnectionStatus(online: isOnline()) {
    _subscription = connectivityChanges?.listen((online) {
      _status = _status.copyWith(online: online);
      notifyListeners();
      if (online) unawaited(refresh());
    });
  }

  final SyncMetadata metadata;

  /// When supplied, only central requests and central bootstrap status count.
  final Future<bool> Function()? centralReady;
  final Duration refreshInterval;
  final Future<void> Function()? onRefreshData;
  Future<void> refreshData() async {
    await onRefreshData?.call();
    await refresh();
  }

  final bool Function() _isOnline;

  StreamSubscription<bool>? _subscription;
  Timer? _timer;
  Timer? _startTimer;
  ConnectionStatus _status;

  /// A refresh already waiting on the connection. Overlapping ticks skip
  /// instead of queueing duplicate reads behind a long write.
  bool _refreshing = false;

  ConnectionStatus get status => _status;

  /// Periodically refreshes local status without contacting the server.
  void start({Duration initialDelay = const Duration(milliseconds: 1500)}) {
    if (_timer != null) return;
    _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
    if (initialDelay == Duration.zero) {
      unawaited(refresh());
    } else {
      _startTimer = Timer(initialDelay, () {
        _startTimer = null;
        if (_timer != null) unawaited(refresh());
      });
    }
  }

  /// A failing local read preserves the last known connection status.
  Future<void> refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final results = await Future.wait<Object?>([
        metadata.readAll([
          SyncMetadata.lastPushAtKey,
          SyncMetadata.lastPullAtKey,
          SyncMetadata.lastErrorKey,
          SyncMetadata.pullIncompleteKey,
        ]),

        if (centralReady != null) centralReady!(),
      ]);
      final keys = results[0] as Map<String, String>;
      final push = _asDate(keys[SyncMetadata.lastPushAtKey]);
      final pull = _asDate(keys[SyncMetadata.lastPullAtKey]);
      final ready = centralReady == null ? true : results.last as bool;
      final last = centralReady == null ? _latest(push, pull) : pull;
      final next = ConnectionStatus(
        online: _isOnline(),
        lastSync: last,
        hasError: (keys[SyncMetadata.lastErrorKey] ?? '').isNotEmpty,
        pullIncomplete: centralReady == null
            ? keys[SyncMetadata.pullIncompleteKey] == '1'
            : !ready,
      );
      if (next.online != _status.online ||
          next.lastSync != _status.lastSync ||
          next.hasError != _status.hasError ||
          next.pullIncomplete != _status.pullIncomplete) {
        _status = next;
        notifyListeners();
      }
    } on Object {
      // A badge must never break the shell: keep the last known values.
    } finally {
      _refreshing = false;
    }
  }

  static DateTime? _latest(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  static DateTime? _asDate(String? iso) =>
      (iso == null || iso.isEmpty) ? null : DateTime.tryParse(iso);

  @override
  void dispose() {
    _startTimer?.cancel();
    _startTimer = null;
    _timer?.cancel();
    _timer = null;
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}
