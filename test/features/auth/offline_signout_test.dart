import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_store.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/firebase/firebase_bootstrap.dart';
import 'package:material_lab/core/firebase/firebase_options.dart';
import 'package:material_lab/core/network/connectivity_service.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/features/auth/data/firebase_auth_repository.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';

class _MockDatabaseHelper extends Mock implements DatabaseHelper {}

class _MockSessionStore extends Mock implements SessionStore {}

class _MockConnectivity extends Mock implements ConnectivityService {}

class _MockSyncMetadata extends Mock implements SyncMetadata {}

class _MockAuthRemote extends Mock implements AuthRemoteDataSource {}

/// Regression pins for "sign-out must complete offline and the next access,
/// even offline, never silently re-enters":
/// 1. An explicit sign-out with **no internet** and a failing still completes
///    locally: tombstone, cache wipe, org unbind and `AuthState.signedOut`.
/// 2. A tombstone (recorded sign-out) forces `signedOut` at startup with **no
///    internet**, even when a valid cached session exists.
/// 3. After sign-out, a restore with no cache and no internet stays signed out.
void main() {
  late _MockAuthRemote remote;
  late _MockDatabaseHelper db;
  late _MockSessionStore store;
  late _MockConnectivity connectivity;
  late _MockSyncMetadata metadata;
  late DateTime clock;
  late AppSession cached;
  late List<AppSession?> liveCache;
  String? currentOrg;

  setUpAll(() {
    registerFallbackValue(const AppSession());
  });

  setUp(() {
    remote = _MockAuthRemote();
    db = _MockDatabaseHelper();
    store = _MockSessionStore();
    connectivity = _MockConnectivity();
    metadata = _MockSyncMetadata();
    clock = DateTime.utc(2026, 11, 1, 12);
    cached = AppSession(
      uid: 'uid-1',
      email: 'owner@example.com',
      organizationId: 'org_abc',
      memberId: 'member_1',
      role: AppRoles.admin,
      status: MemberStatus.active,
      organizationStatus: OrgStatus.active,
      authenticationPolicyVersion: 1,
      signedInAt: clock.subtract(const Duration(days: 1)),
    );
    liveCache = <AppSession?>[cached];
    currentOrg = null;

    // Everything starts OFFLINE and stays offline for the whole test.
    when(() => connectivity.isOnline).thenReturn(false);
    // The remote source refuses to do anything (no network), including the
    // Firebase sign-out itself — exactly the "no internet, still must sign out"
    // requirement.
    when(() => remote.signOut()).thenThrow(StateError('offline'));
    when(() => remote.isConfigured).thenReturn(true);
    when(() => remote.currentUser()).thenThrow(StateError('offline'));

    when(() => store.restore()).thenAnswer((_) async => liveCache.first);
    when(() => store.save(any())).thenAnswer((_) async {});
    when(() => store.clear()).thenAnswer((_) async {
      liveCache.first = null;
    });
    when(() => store.isSignOutPending()).thenAnswer((_) async => false);
    when(() => store.markSignedOut()).thenAnswer((_) async {});
    when(() => store.allowSignIn()).thenAnswer((_) async {});

    when(
      () => metadata.ensureDeviceId(any()),
    ).thenAnswer((_) async => 'device_windows_abc');

    when(() => db.boundOrgId).thenAnswer((_) => currentOrg);
    when(() => db.bindOrg(any())).thenAnswer((invocation) async {
      final arg = invocation.positionalArguments.first as String?;
      currentOrg = (arg == null || arg.isEmpty) ? null : arg;
      return currentOrg ?? '';
    });
  });

  FirebaseAuthRepository build() => FirebaseAuthRepository(
    now: () => clock,
    remote: remote,
    sessionStore: store,
    dbHelper: db,
    connectivity: connectivity,
    metadata: metadata,
    bootstrap: const FirebaseBootstrapResult(
      status: FirebaseStatus.ready,
      config: FirebaseConfig(
        apiKey: 'k',
        appId: 'a',
        messagingSenderId: 'm',
        projectId: 'p',
        authDomain: 'd',
      ),
    ),
  );

  test(
    'an explicit offline sign-out completes locally even when Firebase fails',
    () async {
      final auth = build();
      // Enters through the offline cache first — that is the state the user
      // is signing out from with no internet.
      expect(await auth.restoreSession(), AuthState.ready);
      expect(auth.state, AuthState.ready);
      expect(currentOrg, 'org_abc');
      // The cache in the store survives this restore for the checks below.
      liveCache.first = cached;

      clearInteractions(store);
      when(() => store.isSignOutPending()).thenAnswer((_) async => false);

      await auth.signOut();

      expect(auth.state, AuthState.signedOut);
      expect(currentOrg, isNull);
      verify(() => store.markSignedOut()).called(1);
      verify(() => store.clear()).called(1);
      verify(() => db.bindOrg(null)).called(1);
    },
  );

  test(
    'a recorded sign-out forces signed-out at offline startup, never a cache',
    () async {
      final auth = build();
      when(() => store.isSignOutPending()).thenAnswer((_) async => true);

      expect(await auth.restoreSession(), AuthState.signedOut);
      expect(auth.state, AuthState.signedOut);
      expect(currentOrg, isNull);
      // The tombstone path never re-persists a session.
      verifyNever(() => store.save(any()));
    },
  );

  test(
    'without a cache and without internet the app stays signed out',
    () async {
      final auth = build();
      liveCache.first = null;

      expect(await auth.restoreSession(), AuthState.signedOut);
      expect(auth.state, AuthState.signedOut);
      expect(currentOrg, isNull);
    },
  );
}
