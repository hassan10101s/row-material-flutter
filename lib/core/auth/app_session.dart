import 'dart:convert';

import 'permissions.dart';

/// The signed-in identity + organization binding of this device.
///
/// This is the *local* source of truth for the write guards (plan §9.4) and
/// the only thing the UI is allowed to read for permission checks. The remote
/// Firestore rules remain the second, independent layer.
class AppSession {
  const AppSession({
    this.uid = '',
    this.email = '',
    this.displayName = '',
    this.photoUrl,
    this.organizationId = '',
    this.memberId = '',
    this.role = AppRoles.viewer,
    this.status = MemberStatus.invited,
    this.deviceId = '',
    this.readOnlyDevice = false,
    this.signedInAt,
    this.idToken,
    this.idTokenExpiresAt,
    this.offline = false,
    this.organizationStatus = '',
    this.trialEndsAt,
    this.manuallyActivated = false,
  });

  final String uid;
  final String email;
  final String displayName;
  final String? photoUrl;
  final String organizationId;
  final String memberId;
  final String role;
  final String status;
  final String deviceId;

  /// True for dashboard devices (role `viewer`): UI hides writes and the
  /// repositories reject them locally.
  final bool readOnlyDevice;

  final DateTime? signedInAt;
  final String? idToken;
  final DateTime? idTokenExpiresAt;

  /// True when this session was restored from the offline cache.
  final bool offline;

  /// Organization-level lifecycle (`trial` / `suspended` / `active`).
  /// Empty when no organization is bound yet. Persisted in the cache so an
  /// expired trial stays blocked offline too.
  final String organizationStatus;

  /// ISO-8601 of when the 30-day trial ends (null for legacy / active orgs).
  final String? trialEndsAt;

  /// True once support manually activated the company. Permanent: such a
  /// session must never be treated as expired.
  final bool manuallyActivated;

  bool get isSignedIn => uid.isNotEmpty;

  bool get hasOrganization => organizationId.isNotEmpty;

  bool get isActiveMember => status == MemberStatus.active;

  bool get isInvited => status == MemberStatus.invited;

  bool get isPendingActivation => status == MemberStatus.pendingActivation;

  /// Waiting for the manager: `invited` or `pending_activation`.
  bool get isAwaitingActivation => isInvited || isPendingActivation;

  bool get isDisabled => status == MemberStatus.disabled;

  /// True when the bound organization itself is suspended (trial finished and
  /// waiting for manual activation), even though the member row is `active`.
  /// Suspended members see the trial-expired screen, never the dashboard.
  bool get isOrgSuspended =>
      organizationStatus == OrgStatus.suspended ||
      organizationStatus == OrgStatus.disabled;

  /// True when the bound company is in its trial window.
  bool get isOrgTrial => organizationStatus == OrgStatus.trial;

  /// No company binding (plan §1 `no_company`): may create a trial company or
  /// join with an invite.
  bool get hasNoCompany => organizationId.isEmpty;

  /// Blocks creating a new company (plan §2): bound + invited/pending/active.
  /// Sign-out alone never clears this; only leaving does.
  bool get blocksNewCompany =>
      organizationId.isNotEmpty &&
      MemberStatus.blocksNewCompany(status);

  /// The only state allowed into the dashboard, the company database and the
  /// sync cycle (plan §5/§8/§12): an `active` member of a usable company.
  /// A suspended company never enters, even with an `active` member row.
  /// An empty [organizationStatus] (legacy cache / org read skipped) does not
  /// block here; the repository gate already handled the known cases.
  bool get mayEnterCompany =>
      organizationId.isNotEmpty &&
      MemberStatus.mayEnter(status) &&
      !isOrgSuspended;

  /// Can this device write anything at all?
  bool get canWrite => isActiveMember && !readOnlyDevice;

  Set<Permission> get permissions => rolePermissions(role);

  bool can(Permission permission) =>
      isActiveMember && permissions.contains(permission);

  /// Guard used before every write (plan §9.4). [online] comes from
  /// `ConnectivityService.isOnline`.
  ///
  /// The role is passed to [permissionRequiresFreshSession] so the organization
  /// manager is exempt from the online/fresh-token requirement on the
  /// privileged operations; see [freshSessionExemptRoles] for why that is safe.
  /// The read-only-device and active-member checks above are not part of that
  /// exemption and still refuse.
  bool canDo(Permission permission, {bool online = true}) {
    if (readOnlyDevice) return false;
    if (!isActiveMember) return false;
    if (!permissions.contains(permission)) return false;
    if (permissionRequiresFreshSession(permission, role: role) &&
        (!online || !isTokenFresh)) {
      return false;
    }
    return true;
  }

