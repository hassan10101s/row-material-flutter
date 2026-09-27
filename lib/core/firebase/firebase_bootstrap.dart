import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show AssetBundle;

import 'firebase_options.dart';

/// Outcome of the Firebase start-up probe (never throws at the caller).
enum FirebaseStatus { ready, unconfigured, failed }

/// Result object so the app can degrade instead of crashing (plan §8.1
/// `needsBootstrap` ⇒ configuration screen).
class FirebaseBootstrapResult {
  const FirebaseBootstrapResult({
    required this.status,
    this.config = const FirebaseConfig(),
    this.error,
  });

  final FirebaseStatus status;
  final FirebaseConfig config;
  final Object? error;

  bool get isReady => status == FirebaseStatus.ready;
  bool get isUnconfigured => status == FirebaseStatus.unconfigured;

  List<String> get missingKeys => config.missingKeys;
}

/// Initialises `Firebase.initializeApp` exactly once, capturing every failure.
class FirebaseBootstrap {
  FirebaseBootstrap._();

  static bool _initialized = false;

  static Future<FirebaseBootstrapResult> initialize({AssetBundle? bundle}) async {
    try {
      final config = await FirebaseConfig.load(bundle: bundle);
      if (!config.isConfigured) {
        return FirebaseBootstrapResult(
          status: FirebaseStatus.unconfigured,
          config: config,
        );
      }
      if (_initialized) {
        return FirebaseBootstrapResult(status: FirebaseStatus.ready, config: config);
      }
      await Firebase.initializeApp(options: config.toOptions());
      _initialized = true;
      return FirebaseBootstrapResult(status: FirebaseStatus.ready, config: config);
    } catch (error, stack) {
      if (kDebugMode) {
        debugPrint('[firebase] initialize failed: $error\n$stack');
      }
      return FirebaseBootstrapResult(status: FirebaseStatus.failed, error: error);
    }
  }

  /// Test hook: forget that `initializeApp` already ran.
  static void resetForTesting() => _initialized = false;
}
