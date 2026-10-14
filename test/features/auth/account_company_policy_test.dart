import 'dart:io';

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
import 'package:material_lab/features/auth/data/offline_first_auth_repository.dart';
import 'package:material_lab/features/auth/domain/auth_repository.dart';

class _MockRemote extends Mock implements AuthRemoteDataSource {}

class _MockDb extends Mock implements DatabaseHelper {}

class _MockStore extends Mock implements SessionStore {}

class _MockConnectivity extends Mock implements ConnectivityService {}

class _MockMetadata extends Mock implements SyncMetadata {}

/// Single-company account policy (plan §1-§10):
/// one Firebase account ↔ one company; invited → pending_activation → active.
void main() {
  group('member statuses', () {
    test('1. trial owner has limited permissions', () {
      final perms = rolePermissions(AppRoles.trialOwner).map((p) => p.id);
      // Demo work allowed.
      expect(perms, contains('samples.create'));
      expect(perms, contains('lab_results.create'));
      expect(perms, contains('qc.write'));
      // Sensitive operations denied.
      expect(perms, isNot(contains('users.create')));
      expect(perms, isNot(contains('users.update')));
      expect(perms, isNot(contains('org.update')));
      expect(perms, isNot(contains('qc.approve')));
      expect(perms, isNot(contains('reports.export')));
      expect(perms, isNot(contains('audit.read')));
      expect(perms, isNot(contains('devices.update')));
    });

    test('2. active member is blocked from creating a company', () {
      const s = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        status: MemberStatus.active,
      );
      expect(s.blocksNewCompany, isTrue);
    });

    test('3. pending_activation member is blocked from creating', () {
      const s = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        status: MemberStatus.pendingActivation,
      );
      expect(s.blocksNewCompany, isTrue);
      expect(s.mayEnterCompany, isFalse);
    });

    test('invited member is blocked from creating too', () {
      const s = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        status: MemberStatus.invited,
      );
      expect(s.blocksNewCompany, isTrue);
    });

    test('4. after leaving (no binding) the account may create again', () {
      const s = AppSession(uid: 'u', organizationId: '', status: 'disabled');
      expect(s.blocksNewCompany, isFalse);
      expect(s.hasNoCompany, isTrue);
    });

    test('5. invited member must not enter the dashboard', () {
      const s = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        role: AppRoles.lab,
        status: MemberStatus.invited,
      );
      expect(s.mayEnterCompany, isFalse);
      expect(s.isActiveMember, isFalse);
    });

    test('6. invited member reads nothing', () {
      const s = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        role: AppRoles.lab,
        status: MemberStatus.invited,
      );
      expect(s.can(Permission.samplesRead), isFalse);
      expect(s.canWrite, isFalse);
    });

    test('7. a member cannot activate itself (no users.update)', () {
      expect(roleHas(AppRoles.lab, Permission.usersUpdate), isFalse);
      expect(roleHas(AppRoles.viewer, Permission.usersUpdate), isFalse);
      const s = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        role: AppRoles.lab,
        status: MemberStatus.pendingActivation,
      );
      expect(
        s.canDo(Permission.usersUpdate, online: true),
        isFalse,
      );
    });

    test('8. a manager holds users.update and can activate', () {
      expect(roleHas(AppRoles.admin, Permission.usersUpdate), isTrue);
      const s = AppSession(
        uid: 'admin',
        organizationId: 'org_1',
        role: AppRoles.admin,
        status: MemberStatus.active,
      );
      expect(s.canDo(Permission.usersUpdate, online: true), isTrue);
    });

    test('9. after activation the member enters per its role', () {
      const s = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        role: AppRoles.lab,
        status: MemberStatus.active,
      );
      expect(s.mayEnterCompany, isTrue);
      expect(s.can(Permission.samplesCreate), isTrue);
      expect(s.can(Permission.usersUpdate), isFalse);
    });

    test('10. a disabled member loses access immediately', () {
      const s = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        role: AppRoles.admin,
        status: MemberStatus.disabled,
      );
      expect(s.mayEnterCompany, isFalse);
      expect(s.can(Permission.samplesRead), isFalse);
      expect(s.canWrite, isFalse);
    });

    test('11. a second company for the same account is blocked', () {
      for (final status in [
        MemberStatus.invited,
        MemberStatus.pendingActivation,
        MemberStatus.active,
      ]) {
        expect(MemberStatus.blocksNewCompany(status), isTrue);
      }
      expect(MemberStatus.blocksNewCompany(MemberStatus.disabled), isFalse);
    });

    test('legacy bound account without a status waits for activation', () {
      expect(
        normalizeMemberStatus(null),
        MemberStatus.pendingActivation,
      );
      expect(normalizeMemberStatus(''), MemberStatus.pendingActivation);
      expect(normalizeMemberStatus('bogus'), MemberStatus.pendingActivation);
      // Never active by accident.
      expect(normalizeMemberStatus(null) == MemberStatus.active, isFalse);
    });

    test('14. provider does not change permissions: same role, same set', () {
      // Google / email / password all resolve to the same users/{uid} profile;
      // the session derives permissions from the role only.
      const viaGoogle = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        role: AppRoles.lab,
        status: MemberStatus.active,
      );
      const viaPassword = AppSession(
        uid: 'u',
        organizationId: 'org_1',
        role: AppRoles.lab,
        status: MemberStatus.active,
      );
      expect(viaGoogle.permissions, viaPassword.permissions);
    });
  });

  group('firestore rules (static guarantees)', () {
    late String rules;
    setUpAll(() {
      rules = File('firestore.rules').readAsStringSync();
    });

    test('13. company reads/writes require active status', () {
      expect(rules, contains("myStatus() == 'active'"));
      expect(rules, contains('activeInOrg(orgId)'));
    });

    test('activation moves invited/pending to active only', () {
      expect(rules, contains('pending_activation'));
      expect(
        rules,
        contains(
          "resource.data.status in ['invited','pending_activation']",
        ),
      );
    });

    test('single-company creation is enforced server-side', () {
      expect(rules, contains('blocksNewCompany(request.auth.uid)'));
    });

    test('trial companies and trial_owner exist server-side', () {
      expect(rules, contains("'trial'"));
      expect(rules, contains("role == 'trial_owner'"));
    });

    test('self-leave drops the binding, activation needs users.update', () {
      expect(rules, contains('Self-service departure'));
      expect(rules, contains("'activatedBy'"));
    });
  });

  group('repository gating', () {
    late _MockRemote remote;
    late _MockDb db;
    late _MockStore store;
    late _MockConnectivity connectivity;
    late _MockMetadata metadata;
    late List<String> bound;

    setUpAll(() {
      registerFallbackValue(const AppSession());
    });

    setUp(() {
      remote = _MockRemote();
      db = _MockDb();
      store = _MockStore();
      connectivity = _MockConnectivity();
      metadata = _MockMetadata();
      bound = <String>[];

      when(() => remote.isConfigured).thenReturn(true);
      when(() => remote.currentUser()).thenAnswer(
        (_) async => const RemoteUser(uid: 'uid-1', email: 'm@example.com'),
      );
      when(() => connectivity.isOnline).thenReturn(true);
      when(() => store.restore()).thenAnswer((_) async => null);
      when(() => store.save(any())).thenAnswer((_) async {});
      when(() => store.clear()).thenAnswer((_) async {});
      when(
        () => metadata.ensureDeviceId(any()),
      ).thenAnswer((_) async => 'device_test');
      when(() => db.boundOrgId).thenReturn(null);
      when(() => db.bindOrg(any())).thenAnswer((_) async => '');
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

    UserProfile pendingProfile() => const UserProfile(
          uid: 'uid-1',
          email: 'm@example.com',
          organizationId: 'org_1',
          role: AppRoles.lab,
          status: MemberStatus.pendingActivation,
          memberId: 'member_1',
        );

    test('12. no binder / no sync source before activation', () async {
      when(
        () => remote.loadProfile(any()),
      ).thenAnswer((_) async => pendingProfile());
      final auth = build();
      expect(await auth.resolveProfile(), AuthState.awaitingActivation);
      expect(bound, isEmpty, reason: 'onOrganizationBound runs for active only');
      verify(() => db.bindOrg(null)).called(1);
      verifyNever(() => db.bindOrg('org_1'));
    });

    test('active profile binds and starts the binder once', () async {
      when(() => remote.loadProfile(any())).thenAnswer(
        (_) async => const UserProfile(
          uid: 'uid-1',
          email: 'm@example.com',
          organizationId: 'org_1',
          role: AppRoles.admin,
          status: MemberStatus.active,
          memberId: 'member_1',
        ),
      );
      final auth = build();
      expect(await auth.resolveProfile(), AuthState.ready);
      expect(bound, ['org_1']);
    });
  });
}
