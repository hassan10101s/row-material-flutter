import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/auth/app_session.dart';
import '../core/auth/permissions.dart';
import '../core/network/connectivity_service.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/domain/user.dart';

/// Observable auth state consumed by the router guards and the shell badge
/// (plan §8.1). Replaces the pre-V2 "is there a row in `users`" check.
class AuthGate extends ChangeNotifier {
  AuthGate(this.auth, {this.connectivity});

  final AuthRepository auth;

  /// Optional: the shell badge and the write guards need live connectivity.
  final ConnectivityService? connectivity;

  StreamSubscription<AuthState>? _subscription;

  AppSession get session => auth.session;

  bool get isAuthenticated => auth.state == AuthState.ready;

  bool get needsBootstrap => auth.state == AuthState.needsBootstrap;

  bool get isSignedOut => auth.state == AuthState.signedOut;

  bool get hasNoProfile => auth.state == AuthState.noProfile;

  bool get isAwaitingActivation => auth.state == AuthState.awaitingActivation;

  String get organizationId => session.organizationId;

  String get role => session.role;

  /// View-model used by the existing screens (`plan §7.3`: their call sites stay
  /// unchanged, only the bodies of the permission getters were rewritten).
  User? get currentUser {
    if (!session.isSignedIn) return null;
    return User(
      uid: session.uid,
      memberId: session.memberId.isEmpty ? null : session.memberId,
      email: session.email,
      fullName: session.displayName,
      displayName: session.displayName,
      photoUrl: session.photoUrl,
      role: session.role,
      status: session.status,
      readOnlyDevice: session.readOnlyDevice,
    );
  }

  bool get isReadOnlyDevice => session.readOnlyDevice || !session.canWrite;

  /// Can the UI open a write dialog? (Local guard; Firestore rules are the
  /// second, independent layer.)
  bool canWrite(Permission permission) => session.canDo(permission, online: online);

  bool get online => connectivity?.isOnline ?? session.isTokenFresh;

  void start() {
    _subscription?.cancel();
    _subscription = auth.currentState.listen((_) => notifyListeners());
  }

  /// Re-reads the repository synchronously (used after sign-in/sign-out and by
  /// [offline_first_auth_repository] side effects such as organization binds).
  void updated() => notifyListeners();

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
