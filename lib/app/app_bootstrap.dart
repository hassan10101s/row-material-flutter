import 'package:flutter/material.dart' show debugPrint;

import '../core/firebase/firebase_bootstrap.dart';
import '../core/sync/sync_engine.dart';
import '../di/service_locator.dart';
import 'auth_gate.dart';
import '../features/auth/domain/auth_repository.dart';

/// Startup sequence (plan §8.1 + §6.5).
///
/// ```
/// boot → FirebaseBootstrap
///      → restoreSession()          (online: users/{uid} · offline: session cache)
///      → bindOrg(orgId)            (per-organization database, then the seeds
///                                   below run against it, then the sync engine)
///      → SyncEngine.start()
/// ```
/// Everything after [FirebaseBootstrap.initialize] is safe without Firebase: the
/// app degrades to the cached session or to the `needsBootstrap` state.
Future<void> appBootstrap() async {
  await initServiceLocator();

  final auth = getIt<AuthRepository>();
  await registerOrganizationBinder(auth);

  // Keep the shell + router guards in sync with the auth state stream
  // (sign-in, sign-out, organization switch, refresh failures).
  getIt<AuthGate>().start();

  final state = await auth.restoreSession();
  debugPrint('[bootstrap] auth state: ${state.name}');

  if (state == AuthState.needsBootstrap) {
    debugPrint('[bootstrap] firebase missing: ${getIt<FirebaseBootstrapResult>().missingKeys}');
    return;
  }

  if (state == AuthState.ready) {
    startSyncEngine();
  }
}

/// Runs the per-organization side effects. The callback itself lives in
/// `registerOrganizationBinder` (service_locator) so the repository never has
/// to import a feature module.
void startSyncEngine() => getIt<SyncEngine>().start();

/// Sign out and clear the in-memory session after a database restore.
Future<void> resetAfterRestore() async {
  final auth = getIt<AuthRepository>();
  await auth.signOut();
}

/// Local → remote calls are impossible after a sign-out.
bool get isWritableSession {
  final auth = getIt<AuthRepository>();
  return auth.state == AuthState.ready;
}
