import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/features/organizations/data/firestore_organization_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/organizations/domain/organization_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockRemote extends Mock implements AuthRemoteDataSource {}

/// Real guard (not a fake): proves a normal signed-in member cannot invite,
/// even if the UI were bypassed.
WriteGuard guardFor(String role) {
  final session = AppSession(
    uid: 'uid_1',
    email: 'user@lab.test',
    organizationId: 'org_1',
    memberId: 'member_1',
    role: role,
    status: MemberStatus.active,
    deviceId: 'dev_1',
    idTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
  return SessionWriteGuard(
    source: SessionSource(() => session),
    isOnline: () => true,
  );
}

void main() {
  late _MockRemote remote;

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    remote = _MockRemote();
    when(
      () => remote.createInvite(
        organizationId: any(named: 'organizationId'),
        email: any(named: 'email'),
        role: any(named: 'role'),
        invitedBy: any(named: 'invitedBy'),
      ),
    ).thenAnswer((_) async => 'member_new');
    when(
      () => remote.writeAudit(
        organizationId: any(named: 'organizationId'),
        action: any(named: 'action'),
        entityType: any(named: 'entityType'),
        entityId: any(named: 'entityId'),
        details: any(named: 'details'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => remote.listMembers(any()),
    ).thenAnswer((_) async => const []);
  });

  test('only admin holds users.create locally', () {
    expect(roleHas(AppRoles.admin, Permission.usersCreate), isTrue);
    for (final role in [
      AppRoles.qualityManager,
      AppRoles.lab,
      AppRoles.viewer,
      AppRoles.trialOwner,
    ]) {
      expect(
        roleHas(role, Permission.usersCreate),
        isFalse,
        reason: role,
      );
    }
  });

  test('guard allows invite for admin only', () {
    expect(guardFor(AppRoles.admin).allows('users.create'), isTrue);
    for (final role in [
      AppRoles.qualityManager,
      AppRoles.lab,
      AppRoles.viewer,
      AppRoles.trialOwner,
    ]) {
      expect(guardFor(role).allows('users.create'), isFalse, reason: role);
    }
  });

  group('normal member cannot add new member (repository)', () {
    for (final role in [
      AppRoles.qualityManager,
      AppRoles.lab,
      AppRoles.viewer,
      AppRoles.trialOwner,
    ]) {
      test('$role invite is refused before any remote call', () async {
        final repo = FirestoreOrganizationRepository(
          remote: remote,
          guard: guardFor(role),
        );
        await expectLater(
          repo.members.invite(email: 'new@lab.test', role: AppRoles.lab),
          throwsA(
            isA<OrganizationFailure>().having(
              (e) => e.code,
              'code',
              'not_allowed',
            ),
          ),
        );
        verifyNever(
          () => remote.createInvite(
            organizationId: any(named: 'organizationId'),
            email: any(named: 'email'),
            role: any(named: 'role'),
            invitedBy: any(named: 'invitedBy'),
          ),
        );
      });

      test('$role resend is refused too', () async {
        final repo = FirestoreOrganizationRepository(
          remote: remote,
          guard: guardFor(role),
        );
        await expectLater(
          repo.members.resendInvite(memberId: 'member_x'),
          throwsA(
            isA<OrganizationFailure>().having(
              (e) => e.code,
              'code',
              'not_allowed',
            ),
          ),
        );
        verifyNever(
          () => remote.createInvite(
            organizationId: any(named: 'organizationId'),
            email: any(named: 'email'),
            role: any(named: 'role'),
            invitedBy: any(named: 'invitedBy'),
          ),
        );
      });

      test('$role cannot change role / disable / remove', () async {
        final repo = FirestoreOrganizationRepository(
          remote: remote,
          guard: guardFor(role),
        );
        await expectLater(
          repo.members.changeRole(memberId: 'm', role: AppRoles.lab),
          throwsA(isA<OrganizationFailure>()),
        );
        await expectLater(
          repo.members.setStatus(memberId: 'm', status: 'disabled'),
          throwsA(isA<OrganizationFailure>()),
        );
        await expectLater(
          repo.members.removeMember(memberId: 'm'),
          throwsA(isA<OrganizationFailure>()),
        );
      });
    }

    test('non-active admin (invited) cannot invite either', () async {
      final session = AppSession(
        uid: 'uid_1',
        email: 'user@lab.test',
        organizationId: 'org_1',
        memberId: 'member_1',
        role: AppRoles.admin,
        status: MemberStatus.invited,
        deviceId: 'dev_1',
        idTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
      );
      final repo = FirestoreOrganizationRepository(
        remote: remote,
        guard: SessionWriteGuard(
          source: SessionSource(() => session),
          isOnline: () => true,
        ),
      );
      await expectLater(
        repo.members.invite(email: 'new@lab.test', role: AppRoles.lab),
        throwsA(
          isA<OrganizationFailure>().having(
            (e) => e.code,
            'code',
            'not_allowed',
          ),
        ),
      );
      verifyNever(
        () => remote.createInvite(
          organizationId: any(named: 'organizationId'),
          email: any(named: 'email'),
          role: any(named: 'role'),
          invitedBy: any(named: 'invitedBy'),
        ),
      );
    });
  });
}