  /// Privileged operations (member management, org settings, QC decisions) need
  /// a fresh session *and* connectivity (plan §8.4).
  bool get isTokenFresh {
    final expiry = idTokenExpiresAt;
    if (expiry == null) return false;
    return DateTime.now().isBefore(expiry);
  }

  AppSession copyWith({
    String? uid,
    String? email,
    String? displayName,
    String? photoUrl,
    String? organizationId,
    String? memberId,
    String? role,
    String? status,
    String? deviceId,
    bool? readOnlyDevice,
    DateTime? signedInAt,
    String? idToken,
    DateTime? idTokenExpiresAt,
    bool? offline,
    String? organizationStatus,
    String? trialEndsAt,
    bool? manuallyActivated,
    bool clearToken = false,
    bool clearTrialEndsAt = false,
  }) => AppSession(
    uid: uid ?? this.uid,
    email: email ?? this.email,
    displayName: displayName ?? this.displayName,
    photoUrl: photoUrl ?? this.photoUrl,
    organizationId: organizationId ?? this.organizationId,
    memberId: memberId ?? this.memberId,
    role: role ?? this.role,
    status: status ?? this.status,
    deviceId: deviceId ?? this.deviceId,
    readOnlyDevice: readOnlyDevice ?? this.readOnlyDevice,
    signedInAt: signedInAt ?? this.signedInAt,
    idToken: clearToken ? null : (idToken ?? this.idToken),
    idTokenExpiresAt: clearToken
        ? null
        : (idTokenExpiresAt ?? this.idTokenExpiresAt),
    offline: offline ?? this.offline,
    organizationStatus: organizationStatus ?? this.organizationStatus,
    trialEndsAt: clearTrialEndsAt ? null : (trialEndsAt ?? this.trialEndsAt),
    manuallyActivated: manuallyActivated ?? this.manuallyActivated,
  );

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'email': email,
    'displayName': displayName,
    'photoUrl': photoUrl,
    'organizationId': organizationId,
    'memberId': memberId,
    'role': role,
    'status': status,
    'deviceId': deviceId,
    'readOnlyDevice': readOnlyDevice,
    'signedInAt': signedInAt?.toIso8601String(),
    'idTokenExpiresAt': idTokenExpiresAt?.toIso8601String(),
    'organizationStatus': organizationStatus,
    'trialEndsAt': trialEndsAt,
    'manuallyActivated': manuallyActivated,
  };

  /// Rebuild a session from the on-disk cache.
  ///
  /// [role], [status] and [readOnlyDevice] are **not** fully trusted: an
  /// unrecognised value degrades to viewer/invited, but a *valid* cached role
  /// string is kept so an offline exempt admin still sees their workspace.
  /// This is defence in depth, not the authorization boundary — member writes
  /// additionally require live connectivity (`_requireOnline`) and Firestore
  /// re-derives role/status from `users/{uid}` and fails closed regardless,
  /// so a tampered cache at most shows buttons that then fail with
  /// `not_allowed`.
  static AppSession fromJson(Map<String, dynamic> json) {
    final role = normalizeRole(json['role'] as String?);
    return AppSession(
      uid: '${json['uid'] ?? ''}',
      email: '${json['email'] ?? ''}',
      displayName: '${json['displayName'] ?? ''}',
      photoUrl: json['photoUrl'] as String?,
      organizationId: '${json['organizationId'] ?? ''}',
      memberId: '${json['memberId'] ?? ''}',
      role: role,
      status: normalizeCachedStatus(json['status'] as String?),
      deviceId: '${json['deviceId'] ?? ''}',
      readOnlyDevice: roleIsReadOnly(role),
      signedInAt: _parseDate(json['signedInAt']),
      idToken: json['idToken'] as String?,
      idTokenExpiresAt: _parseDate(json['idTokenExpiresAt']),
      organizationStatus: '${json['organizationStatus'] ?? ''}',
      trialEndsAt: json['trialEndsAt'] as String?,
      manuallyActivated: json['manuallyActivated'] == true,
    );
  }

  static String encode(AppSession session) => jsonEncode(session.toJson());

  static AppSession decode(String raw) =>
      AppSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  static DateTime? _parseDate(Object? value) {
    if (value == null) return null;
    return DateTime.tryParse('$value');
  }

  @override
  String toString() =>
      'AppSession(uid: $uid, org: $organizationId, role: $role, status: $status, '
      'readOnly: $readOnlyDevice, offline: $offline)';
}

/// Empty session used before sign-in and by tests.
const AppSession kEmptySession = AppSession();
