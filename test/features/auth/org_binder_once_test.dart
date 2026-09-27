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
import 'package:material_lab/features/auth/data/auth_repository.dart';
import 'package:material_lab/features/auth/data/offline_first_auth_repository.dart';

class _MockDatabaseHelper extends Mock implements DatabaseHelper {}

class _MockSessionStore extends Mock implements SessionStore {}

class _MockConnectivity extends Mock implements ConnectivityService {}

class _MockSyncMetadata extends Mock implements SyncMetadata {}

class _MockAuthRemote extends Mock implements AuthRemoteDataSource {}

/// The organization binder (`service_locator.registerOrganizationBinder`) runs
/// the seeds, `autoBackup()` - a `VACUUM INTO` on the **live** database - the
/// device registration and the sync engine.
///
/// `restoreSession`, `signInWithGoogle` and `CreateOrganizationCubit` all funnel
/// through `resolveProfile`, so before the guard in
/// `OfflineFirstAuthRepository._bindOrganization` the whole binder ran three
/// times in a single startup, vacuuming the database the user is about to save
/// an inspection into. These tests pin the once-per-organization contract.
void main() {
  late _MockAuthRemote remote;
  late _MockDatabaseHelper db;
  late _MockSessionStore store;
  late _MockConnectivity connectivity;
  late _MockSyncMetadata metadata;
  late List<String> bound;
  String? currentOrg;

  setUpAll(() {
    registerFallbackValue(const AppSession());
  });

  UserProfile profileFor(String orgId) => UserProfile(
        uid: 'uid-1',
        email: 'owner@example.com',
        organizationId: orgId,
        role: AppRoles.admin,
        status: MemberStatus.active,
        memberId: 'member_1',
      );

  setUp(() {
    remote = _MockAuthRemote();
    db = _MockDatabaseHelper();
    store = _MockSessionStore();
    connectivity = _MockConnectivity();
    metadata = _MockSyncMetadata();
    bound = <String>[];
    currentOrg = null;

    when(() => remote.isConfigured).thenReturn(true);
    when(() => remote.currentUser())
        .thenAnswer((_) async => const RemoteUser(uid: 'uid-1', email: 'owner@example.com'));
    when(() => connectivity.isOnline).thenReturn(true);
    when(() => store.restore()).thenAnswer((_) async => null);
    when(() => store.save(any())).thenAnswer((_) async {});
    when(() => store.clear()).thenAnswer((_) async {});
    when(() => metadata.ensureDeviceId(any())).thenAnswer((_) async => 'device_windows_abc');

    // DatabaseHelper.boundOrgId is a getter over the mutable AppPaths.orgId.
    when(() => db.boundOrgId).thenAnswer((_) => currentOrg);
    when(() => db.bindOrg(any())).thenAnswer((invocation) async {
      final arg = invocation.positionalArguments.first as String?;
      currentOrg = (arg == null || arg.isEmpty) ? null : arg;
      return currentOrg ?? '';
    });
  });

  OfflineFirstAuthRepository build() => OfflineFirstAuthRepository(
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
      )..onOrganizationBound = (orgId) async => bound.add(orgId);

  test('the binder runs once per organization, not once per resolveProfile',
      () async {
    when(() => remote.loadProfile(any())).thenAnswer((_) async => profileFor('org_abc'));
    final auth = build();

    // three resolveProfile calls in one startup: restore, sign-in, create-org
    expect(await auth.resolveProfile(), AuthState.ready);
    expect(await auth.resolveProfile(), AuthState.ready);
    expect(await auth.resolveProfile(), AuthState.ready);

    expect(
      bound,
      ['org_abc'],
      reason: 'the seeds / autoBackup / device-registration side effects must run once',
    );
    // bindOrg is still called every time - it is the cheap, idempotent part.
    verify(() => db.bindOrg('org_abc')).called(3);
  });

  test('switching organization re-runs the binder', () async {
    when(() => remote.loadProfile(any())).thenAnswer((_) async => profileFor('org_abc'));
    final auth = build();
    await auth.resolveProfile();
    expect(bound, ['org_abc']);

    when(() => remote.loadProfile(any())).thenAnswer((_) async => profileFor('org_xyz'));
    await auth.resolveProfile();

    expect(bound, ['org_abc', 'org_xyz']);
  });

  test('sign-out unbinds, so the next sign-in re-runs the binder', () async {
    when(() => remote.loadProfile(any())).thenAnswer((_) async => profileFor('org_abc'));
    when(() => remote.signOut()).thenAnswer((_) async {});
    final auth = build();
    await auth.resolveProfile();
    expect(bound, ['org_abc']);

    await auth.signOut();
    expect(currentOrg, isNull);

    await auth.resolveProfile();
    expect(bound, ['org_abc', 'org_abc']);
  });

  test('a no-profile session binds nothing at all', () async {
    when(() => remote.loadProfile(any())).thenAnswer((_) async => null);
    final auth = build();

    expect(await auth.resolveProfile(), AuthState.noProfile);
    expect(bound, isEmpty);
    verifyNever(() => db.bindOrg(any()));
  });
}
