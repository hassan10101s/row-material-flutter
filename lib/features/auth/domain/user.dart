import '../../../core/auth/permissions.dart';

/// Member entity as stored in the local `users` table (V2 roster).
///
/// The getters are the single place where the old role strings were hard-coded
/// (`isDeveloper`, `canManageSettings`, ...). They now derive from the shared
/// permission matrix in `core/auth/permissions.dart`, so every existing call
/// site keeps compiling while the rules live in one file (plan §7.3).
class User {
  const User({
    this.id,
    this.uid,
    this.memberId,
    required this.email,
    this.fullName = '',
    this.role = AppRoles.viewer,
    this.status = MemberStatus.invited,
    this.displayName = '',
    this.photoUrl,
    this.version = 1,
    this.createdAt = '',
    this.readOnlyDevice = false,
  });

  final int? id;

  /// Firebase UID (`NULL` until the member signs in for the first time).
  final String? uid;

  /// `member_<localId>` — the remote member document id.
  final String? memberId;

  final String email;
  final String fullName;
  final String role;

  /// `invited` | `active` | `disabled`.
  final String status;

  final String displayName;
  final String? photoUrl;
  final int version;
  final String createdAt;

  /// The device was switched to read-only (`session.readOnlyDevice`): every
  /// write is refused even when the role would allow it (plan §14-P8.3). The
  /// role itself is untouched, so the UI can still show what the member is.
  final bool readOnlyDevice;

  Set<Permission> get permissions => rolePermissions(role);

  bool get isActiveMember => status == MemberStatus.active;

  bool get isReadOnly => roleIsReadOnly(role) || readOnlyDevice;

  /// A read-only device offers no write affordance at all. The member status
  /// stays a session concern (`AppSession.canDo`), as documented for the
  /// invited-member case.
  bool get canWriteAnything => !readOnlyDevice;

  // ── Legacy call sites (kept so no widget/cubit had to change) ────────────
  // Read gates stay role-based, write gates also require a writable device.
  bool get canSeeSettings => permissions.contains(Permission.usersRead);
  bool get canEditInspections => canWriteAnything && permissions.contains(Permission.samplesUpdate);
  bool get canCreateInspection => canWriteAnything && permissions.contains(Permission.samplesCreate);
  bool get canEditUsers => canWriteAnything && permissions.contains(Permission.usersUpdate);
  bool get canManageSettings => canWriteAnything && permissions.contains(Permission.orgUpdate);
  bool get canApproveQuality => canWriteAnything && permissions.contains(Permission.qcApprove);
  bool get canReadAudit => permissions.contains(Permission.auditRead);

  String get label => displayName.isNotEmpty ? displayName : fullName;

  String get roleLabel => AppRoles.label(role);

  /// V1 display alias. In V2 the identity is the Google account, so the two
  /// remaining `@username` call sites show the e-mail instead.
  String get username => email;

  factory User.fromMap(Map<String, dynamic> map) => User(
        id: (map['id'] as num?)?.toInt(),
        uid: map['uid'] as String?,
        memberId: map['member_id'] as String?,
        email: '${map['email'] ?? map['username'] ?? ''}',
        fullName: '${map['full_name'] ?? ''}',
        role: normalizeRole('${map['role'] ?? AppRoles.viewer}'),
        status: normalizeMemberStatus('${map['status'] ?? ''}'),
        displayName: '${map['display_name'] ?? ''}',
        photoUrl: map['photo_url'] as String?,
        version: (map['version'] as num?)?.toInt() ?? 1,
        createdAt: '${map['created_at'] ?? ''}',
      );

  Map<String, dynamic> toMap({bool withId = true}) => {
        if (withId && id != null) 'id': id,
        if (uid != null) 'uid': uid,
        if (memberId != null) 'member_id': memberId,
        'email': email,
        'full_name': fullName,
        'role': role,
        'status': status,
        'display_name': displayName,
        if (photoUrl != null) 'photo_url': photoUrl,
        'version': version,
        'created_at': createdAt,
      };
}
