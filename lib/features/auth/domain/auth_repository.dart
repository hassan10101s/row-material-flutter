import '../../../core/auth/app_session.dart';
import '../../../core/utils/app_exceptions.dart';

/// Auth state machine of plan §8.1.
enum AuthState {
  /// Firebase is not configured / could not be initialized.
  needsBootstrap,

  /// No Firebase session and no cached session.
  signedOut,

  /// Signed in with Google, but `users/{uid}` does not exist yet.
  noProfile,

  /// Profile exists but `status != active` (invited/disabled).
  awaitingActivation,

  /// Fully usable, possibly from the offline cache.
  ready,
}

/// The authentication contract.
///
/// Implementation: `data/firebase_auth_repository.dart`
/// (`FirebaseAuthRepository`). Firebase Auth supplies authenticated
/// identity; Firestore rules independently enforce organization access.
///
/// ## Why this lives in `domain/`
///
/// It used to sit in `data/auth_repository.dart` next to its implementation,
/// which meant `login_cubit` and `create_organization_cubit` had to import the
/// data layer to name the type they hold. That is the one dependency the
/// architecture ratchet exists to remove, and these two cubits were the last
/// two entries in it.
abstract interface class AuthRepository {
  Stream<AuthState> get currentState;

  AuthState get state;

  AppSession get session;

  bool get isFirebaseAvailable;

  /// Reason the configuration screen must be shown (empty when configured).
  List<String> get missingConfiguration;

  /// Open the browser and sign in with Google. Throws [AuthFailure].
  Future<void> signInWithGoogle();

  Future<void> signInWithEmail({
    required String email,
    required String password,
  });

  Future<void> createPasswordAccount({
    required String email,
    required String password,
  });

  /// Restore a session: Firebase when online, the encrypted cache when not.
  Future<AuthState> restoreSession();

  /// Load `users/{uid}` (or claim an invite) and bind the organization.
  Future<AuthState> resolveProfile();

  /// Bind another organization (multi-organization accounts).
  Future<void> changeOrganization(String organizationId);

  /// Update the signed-in member's display name.
  ///
  /// The name is the member's own choice and is independent of the Google
  /// profile name: it is written to `users/{uid}` and the local roster, and it
  /// becomes the session's `displayName`, so the shell and the lab "بواسطة"
  /// (By) column show it everywhere on this device.
  Future<void> updateDisplayName(String displayName);

  /// Send a Firebase password-reset email to [email].
  ///
  /// Radio-button-free and provider-safe: it works whether the account signed
  /// in with Google or with an email/password, and never requires a recent
  /// re-authentication.
  Future<void> sendPasswordResetEmail(String email);

  /// True when the signed-in Firebase account has a verified e-mail address.
  /// The server rules refuse company genesis for unverified e-mails, so the
  /// create-organization flow must check (and offer to re-check) this.
  Future<bool> refreshEmailVerified();

  /// Re-sends the Firebase e-mail verification link. Throws [AuthFailure].
  Future<void> sendEmailVerification();

  /// Clear the cache, close the database and stop the sync engine.
  Future<void> signOut();

  /// Signs out of this device only: the member stays active and their other
  /// devices keep working (plan §14-P9.1). Defaults to [signOut] for
  /// implementations that have no device registry.
  Future<void> signOutThisDevice() => signOut();
}

/// Domain error with a user-facing Arabic/English message.
class AuthFailure implements Exception, UserFacingError {
  const AuthFailure(this.message, {this.code = 'auth_failed'});

  final String message;
  final String code;

  bool get isCancelled => code == 'cancelled';
  bool get isDenied => code == 'access_denied';
  bool get isOffline => code == 'offline';
  bool get isConfiguration => code == 'missing_config';

  @override
  String get userMessage => message;

  @override
  String toString() => message;
}
