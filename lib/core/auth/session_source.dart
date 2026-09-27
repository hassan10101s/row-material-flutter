import 'app_session.dart';

/// Live, pull-based view of the current [AppSession].
///
/// Everything that needs the session long after bootstrap (the member write
/// guard, the push/pull workers, the sync engine) must read it *through* this
/// object. Holding an `AppSession` by value would freeze the state captured
/// when the lazily-registered singleton was first resolved — typically the
/// empty session from before sign-in (plan §8.5/§9.4).
class SessionSource {
  const SessionSource(this._read);

  final AppSession Function() _read;

  AppSession get session => _read();

  /// Source used before sign-in and by tests.
  static SessionSource empty([AppSession Function()? read]) =>
      SessionSource(read ?? () => kEmptySession);
}
