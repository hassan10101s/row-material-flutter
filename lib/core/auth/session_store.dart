import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_session.dart';

/// Encrypted cache of the last session so the app can be opened **offline**
/// (plan §8.4). It grants no new permission: the cached token is only used for
/// read-only local work, and every remote write still requires a live token.
class SessionStore {
  SessionStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
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
    final raw = await _storage.read(key: key);
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final session = AppSession.decode(raw);
      if (!session.isSignedIn) return null;
      return session;
    } on Object {
      // Corrupted cache = signed out (never crash at boot).
      await clear();
      return null;
    }
  }

  Future<void> clear() => _storage.delete(key: key);
}
