import '../../../core/auth/permissions.dart';
import '../../../core/sync/remote/auth_remote_data_source.dart'
    show RemoteAuthException;
import '../../../core/constants/app_strings.dart';
import '../../../core/sync/remote/remote_data_source.dart'
    hide OrganizationProfile;
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
      throw OrganizationFailure(
        AppText.t('اسم المؤسسة مطلوب', 'Organization name is required.'),
        code: 'validation',
      );
    }
    final user = await remote.currentUser();
    if (user == null) {
      throw OrganizationFailure(
        AppText.t(
          'انتهت جلسة الدخول، أعد تسجيل الدخول',
          'Session expired, please sign in again.',
        ),
        code: 'signed_out',
      );
    }
    // Single-company policy (§2): read the current profile before creating.
    // A bound account (invited/pending_activation/active) is refused with a
    // clear message — sign-out alone never unblocks this, only leaving does.
    final existing = await remote.loadProfile(user.uid);
    if (existing != null &&
        existing.organizationId.isNotEmpty &&
        (existing.status == 'invited' ||
            existing.status == 'pending_activation' ||
            existing.status == 'active')) {
      throw OrganizationFailure(
        AppText.t(
          'هذا الحساب مرتبط بشركة حالية. غادر الشركة الحالية أولًا لإنشاء شركة جديدة.',
          'This account is already linked to a company. Leave the current company first to create a new one.',
        ),
        code: 'member_exists',
      );
    }
    return remote
        .createOrganization(
          uid: user.uid,
          email: user.email,
          displayName: user.displayName ?? '',
          organizationName: trimmed,
        )
        .onError<RemoteAuthException>((error, _) {
          throw OrganizationFailure(
            _remoteCreateMessage(error),
            code: error.code,
          );
        });
  }

  /// Bilingual mapping for the remote creation errors: raw technical English
  /// must never reach the UI, while the code stays for debugging.
  static String _remoteCreateMessage(
    RemoteAuthException error,
  ) => switch (error.code) {
    'member_exists' => AppText.t(
      'هذا الحساب مرتبط بشركة حالية. غادر الشركة الحالية أولًا لإنشاء شركة جديدة.',
      'This account is already linked to a company. Leave the current company first to create a new one.',
    ),
    'organization_exists' => AppText.t(
      'الشركة موجودة بالفعل.',
      'Organization already exists.',
    ),
    _ => AppText.t(
      'تعذر إنشاء الشركة. حاول مرة أخرى.',
      'Could not create the company. Try again.',
    ),
  };

  @override
  Future<void> joinWithInvite({required String organizationId}) async {
    final user = await remote.currentUser();
    if (user == null) {
      throw OrganizationFailure(
        AppText.t(
          'انتهت جلسة الدخول، أعد تسجيل الدخول',
          'Session expired, please sign in again.',
        ),
        code: 'signed_out',
      );
    }
    final orgId = organizationId.trim();
    if (orgId.isEmpty) {
      throw OrganizationFailure(
        AppText.t('كود المؤسسة مطلوب', 'Organization code is required.'),
        code: 'validation',
      );
    }
    // The Rules only allow reading the invite whose e-mail equals the token
    // e-mail, so a miss is a plain "not found" (plan §8.3 → "Access Denied").
    // A denied read (unverified e-mail) surfaces the same way: hint at
    // verification instead of showing a raw permission error.
    Invite? invite;
    try {
      invite = await remote.findInvite(orgId, user.email);
    } on Object catch (_) {
      throw OrganizationFailure(
        AppText.t(
          'تعذّر قراءة الدعوة — تحقق من اتصالك وتأكد من توثيق بريدك ثم حاول مجددًا.',
          'Could not read the invite — check your connection, make sure your email is verified, then try again.',
        ),
        code: 'invite_not_found',
      );
    }
    if (invite == null) {
      throw OrganizationFailure(
        AppText.t(
          'لا توجد دعوة مطابقة لبريدك في هذه المؤسسة',
          'No matching invite for your email in this organization.',
        ),
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
      trialStartedAt: profile.trialStartedAt,
      trialEndsAt: profile.trialEndsAt,
      trialConsumed: profile.trialConsumed,
      manuallyActivated: profile.manuallyActivated,
    );
  }

  @override
  Future<void> rename(String name) async {
    if (name.trim().isEmpty) {
      throw OrganizationFailure(
        AppText.t('اسم المؤسسة مطلوب', 'Organization name is required.'),
        code: 'validation',
      );
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
      throw OrganizationFailure(
        AppText.t(
          'هذه العملية تتطلب اتصالاً بالإنترنت وجلسة صالحة',
          'This action requires an internet connection and a valid session.',
        ),
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
    try {
      final documents = await _remote.listMembers(_orgId);
      final members = documents.map(Member.fromDocument).toList()
        ..sort((a, b) {
          final byStatus = _statusOrder(
            a.status,
          ).compareTo(_statusOrder(b.status));
          if (byStatus != 0) return byStatus;
          return a.email.toLowerCase().compareTo(b.email.toLowerCase());
        });
      return members;
    } on RemoteAuthException catch (e) {
      throw OrganizationFailure(e.message, code: e.code);
    } on Object catch (e) {
      throw _mapRemoteError(e);
    }
  }

  /// Member writes are online-only (never queued): even the exempt `admin`
  /// role must have connectivity here, otherwise the button looks enabled
  /// offline and only fails later with a raw Firestore error.
  void _requireOnline() {
    if (!_guard.online) {
      throw OrganizationFailure(
        AppText.t(
          'هذه العملية تتطلب اتصالاً بالإنترنت',
          'This action requires an internet connection.',
        ),
        code: 'offline',
      );
    }
  }

  @override
  Future<void> invite({
    required String email,
    required String role,
    List<String>? roles,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.length < 4 ||
        !normalized.contains('@') ||
        !_emailLooksValid(normalized)) {
      throw OrganizationFailure(
        AppText.t('البريد الإلكتروني غير صالح', 'Invalid email address.'),
        code: 'validation',
      );
    }
    final assignedRoles = roles ?? [role];
    if (!AppRoles.isValid(role) ||
        role == AppRoles.trialOwner ||
        assignedRoles.isEmpty ||
        assignedRoles.first != role ||
        !AppRoles.isValidAssignment(assignedRoles)) {
      throw OrganizationFailure(
        AppText.t('الدور غير صالح', 'Invalid role.'),
        code: 'validation',
      );
    }
    final selfEmail = _guard.email.trim().toLowerCase();
    if (selfEmail.isNotEmpty && normalized == selfEmail) {
      throw OrganizationFailure(
        AppText.t(
          'لا يمكنك دعوة نفسك — هذا البريد مرتبط بحسابك.',
          'You cannot invite yourself — this email belongs to your account.',
        ),
        code: 'validation',
      );
    }
    _requireOnline();
    _owner._require('users.create');
    late final String memberId;
    try {
      memberId = await _remote.createInvite(
        organizationId: _orgId,
        email: normalized,
        role: role,
        roles: assignedRoles,
        invitedBy: _guard.uid,
      );
    } on RemoteAuthException catch (error) {
      final message = switch (error.code) {
        'member_exists' => AppText.t(
          'هذا البريد عضو نشط بالفعل في الشركة',
          'This email is already an active company member.',
        ),
        'invalid_email' => AppText.t(
          'البريد الإلكتروني غير صالح',
          'Invalid email address.',
        ),
        'invalid_role' => AppText.t('الدور غير صالح', 'Invalid role.'),
        _ => error.message,
      };
      throw OrganizationFailure(message, code: error.code);
    }
    await _remote.writeAudit(
      organizationId: _orgId,
      action: 'MEMBER_INVITED',
      entityType: 'member',
      entityId: memberId,
      details: {'email': normalized, 'role': role, 'roles': assignedRoles},
    );
    await _owner.onRosterChanged?.call();
  }

  @override
  Future<void> resendInvite({required String memberId}) async {
    if (memberId.trim().isEmpty) {
      throw OrganizationFailure(
        AppText.t('العضو غير صالح', 'Invalid member.'),
        code: 'validation',
      );
    }
    _requireOnline();
    _owner._require('users.create');
    final members = await listMembers();
    Member? target;
    for (final m in members) {
      if (m.id == memberId) {
        target = m;
        break;
      }
    }
    if (target == null) {
      throw OrganizationFailure(
        AppText.t('العضو غير موجود', 'Member not found.'),
        code: 'not_found',
      );
    }
    if (target.isActive) {
      throw OrganizationFailure(
        AppText.t(
          'هذا البريد عضو نشط بالفعل في الشركة',
          'This email is already an active company member.',
        ),
        code: 'member_exists',
      );
    }
    final memberIdOut = await _remote.createInvite(
      organizationId: _orgId,
      email: target.email,
      role: target.role,
      roles: target.effectiveRoles,
      invitedBy: _guard.uid,
    );
    await _remote.writeAudit(
      organizationId: _orgId,
      action: 'MEMBER_INVITE_RESENT',
      entityType: 'member',
      entityId: memberIdOut,
      details: {
        'email': target.email,
        'role': target.role,
        'roles': target.effectiveRoles,
      },
    );
    await _owner.onRosterChanged?.call();
  }

  @override
  Future<void> changeRole({
    required String memberId,
    required String role,
    List<String>? roles,
  }) async {
    final assignedRoles = roles ?? [role];
    if (!AppRoles.isValid(role) ||
        role == AppRoles.trialOwner ||
        assignedRoles.isEmpty ||
        assignedRoles.first != role ||
        !AppRoles.isValidAssignment(assignedRoles)) {
      throw OrganizationFailure(
        AppText.t('الدور غير صالح', 'Invalid role.'),
        code: 'validation',
      );
    }
    if (memberId == _guard.memberId) {
      throw OrganizationFailure(
        AppText.t(
          'لا يمكنك تغيير دورك بنفسك — اطلب من مالك آخر.',
          'You cannot change your own role — ask another owner.',
        ),
        code: 'validation',
      );
    }
    _requireOnline();
    _owner._require('users.update');
    try {
      await _remote.updateMember(
        organizationId: _orgId,
        memberId: memberId,
        data: {'role': role, 'roles': assignedRoles},
      );
    } on Object catch (e) {
      throw _mapRemoteError(e);
    }
    await _remote.writeAudit(
      organizationId: _orgId,
      action: 'MEMBER_ROLE_CHANGED',
      entityType: 'member',
      entityId: memberId,
      details: {'role': role, 'roles': assignedRoles},
    );
    await _owner.onRosterChanged?.call();
  }

  @override
  Future<void> setStatus({
    required String memberId,
    required String status,
  }) async {
    if (status != 'active' && status != 'disabled') {
      throw OrganizationFailure(
        AppText.t('الحالة غير صالحة', 'Invalid status.'),
        code: 'validation',
      );
    }
    if (status == 'disabled' && memberId == _guard.memberId) {
      throw OrganizationFailure(
        AppText.t(
          'لا يمكنك تعطيل نفسك — استخدم المغادرة بدلًا من ذلك.',
          'You cannot disable yourself — use Leave instead.',
        ),
        code: 'validation',
      );
    }
    _requireOnline();
    _owner._require(status == 'active' ? 'users.update' : 'users.disable');
    try {
      await _remote.updateMember(
        organizationId: _orgId,
        memberId: memberId,
        data: {'status': status, if (status == 'active') 'activatedAt': null},
      );
    } on Object catch (e) {
      throw _mapRemoteError(e);
    }
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
      throw OrganizationFailure(
        AppText.t(
          'لا يمكنك إزالة نفسك من المؤسسة',
          'You cannot remove yourself from the organization.',
        ),
        code: 'validation',
      );
    }
    _requireOnline();
    _owner._require('users.disable');
    try {
      await _remote.deleteMember(organizationId: _orgId, memberId: memberId);
    } on Object catch (e) {
      throw _mapRemoteError(e);
    }
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
  ///
  /// The one exception is the company owner: the company must never be left
  /// without an active owner, so an `admin` who is the last active owner is
  /// refused until a co-owner has been invited **and activated**.
  @override
  Future<void> leave() async {
    final uid = _guard.uid;
    final memberId = _guard.memberId;
    if (uid.isEmpty || memberId.isEmpty || _orgId.isEmpty) {
      throw OrganizationFailure(
        AppText.t(
          'جلسة الدخول غير مكتملة، أعد تسجيل الدخول',
          'Sign-in session is incomplete, please sign in again.',
        ),
        code: 'signed_out',
      );
    }
    await _requireSuccessorOwner(uid: uid, memberId: memberId);
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

  /// Refuses to let the last active owner leave.
  ///
  /// A company must always keep at least one active owner, otherwise it becomes
  /// ownerless and unmanageable (`ownerUid` is immutable in the rules, so there
  /// is no way to appoint one afterwards). The check only applies to the
  /// `admin` role — a `trial_owner` is a single-user trial and cannot invite
  /// anyone, so blocking the departure would trap them.
  ///
  /// Best-effort by design: if the roster cannot be read (offline / denied) the
  /// member is not trapped; the UI blocks the button in the normal path.
  Future<void> _requireSuccessorOwner({
    required String uid,
    required String memberId,
  }) async {
    late final List<Member> members;
    try {
      members = await listMembers();
    } on Object {
      return;
    }
    Member? self;
    for (final member in members) {
      if (member.id == memberId ||
          (member.uid.isNotEmpty && member.uid == uid)) {
        self = member;
        break;
      }
    }
    final owner = self;
    if (owner == null || owner.role != AppRoles.admin) return;
    final hasSuccessor = members.any(
      (member) =>
          member.isActive &&
          member.role == AppRoles.admin &&
          member.id != owner.id,
    );
    if (!hasSuccessor) {
      throw OrganizationFailure(
        AppText.t(
          'لا يمكنك مغادرة الشركة إلا بعد إضافة مالك آخر وتفعيله. '
              'استخدم «دعوة مالك آخر» ثم فعّل الدعوة أولاً.',
          'You cannot leave the company until another owner is added and '
              'activated. Use "Invite co-owner" first, then activate it.',
        ),
        code: 'last_owner',
      );
    }
  }

  /// Active first, then invited/pending, then disabled.
  static int _statusOrder(String status) => switch (status) {
    'active' => 0,
    'invited' => 1,
    'pending_activation' => 1,
    _ => 2,
  };

  /// Minimal RFC-5322-ish check: one `@`, a dot after it, no spaces.
  static bool _emailLooksValid(String email) {
    if (email.contains(' ')) return false;
    final parts = email.split('@');
    if (parts.length != 2) return false;
    if (parts[0].isEmpty || parts[1].isEmpty) return false;
    if (!parts[1].contains('.')) return false;
    return true;
  }

  /// Maps raw Firestore/remote errors to bilingual `OrganizationFailure`s so
  /// technical strings (`permission-denied`, `unavailable`) never reach the UI.
  static OrganizationFailure _mapRemoteError(Object e) {
    final text = '$e';
    if (text.contains('permission-denied') ||
        text.contains('PERMISSION_DENIED') ||
        text.contains('permission_denied')) {
      return OrganizationFailure(
        AppText.t(
          'تم الرفض من الخادم — تحقق من صلاحياتك وحدّث القائمة.',
          'Rejected by the server — check your permissions and refresh.',
        ),
        code: 'not_allowed',
      );
    }
    if (text.contains('unavailable') ||
        text.contains('deadline-exceeded') ||
        text.contains('network') ||
        text.contains('offline')) {
      return OrganizationFailure(
        AppText.t(
          'لا يوجد اتصال بالإنترنت — تحقق من الشبكة وحاول مجددًا.',
          'No internet connection — check the network and try again.',
        ),
        code: 'offline',
      );
    }
    if (e is OrganizationFailure) return e;
    return OrganizationFailure(
      AppText.t(
        'تعذّر إتمام العملية. حاول مرة أخرى.',
        'Could not complete the operation. Try again.',
      ),
      code: 'remote_error',
    );
  }
}
