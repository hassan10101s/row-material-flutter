import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/features/organizations/data/firestore_organization_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/organizations/domain/organization_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockRemote extends Mock implements AuthRemoteDataSource {}

/// A guard that answers whatever the test needs. `allows` is deliberately never
/// consulted by [FirestoreOrganizationRepository.leave] - a `lab` member holds
/// no `users.*` permission and still has to be able to leave.
class _FakeGuard implements WriteGuard {
  _FakeGuard({
    this.uid = 'uid_1',
    this.memberId = 'member_1',
    this.online = true,
    this.permitted = false,
  });

  @override
  final String uid;
  @override
  final String memberId;
  @override
  final bool online;
  final bool permitted;

  @override
  String get email => 'lab@lab.test';
  @override
  String get organizationId => 'org_1';
  @override
  String get deviceId => 'dev_1';
  @override
  bool allows(String permissionId) => permitted;
}

void main() {
  late _MockRemote remote;
  late int rosterChanges;

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() {
    remote = _MockRemote();
    rosterChanges = 0;
    when(
      () => remote.leaveOrganization(
        organizationId: any(named: 'organizationId'),
        memberId: any(named: 'memberId'),
        uid: any(named: 'uid'),
      ),
    ).thenAnswer((_) async {});
    when(
      () => remote.writeAudit(
        organizationId: any(named: 'organizationId'),
        action: any(named: 'action'),
        entityType: any(named: 'entityType'),
        entityId: any(named: 'entityId'),
        details: any(named: 'details'),
      ),
    ).thenAnswer((_) async {});
  });

  FirestoreOrganizationRepository build(WriteGuard guard) =>
      FirestoreOrganizationRepository(
        remote: remote,
        guard: guard,
        onRosterChanged: () async => rosterChanges++,
      );

  group('MemberRepository.leave', () {
    test('a member without any users.* permission can still leave', () async {
      final guard = _FakeGuard(permitted: false);
      await build(guard).members.leave();

      verify(
        () => remote.leaveOrganization(
          organizationId: 'org_1',
          memberId: 'member_1',
          uid: 'uid_1',
        ),
      ).called(1);
      // The caller unbinds and signs out right after, so re-reading the roster
      // here would be a wasted round trip.
      expect(rosterChanges, 0);
    });

    test('leaving writes exactly one MEMBER_LEFT audit entry', () async {
      await build(_FakeGuard()).members.leave();

      final calls = verify(
        () => remote.writeAudit(
          organizationId: captureAny(named: 'organizationId'),
          action: captureAny(named: 'action'),
          entityType: captureAny(named: 'entityType'),
          entityId: captureAny(named: 'entityId'),
          details: captureAny(named: 'details'),
        ),
      ).captured;

      expect(calls[1], 'MEMBER_LEFT');
      expect(calls[2], 'member');
      expect(calls[3], 'member_1');
      expect(calls[4], <String, dynamic>{'email': 'lab@lab.test'});
    });

    test('a signed-out session is refused before any remote call', () async {
      await expectLater(
        build(_FakeGuard(uid: '')).members.leave(),
        throwsA(
          isA<OrganizationFailure>().having(
            (e) => e.code,
            'code',
            'signed_out',
          ),
        ),
      );
      verifyNever(
        () => remote.leaveOrganization(
          organizationId: any(named: 'organizationId'),
          memberId: any(named: 'memberId'),
          uid: any(named: 'uid'),
        ),
      );
      verifyNever(
        () => remote.writeAudit(
          organizationId: any(named: 'organizationId'),
          action: any(named: 'action'),
          entityType: any(named: 'entityType'),
          entityId: any(named: 'entityId'),
          details: any(named: 'details'),
        ),
      );
    });

    test('a session without a member id is refused too', () async {
      await expectLater(
        build(_FakeGuard(memberId: '')).members.leave(),
        throwsA(
          isA<OrganizationFailure>().having(
            (e) => e.code,
            'code',
            'signed_out',
          ),
        ),
      );
      verifyNever(
        () => remote.leaveOrganization(
          organizationId: any(named: 'organizationId'),
          memberId: any(named: 'memberId'),
          uid: any(named: 'uid'),
        ),
      );
    });

    test(
      'leaving offline still reaches the remote: the rules decide',
      () async {
        await build(_FakeGuard(online: false)).members.leave();

        verify(
          () => remote.leaveOrganization(
            organizationId: 'org_1',
            memberId: 'member_1',
            uid: 'uid_1',
          ),
        ).called(1);
      },
    );
  });

  group('co-owner invitations', () {
    test(
      'an owner invites the second owner as an admin, not a plain member',
      () async {
        when(
          () => remote.createInvite(
            organizationId: any(named: 'organizationId'),
            email: any(named: 'email'),
            role: any(named: 'role'),
            invitedBy: any(named: 'invitedBy'),
          ),
        ).thenAnswer((_) async => 'member_2');

        await build(
          _FakeGuard(permitted: true),
        ).members.invite(email: '  CoOwner@Lab.test ', role: AppRoles.admin);

        final captured = verify(
          () => remote.createInvite(
            organizationId: any(named: 'organizationId'),
            email: captureAny(named: 'email'),
            role: captureAny(named: 'role'),
            invitedBy: any(named: 'invitedBy'),
          ),
        ).captured;

        // Normalized: the invite key is base64url of the lower-cased address.
        expect(captured[0], 'coowner@lab.test');
        expect(captured[1], 'admin');
        expect(rosterChanges, 1, reason: 'an invite refreshes the roster');
      },
    );

    test('a member who is not permitted to invite is refused', () async {
      await expectLater(
        build(
          _FakeGuard(permitted: false),
        ).members.invite(email: 'coowner@lab.test', role: AppRoles.admin),
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
