import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/auth/app_session.dart';
import '../core/auth/session_policy.dart';
import '../core/auth/permissions.dart';
import '../core/network/connectivity_service.dart';
import '../features/auth/domain/auth_repository.dart';
import '../features/auth/domain/user.dart';

/// Observable auth state consumed by the router guards and the shell badge
/// (plan §8.1). Replaces the pre-V2 "is there a row in `users`" check.
class AuthGate extends ChangeNotifier {
  AuthGate(this.auth, {this.connectivity, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final DateTime Function() _now;

  final AuthRepository auth;

  /// Optional: the shell badge and the write guards need live connectivity.
  final ConnectivityService? connectivity;

  StreamSubscription<AuthState>? _subscription;
  Timer? _expiry;
  bool _expiring = false;

  AppSession get session => auth.session;

  bool get isAuthenticated => !_expiring && auth.state == AuthState.ready;

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
      roles: session.effectiveRoles,
      status: session.status,
      readOnlyDevice: session.readOnlyDevice,
    );
  }

  bool get isReadOnlyDevice => session.readOnlyDevice || !session.canWrite;

  /// Can the UI open a write dialog? (Local guard; Firestore rules are the
  /// second, independent layer.)
  bool canWrite(Permission permission) =>
      session.canPrepareBusinessWrite(permission, online: online);

  bool get online => connectivity?.isOnline ?? session.isTokenFresh;

  void start() {
    _subscription?.cancel();
    _subscription = auth.currentState.listen((_) {
      _scheduleExpiry();
      notifyListeners();
    });
    _scheduleExpiry();
  }

  /// Re-reads the repository synchronously (used after sign-in/sign-out and by
  /// FirebaseAuthRepository side effects such as organization binds).
  void updated() {
    _scheduleExpiry();
    notifyListeners();
  }

  void _scheduleExpiry() {
    _expiry?.cancel();
    if (!session.isSignedIn || _expiring) return;
    final signedInAt = session.signedInAt;
    if (SessionPolicy.requiresSignIn(
      signedInAt,
      _now(),
      policyVersion: session.authenticationPolicyVersion,
    )) {
      _expiring = true;
      unawaited(
        auth.signOut().whenComplete(() {
          _expiring = false;
        }),
      );
      return;
    }
    _expiry = Timer(
      signedInAt!.add(SessionPolicy.maximumAge).difference(_now()),
      () {
        _scheduleExpiry();
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _expiry?.cancel();
    super.dispose();
  }
}
