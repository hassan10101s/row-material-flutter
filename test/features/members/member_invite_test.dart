import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/sync/remote/auth_remote_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/features/members/domain/member_repository.dart';
import 'package:material_lab/features/organizations/data/firestore_organization_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/organizations/domain/organization_repository.dart';
import 'package:mocktail/mocktail.dart';

class _MockRemote extends Mock implements AuthRemoteDataSource {}

class _FakeGuard implements WriteGuard {
  _FakeGuard({
    this.uid = 'uid_owner',
    this.memberId = 'member_owner',
    this.email = 'owner@lab.test',
    this.online = true,
    this.permitted = true,
  });

  @override
  final String uid;
  @override
  final String memberId;
  @override
  final String email;
  @override
  final bool online;
  final bool permitted;

  @override
  String get organizationId => 'org_1';
  @override
  String get deviceId => 'dev_1';
  @override
  bool allows(String permissionId) => permitted;
}

RemoteDocument _doc(
  String id,
  String email,
  String role,
  String status, {
  int version = 1,
}) => RemoteDocument(
  id: id,
  data: {
    'email': email,
    'role': role,
    'status': status,
    'uid': '',
    'displayName': '',
  },
  version: version,
);

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
    ).thenAnswer((_) async => const <RemoteDocument>[]);
    when(
      () => remote.updateMember(
        organizationId: any(named: 'organizationId'),
        memberId: any(named: 'memberId'),
        data: any(named: 'data'),
      ),
    ).thenAnswer((_) async {});
  });

  FirestoreOrganizationRepository build(WriteGuard guard) =>
      FirestoreOrganizationRepository(
        remote: remote,
        guard: guard,
        onRosterChanged: () async => rosterChanges++,
      );

  group('invite validation (send invite)', () {
    test('normalizes email and role passes through', () async {
      await build(
        _FakeGuard(),
      ).members.invite(email: '  New@Lab.test ', role: AppRoles.lab);

      final captured = verify(
        () => remote.createInvite(
          organizationId: any(named: 'organizationId'),
          email: captureAny(named: 'email'),
          role: captureAny(named: 'role'),
          invitedBy: any(named: 'invitedBy'),
        ),
      ).captured;
      expect(captured[0], 'new@lab.test');
      expect(captured[1], AppRoles.lab);
      expect(rosterChanges, 1);
    });

    test('invalid emails are rejected before any remote call', () async {
      for (final bad in [
        '',
        'a',
        'no-at-sign',
        'a@b',
        'a @b.com',
        'a@bcom',
        'x@y',
      ]) {
        await expectLater(
          build(_FakeGuard()).members.invite(email: bad, role: AppRoles.lab),
          throwsA(
            isA<OrganizationFailure>().having((e) => e.code, 'code', 'validation'),
          ),
          reason: bad,
        );
      }
      verifyNever(
        () => remote.createInvite(
          organizationId: any(named: 'organizationId'),
          email: any(named: 'email'),
          role: any(named: 'role'),
          invitedBy: any(named: 'invitedBy'),
        ),
      );
    });

    test('unknown role is rejected', () async {
      await expectLater(
        build(
          _FakeGuard(),
        ).members.invite(email: 'new@lab.test', role: 'superadmin'),
        throwsA(
          isA<OrganizationFailure>().having((e) => e.code, 'code', 'validation'),
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

    test('self-invite is rejected', () async {
      await expectLater(
        build(
          _FakeGuard(email: 'owner@lab.test'),
        ).members.invite(email: ' Owner@Lab.Test ', role: AppRoles.lab),
        throwsA(
          isA<OrganizationFailure>().having((e) => e.code, 'code', 'validation'),
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

    test('member without users.create is refused', () async {
      await expectLater(
        build(
          _FakeGuard(permitted: false),
        ).members.invite(email: 'new@lab.test', role: AppRoles.lab),
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

    test('remote member_exists maps to friendly code', () async {
      when(
        () => remote.createInvite(
          organizationId: any(named: 'organizationId'),
          email: any(named: 'email'),
          role: any(named: 'role'),
          invitedBy: any(named: 'invitedBy'),
        ),
      ).thenThrow(
        const RemoteAuthException('already member', code: 'member_exists'),
      );
      await expectLater(
        build(
          _FakeGuard(),
        ).members.invite(email: 'old@lab.test', role: AppRoles.lab),
        throwsA(
          isA<OrganizationFailure>().having(
            (e) => e.code,
            'code',
            'member_exists',
          ),
        ),
      );
      expect(rosterChanges, 0);
    });

    test('invite writes MEMBER_INVITED audit', () async {
      await build(
        _FakeGuard(),
      ).members.invite(email: 'new@lab.test', role: AppRoles.viewer);
      final audit = verify(
        () => remote.writeAudit(
          organizationId: captureAny(named: 'organizationId'),
          action: captureAny(named: 'action'),
          entityType: captureAny(named: 'entityType'),
          entityId: captureAny(named: 'entityId'),
          details: captureAny(named: 'details'),
        ),
      ).captured;
      expect(audit[1], 'MEMBER_INVITED');
      expect(audit[2], 'member');
      expect(audit[4], {'email': 'new@lab.test', 'role': 'viewer'});
    });
  });

  group('resendInvite', () {
    test('resends invited member without retyping email', () async {
      when(() => remote.listMembers(any())).thenAnswer(
        (_) async => [_doc('member_2', 'again@lab.test', 'lab', 'invited')],
      );
      await build(_FakeGuard()).members.resendInvite(memberId: 'member_2');

      final captured = verify(
        () => remote.createInvite(
          organizationId: any(named: 'organizationId'),
          email: captureAny(named: 'email'),
          role: captureAny(named: 'role'),
          invitedBy: any(named: 'invitedBy'),
        ),
      ).captured;
      expect(captured[0], 'again@lab.test');
      expect(captured[1], 'lab');
      final audit = verify(
        () => remote.writeAudit(
          organizationId: captureAny(named: 'organizationId'),
          action: captureAny(named: 'action'),
          entityType: captureAny(named: 'entityType'),
          entityId: captureAny(named: 'entityId'),
          details: captureAny(named: 'details'),
        ),
      ).captured;
      expect(audit[1], 'MEMBER_INVITE_RESENT');
      expect(rosterChanges, 1);
    });

    test('resends pending_activation too (claimed but not activated)', () async {
      when(() => remote.listMembers(any())).thenAnswer(
        (_) async => [
          _doc('member_3', 'claimed@lab.test', 'lab', 'pending_activation'),
        ],
      );
      await build(_FakeGuard()).members.resendInvite(memberId: 'member_3');
      verify(
        () => remote.createInvite(
          organizationId: any(named: 'organizationId'),
          email: 'claimed@lab.test',
          role: 'lab',
          invitedBy: any(named: 'invitedBy'),
        ),
      ).called(1);
    });

    test('active member cannot be resent', () async {
      when(() => remote.listMembers(any())).thenAnswer(
        (_) async => [_doc('member_4', 'old@lab.test', 'lab', 'active')],
      );
      await expectLater(
        build(_FakeGuard()).members.resendInvite(memberId: 'member_4'),
        throwsA(
          isA<OrganizationFailure>().having(
            (e) => e.code,
            'code',
            'member_exists',
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

    test('unknown member id is not_found', () async {
      await expectLater(
        build(_FakeGuard()).members.resendInvite(memberId: 'nope'),
        throwsA(
          isA<OrganizationFailure>().having(
            (e) => e.code,
            'code',
            'not_found',
          ),
        ),
      );
    });
  });

  group('member model + roster ordering', () {
    test('needsActivation covers invited and pending_activation', () {
      const invited = Member(
        id: 'a',
        email: 'a@x.test',
        role: 'lab',
        status: 'invited',
      );
      const pending = Member(
        id: 'b',
        email: 'b@x.test',
        role: 'lab',
        status: 'pending_activation',
      );
      const active = Member(
        id: 'c',
        email: 'c@x.test',
        role: 'lab',
        status: 'active',
      );
      expect(invited.needsActivation, isTrue);
      expect(pending.needsActivation, isTrue);
      expect(pending.isPendingActivation, isTrue);
      expect(active.needsActivation, isFalse);
    });

    test('listMembers sorts active, then invited/pending, then disabled', () async {
      when(() => remote.listMembers(any())).thenAnswer(
        (_) async => [
          _doc('m_disabled', 'z@lab.test', 'lab', 'disabled'),
          _doc('m_pending', 'p@lab.test', 'lab', 'pending_activation'),
          _doc('m_invited', 'i@lab.test', 'lab', 'invited'),
          _doc('m_active', 'a@lab.test', 'lab', 'active'),
        ],
      );
      final members = await build(_FakeGuard()).members.listMembers();
      expect(members.first.status, 'active');
      expect(members.last.status, 'disabled');
      final middle = members.sublist(1, 3).map((m) => m.status).toSet();
      expect(middle, {'invited', 'pending_activation'});
    });

    test('changeRole rejects unknown role before remote', () async {
      await expectLater(
        build(
          _FakeGuard(),
        ).members.changeRole(memberId: 'm1', role: 'nope'),
        throwsA(
          isA<OrganizationFailure>().having((e) => e.code, 'code', 'validation'),
        ),
      );
      verifyNever(
        () => remote.updateMember(
          organizationId: any(named: 'organizationId'),
          memberId: any(named: 'memberId'),
          data: any(named: 'data'),
        ),
      );
    });
  });

  group('online-only + self guards', () {
    test('invite offline is refused with offline code', () async {
      await expectLater(
        build(
          _FakeGuard(online: false),
        ).members.invite(email: 'new@lab.test', role: AppRoles.lab),
        throwsA(
          isA<OrganizationFailure>().having((e) => e.code, 'code', 'offline'),
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

    test('resend/changeRole/disable offline are refused too', () async {
      final repo = build(_FakeGuard(online: false));
      await expectLater(
        repo.members.resendInvite(memberId: 'm'),
        throwsA(
          isA<OrganizationFailure>().having((e) => e.code, 'code', 'offline'),
        ),
      );
      await expectLater(
        repo.members.changeRole(memberId: 'm', role: AppRoles.lab),
        throwsA(
          isA<OrganizationFailure>().having((e) => e.code, 'code', 'offline'),
        ),
      );
      await expectLater(
        repo.members.setStatus(memberId: 'm', status: 'disabled'),
        throwsA(
          isA<OrganizationFailure>().having((e) => e.code, 'code', 'offline'),
        ),
      );
    });

    test('cannot change own role or disable self', () async {
      final repo = build(_FakeGuard(memberId: 'member_owner'));
      await expectLater(
        repo.members.changeRole(memberId: 'member_owner', role: AppRoles.lab),
        throwsA(
          isA<OrganizationFailure>().having((e) => e.code, 'code', 'validation'),
        ),
      );
      await expectLater(
        repo.members.setStatus(
          memberId: 'member_owner',
          status: 'disabled',
        ),
        throwsA(
          isA<OrganizationFailure>().having((e) => e.code, 'code', 'validation'),
        ),
      );
      verifyNever(
        () => remote.updateMember(
          organizationId: any(named: 'organizationId'),
          memberId: any(named: 'memberId'),
          data: any(named: 'data'),
        ),
      );
    });

    test('listMembers maps remote not_allowed instead of empty', () async {
      when(() => remote.listMembers(any())).thenThrow(
        const RemoteAuthException('denied', code: 'not_allowed'),
      );
      await expectLater(
        build(_FakeGuard()).members.listMembers(),
        throwsA(
          isA<OrganizationFailure>().having(
            (e) => e.code,
            'code',
            'not_allowed',
          ),
        ),
      );
    });
  });
}
