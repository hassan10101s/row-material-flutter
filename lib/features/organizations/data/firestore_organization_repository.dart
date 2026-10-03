import '../../../core/sync/remote/auth_remote_data_source.dart' show RemoteAuthException;
import '../../../core/sync/remote/remote_data_source.dart' hide OrganizationProfile;
import '../../members/domain/member_repository.dart';
import '../domain/organization_repository.dart';
import 'member_write_guard.dart';

/// Firestore-backed implementation (plan P3.1/P3.2).
///
/// Writes go straight to Firestore (`organizations`, `members`, `invites`,
/// `users`, `auditLogs`); the local `users` table is refreshed afterwards by
/// the next pull. The sync queue is deliberately **not** used here: an invite
/// or a role change is an authorization decision, it is online-only, and it
/// must be committed remotely before the UI shows it.
class FirestoreOrganizationRepository implements OrganizationRepository {
  FirestoreOrganizationRepository({
    required this.remote,
    required this.guard,
    this.onRosterChanged,
  });

  final AuthRemoteDataSource remote;

  /// Local write guard — mirrors `AppSession.canDo`, so the repository refuses
  /// privileged operations offline and without a fresh token.
  final MemberWriteGuard guard;

  /// Invalidates the members list after a successful remote write.
  final Future<void> Function()? onRosterChanged;

  String get _organizationId => guard.organizationId;

  // ── Organization ───────────────────────────────────────────────────────

  @override
  Future<String> createOrganization({required String name}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const OrganizationFailure('اسم المؤسسة مطلوب', code: 'validation');
    }
    final user = await remote.currentUser();
    if (user == null) {
      throw const OrganizationFailure('انتهت جلسة الدخول، أعد تسجيل الدخول', code: 'signed_out');
    }
    return remote.createOrganization(
      uid: user.uid,
      email: user.email,
      displayName: user.displayName ?? '',
      organizationName: trimmed,
    ).onError<RemoteAuthException>((error, _) {
      throw OrganizationFailure(error.message, code: error.code);
    });
  }

  @override
  Future<void> joinWithInvite({required String organizationId}) async {
    final user = await remote.currentUser();
    if (user == null) {
      throw const OrganizationFailure('انتهت جلسة الدخول، أعد تسجيل الدخول', code: 'signed_out');
    }
    final orgId = organizationId.trim();
    if (orgId.isEmpty) {
      throw const OrganizationFailure('كود المؤسسة مطلوب', code: 'validation');
    }
    // The Rules only allow reading the invite whose e-mail equals the token
    // e-mail, so a miss is a plain "not found" (plan §8.3 → "Access Denied").
    final invite = await remote.findInvite(orgId, user.email);
    if (invite == null) {
      throw const OrganizationFailure(
        'لا توجد دعوة مطابقة لبريدك في هذه المؤسسة',
        code: 'invite_not_found',
      );
    }
    await remote.acceptInvite(
      organizationId: orgId,
      invite: invite,
      uid: user.uid,
      email: user.email,
    );
    await remote.writeAudit(
      organizationId: orgId,
      action: 'INVITE_CLAIMED',
      entityType: 'member',
      entityId: invite.memberId,
      details: {'email': user.email, 'role': invite.role},
    );
  }

  @override
  Future<OrganizationProfile?> loadOrganization() async {
    final orgId = _organizationId;
    if (orgId.isEmpty) return null;
    final profile = await remote.loadOrganization(orgId);
    if (profile == null) return null;
    return OrganizationProfile(
      id: profile.id,
      name: profile.name,
      ownerUid: profile.ownerUid,
      status: profile.status,
      schemaVersion: profile.schemaVersion,
    );
  }

  @override
  Future<void> rename(String name) async {
    if (name.trim().isEmpty) {
      throw const OrganizationFailure('اسم المؤسسة مطلوب', code: 'validation');
    }
    _require('org.update');
    await remote.updateOrganization(_organizationId, {'name': name.trim()});
    await remote.writeAudit(
      organizationId: _organizationId,
      action: 'ORG_UPDATED',
      entityType: 'org',
      entityId: _organizationId,
      details: {'name': name.trim()},
    );
  }

  // ── Members ────────────────────────────────────────────────────────────

  @override
  MemberRepository get members => _Members(this);

  void _require(String permissionId) {
    if (!guard.allows(permissionId)) {
      throw const OrganizationFailure(
        'هذه العملية تتطلب اتصالاً بالإنترنت وجلسة صالحة',
        code: 'not_allowed',
      );
    }
  }
}

