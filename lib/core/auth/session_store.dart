import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_session.dart';

/// Encrypted cache of the last session so the app can be opened **offline**
/// (plan §8.4). It grants no new permission: the cached token is only used for
/// read-only local work, and every remote write still requires a live token.
class SessionStore {
  SessionStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // `resetOnError` is what makes a **restored** device recoverable:
              // after a restore the Android KeyStore key that encrypted the
              // token is gone, and without this a `KeyStoreException` is thrown
              // out of `read` at boot instead of degrading to "signed out".
              aOptions: AndroidOptions(resetOnError: true),
            );

  static const String key = 'ml_session_v2';

  final FlutterSecureStorage _storage;

  Future<void> save(AppSession session) async {
    if (!session.isSignedIn) {
      await clear();
      return;
    }
    await _storage.write(key: key, value: AppSession.encode(session));
  }

  Future<AppSession?> restore() async {
    try {
      // Inside the try on purpose: a `read` on a device whose KeyStore key was
      // invalidated (restore, OS upgrade) can throw, and the contract of this
      // method is "never crash at boot".
      final raw = await _storage.read(key: key);
      if (raw == null || raw.trim().isEmpty) return null;
      final session = AppSession.decode(raw);
      if (!session.isSignedIn) return null;
      return session;
    } on Object {
      // Unreadable or corrupted cache = signed out (never crash at boot).
      await clear();
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: key);
}
