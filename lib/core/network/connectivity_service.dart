import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Online/offline signal for the sync engine and the status badge.
///
/// `connectivity_plus` only reports that an interface is up, so this service
/// adds a real reachability probe (`InternetAddress.lookup`) before reporting
/// "online" (plan §14-P1.4).
class ConnectivityService {
  ConnectivityService({Connectivity? connectivity, this.probeTimeout = const Duration(seconds: 3)})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  final Duration probeTimeout;

  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  bool _online = false;
  bool _started = false;
  bool _probeInFlight = false;

  bool get isOnline => _online;

  Stream<bool> get onStatusChange => _controller.stream;

  /// Start listening. Safe to call more than once.
  void start() {
    if (_started) return;
    _started = true;
    _subscription = _connectivity.onConnectivityChanged.listen((results) async {
      await _evaluate(results);
    });
    _connectivity.checkConnectivity().then((results) => _evaluate(results)).catchError((_) {
      _publish(false);
    });
  }

  Future<void> _evaluate(List<ConnectivityResult> results) async {
    final interfaceUp = results.isNotEmpty &&
        results.any((r) => r != ConnectivityResult.none);
    if (!interfaceUp) {
      _publish(false);
      return;
    }
    _publish(await _hasInternet());
  }

  /// True when at least one interface is up *and* DNS/HTTP reachability works.
  Future<bool> hasInternet() => _hasInternet();

  Future<bool> _hasInternet() async {
    if (_probeInFlight) return _online;
    _probeInFlight = true;
    try {
      final result = await InternetAddress.lookup('firebaseinstallations.googleapis.com')
          .timeout(probeTimeout);
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } on Object {
      return false;
    } finally {
      _probeInFlight = false;
    }
  }

  void _publish(bool value) {
    if (_online == value) return;
    _online = value;
    if (!_controller.isClosed) _controller.add(value);
  }

  /// Force a refresh (used by the manual "sync now" button and by tests).
  Future<void> refresh() async {
    try {
      final results = await _connectivity.checkConnectivity();
      await _evaluate(results);
    } on Object {
      _publish(false);
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _started = false;
    await _controller.close();
  }
}