/// Member operations against the same Firestore source.
class _Members implements MemberRepository {
  _Members(this._owner);

  final FirestoreOrganizationRepository _owner;

  AuthRemoteDataSource get _remote => _owner.remote;

  MemberWriteGuard get _guard => _owner.guard;

  String get _orgId => _guard.organizationId;

  @override
  Future<List<Member>> listMembers() async {
    final documents = await _remote.listMembers(_orgId);
    final members = documents.map(Member.fromDocument).toList()
      ..sort((a, b) {
        final byStatus = _statusOrder(a.status).compareTo(_statusOrder(b.status));
        if (byStatus != 0) return byStatus;
        return a.email.toLowerCase().compareTo(b.email.toLowerCase());
      });
    return members;
  }

  @override
  Future<void> invite({required String email, required String role}) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.length < 4 || !normalized.contains('@')) {
      throw const OrganizationFailure('البريد الإلكتروني غير صالح', code: 'validation');
    }
    _owner._require('users.create');
    final memberId = await _remote.createInvite(
      organizationId: _orgId,
      email: normalized,
      role: role,
      invitedBy: _guard.uid,
    );
    await _remote.writeAudit(
      organizationId: _orgId,
      action: 'MEMBER_INVITED',
      entityType: 'member',
      entityId: memberId,
      details: {'email': normalized, 'role': role},
    );
    await _owner.onRosterChanged?.call();
  }

  @override
  Future<void> changeRole({required String memberId, required String role}) async {
    _owner._require('users.update');
    await _remote.updateMember(
      organizationId: _orgId,
      memberId: memberId,
      data: {'role': role},
    );
    await _remote.writeAudit(
      organizationId: _orgId,
      action: 'MEMBER_ROLE_CHANGED',
      entityType: 'member',
      entityId: memberId,
      details: {'role': role},
    );
    await _owner.onRosterChanged?.call();
  }

  @override
  Future<void> setStatus({required String memberId, required String status}) async {
    if (status != 'active' && status != 'disabled') {
      throw const OrganizationFailure('الحالة غير صالحة', code: 'validation');
    }
    _owner._require(status == 'active' ? 'users.update' : 'users.disable');
    await _remote.updateMember(
      organizationId: _orgId,
      memberId: memberId,
      data: {'status': status, 'activatedAt': null},
    );
    await _remote.writeAudit(
      organizationId: _orgId,
      action: status == 'active' ? 'MEMBER_ACTIVATED' : 'MEMBER_DISABLED',
      entityType: 'member',
      entityId: memberId,
    );
    await _owner.onRosterChanged?.call();
  }

  @override
  Future<void> removeMember({required String memberId}) async {
    if (memberId == _guard.memberId) {
      throw const OrganizationFailure('لا يمكنك إزالة نفسك من المؤسسة', code: 'validation');
    }
    _owner._require('users.disable');
    await _remote.deleteMember(organizationId: _orgId, memberId: memberId);
    await _remote.writeAudit(
      organizationId: _orgId,
      action: 'MEMBER_REMOVED',
      entityType: 'member',
      entityId: memberId,
    );
    await _owner.onRosterChanged?.call();
  }

  /// Self-service departure. No `_require(...)` on purpose: leaving has to be
  /// possible for a `lab` or `viewer` member, who holds no `users.*` permission.
  @override
  Future<void> leave() async {
    final uid = _guard.uid;
    final memberId = _guard.memberId;
    if (uid.isEmpty || memberId.isEmpty || _orgId.isEmpty) {
      throw const OrganizationFailure(
        'جلسة الدخول غير مكتملة، أعد تسجيل الدخول',
        code: 'signed_out',
      );
    }
    await _remote.leaveOrganization(
      organizationId: _orgId,
      memberId: memberId,
      uid: uid,
    );
    await _remote.writeAudit(
      organizationId: _orgId,
      action: 'MEMBER_LEFT',
      entityType: 'member',
      entityId: memberId,
      details: {'email': _guard.email},
    );
    // `onRosterChanged` is intentionally not fired: the caller unbinds the
    // organization and signs out immediately afterwards.
  }

  /// Active first, then invited, then disabled.
  static int _statusOrder(String status) => switch (status) {
        'active' => 0,
        'invited' => 1,
        _ => 2,
      };
}
