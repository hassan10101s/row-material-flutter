/// Single source of truth for roles → permissions (plan §7.1).
///
/// The identical lists live in `firestore.rules`
/// (`function rolePermissions(role)`); `test/security/permissions_parity_test.dart`
/// fails if the two ever drift apart.
library;

import '../constants/app_strings.dart';

enum Permission {
  orgRead('org.read', false),
  orgUpdate('org.update', true),
  usersRead('users.read', false),
  usersCreate('users.create', true),
  usersUpdate('users.update', true),
  usersDisable('users.disable', true),
  samplesRead('samples.read', false),
  samplesCreate('samples.create', true),
  samplesUpdate('samples.update', true),
  labResultsRead('lab_results.read', false),
  labResultsCreate('lab_results.create', true),
  labResultsUpdate('lab_results.update', true),
  qcRead('qc.read', false),
  qcWrite('qc.write', true),
  qcApprove('qc.approve', true),
  qcReject('qc.reject', true),
  reportsRead('reports.read', false),
  reportsCreate('reports.create', true),
  // Rendering/exporting existing data never mutates shared business records.
  reportsExport('reports.export', false),
  devicesRead('devices.read', false),
  devicesRegister('devices.register', true, technical: true),
  devicesUpdate('devices.update', true, technical: true),
  formulationsRead('formulations.read', false),
  formulationsCreate('formulations.create', true),
  formulationsUpdate('formulations.update', true),
  referenceUpdate('reference.update', true),
  auditRead('audit.read', false);

  const Permission(this.id, this.writes, {this.technical = false});

  /// Firestore/rules identifier (`'samples.read'`).
  final String id;

  /// True when holding the permission implies a write capability. Read-only
  /// permissions are `false`, which is what makes `roleIsReadOnly('viewer')`
  /// and `User.isReadOnly` correct.
  final bool writes;

  /// Metadata-only write (`devices.register`): the device has to be listed in
  /// the organization inventory even when the role is read-only, but it never
  /// unlocks a domain write, so it is ignored by the read-only computation.
  final bool technical;

  static Permission? byId(String id) {
    for (final p in Permission.values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

/// Privileged operations (member management, organization settings, QC
/// decisions) require a fresh session **and** connectivity (plan §8.4/§9.4).
const Set<Permission> privilegedPermissions = {
  Permission.orgUpdate,
  Permission.usersCreate,
  Permission.usersUpdate,
  Permission.usersDisable,
  Permission.qcApprove,
  Permission.qcReject,
};

/// Legacy UI freshness exemption for organization owners. This never bypasses
/// the ten-day sign-in policy, explicit online submission or Firestore checks.
/// Offline candidates remain local drafts until manually submitted; reconnect
/// never sends them automatically.
const Set<String> freshSessionExemptRoles = {AppRoles.admin};

/// True when [permission] may only run online with a non-expired token.
///
/// [role] is the holder's role. A role in [freshSessionExemptRoles] returns
/// false for every permission, because it is not subject to the requirement at
/// all. Omitting [role] answers the role-independent question - "is this
/// permission privileged?" - which is what the error-reporting call sites want
/// when they are classifying a refusal they did not cause.
bool permissionRequiresFreshSession(Permission permission, {String? role}) {
  if (role != null && freshSessionExemptRoles.contains(role)) return false;
  return privilegedPermissions.contains(permission);
}

/// The organization roles.
///
/// `trial_owner` is the founder of a trial company (plan: single-company
/// policy §4): a single-user company with limited permissions. It can view
/// screens, create demo data and try checks/analytics/inventory/quality, but
/// it cannot manage other companies, touch another company's data, approve
/// global permissions or change sensitive member rules. A trial company is
/// promoted to `active` / `admin` later by a system admin or an internal
/// approval action.
abstract final class AppRoles {
  static const String admin = 'admin';
  static const String qualityManager = 'quality_manager';
  static const String lab = 'lab';
  static const String nutritionist = 'nutritionist';
  static const String viewer = 'viewer';
  static const String trialOwner = 'trial_owner';

  static const List<String> all = [
    admin,
    qualityManager,
    lab,
    nutritionist,
    viewer,
    trialOwner,
  ];

  /// Roles that own/manage a company (full or trial).
  static const List<String> owners = [admin, trialOwner];

  static bool isValid(String? role) => role != null && all.contains(role);

  /// Canonical role set used by the authorization source. Legacy documents
  /// still carry only `role`; callers supply that as [fallbackRole].
  static List<String> normalizeRoles(Object? raw, {String? fallbackRole}) {
    final fallback = normalizeRole(fallbackRole);
    // Only an absent array denotes a legacy single-role record. A present
    // malformed array must never recover grants from its primary role.
    if (raw == null) return [fallback];
    if (raw is! List || raw.any((value) => value is! String)) return [viewer];
    final roles = raw.cast<String>();
    if (!isValidAssignment(roles) || roles.first != fallback) return [viewer];
    return roles.toList(growable: false);
  }

  /// Owner roles remain exclusive to preserve company ownership semantics.
  /// Viewer can be combined with employee roles as an additional read grant.
  static bool isValidAssignment(Iterable<String> values) {
    final list = values.toList();
    final roles = list.toSet();
    if (roles.length != list.length) return false;
    if (roles.isEmpty || roles.any((role) => !isValid(role))) return false;
    if (roles.length > 1 &&
        roles.any((role) => role == admin || role == trialOwner)) {
      return false;
    }
    return true;
  }

  static String labelMany(Iterable<String> roles) =>
      roles.map(label).join(' + ');

  /// Viewer devices are read-only dashboards (plan §14-P8.3).
  static bool isReadOnlyRole(String? role) => role == viewer;

  static String label(String role) => switch (role) {
    admin => AppText.t('مدير المؤسسة', 'Organization owner'),
    qualityManager => AppText.t('مدير الجودة', 'Quality manager'),
    lab => AppText.t('أخصائي جودة', 'Quality specialist'),
    nutritionist => AppText.t('أخصائي تغذية', 'Nutrition specialist'),
    viewer => AppText.t('اطّلاع فقط', 'Viewer'),
    trialOwner => AppText.t('مالك تجريبي', 'Trial owner'),
    _ => role,
  };
}

/// Organization lifecycle states (plan: single-company policy §4).
///
/// Trial model (30-day one-time trial):
/// `trial` → (after 30 days) → `suspended` → (manual activation by support)
/// → `active` (permanent, never auto-suspended again).
///
/// `disabled` is a legacy value kept for backward compatibility with older
/// documents; new code never writes it.
abstract final class OrgStatus {
  static const String trial = 'trial';
  static const String suspended = 'suspended';
  static const String active = 'active';
  static const String disabled = 'disabled';

  static const List<String> all = [trial, suspended, active, disabled];

  /// Statuses in which an organization is usable (dashboard + sync open).
  /// `suspended` is the only non-usable state for trial expiry: the member
  /// may still be `active`, but the company is locked until manual activation.
  static const List<String> usable = [trial, active];

  /// Length of the one-time free trial, in days.
  static const int trialDays = 30;

  static bool isSuspended(String? status) => status == suspended;

  static bool isUsable(String? status) => status == trial || status == active;
}

/// Member states.
///
/// Flow: `invited` (manager sent the invite) → member signs in with a password
/// or Google → `pending_activation` → manager activates → `active`.
/// `disabled` is terminal (kept as audit history, never hard-deleted).
/// `no_company` is not stored: it is the absence of `organizationId`.
abstract final class MemberStatus {
  static const String invited = 'invited';
  static const String pendingActivation = 'pending_activation';
  static const String active = 'active';
  static const String disabled = 'disabled';

  static const List<String> all = [
    invited,
    pendingActivation,
    active,
    disabled,
  ];

  /// Blocks creating a new company while bound to a current one (plan §2):
  /// `invited`, `pending_activation` or `active` with a non-null
  /// `organizationId`. Sign-out alone never clears this; only leaving does.
  static bool blocksNewCompany(String? status) =>
      status == invited || status == pendingActivation || status == active;

  /// May enter the company dashboard / open the company database / sync.
  static bool mayEnter(String? status) => status == active;
}

/// Explicit permission list per role — no wildcard entries (plan §7.1).
const Map<String, Set<Permission>> _rolePermissions = {
  AppRoles.admin: {
    Permission.orgRead,
    Permission.orgUpdate,
    Permission.usersRead,
    Permission.usersCreate,
    Permission.usersUpdate,
    Permission.usersDisable,
    Permission.samplesRead,
    Permission.samplesCreate,
    Permission.samplesUpdate,
    Permission.labResultsRead,
    Permission.labResultsCreate,
    Permission.labResultsUpdate,
    Permission.qcRead,
    Permission.qcWrite,
    Permission.qcApprove,
    Permission.qcReject,
    Permission.reportsRead,
    Permission.reportsCreate,
    Permission.reportsExport,
    Permission.devicesRead,
    Permission.devicesRegister,
    Permission.devicesUpdate,
    Permission.auditRead,
    Permission.formulationsRead,
    Permission.formulationsCreate,
    Permission.formulationsUpdate,
    Permission.referenceUpdate,
  },
  AppRoles.qualityManager: {
    Permission.orgRead,
    Permission.usersRead,
    Permission.samplesRead,
    Permission.samplesCreate,
    Permission.samplesUpdate,
    Permission.labResultsRead,
    Permission.labResultsCreate,
    Permission.labResultsUpdate,
    Permission.qcRead,
    Permission.qcWrite,
    Permission.qcApprove,
    Permission.qcReject,
    Permission.reportsRead,
    Permission.reportsCreate,
    Permission.reportsExport,
    Permission.devicesRegister,
    Permission.auditRead,
    Permission.formulationsRead,
    Permission.referenceUpdate,
  },
  AppRoles.lab: {
    Permission.orgRead,
    Permission.usersRead,
    Permission.samplesRead,
    Permission.samplesCreate,
    Permission.samplesUpdate,
    Permission.labResultsRead,
    Permission.labResultsCreate,
    Permission.labResultsUpdate,
    Permission.qcRead,
    Permission.qcWrite,
    Permission.qcApprove,
    Permission.qcReject,
    Permission.reportsRead,
    Permission.reportsCreate,
    Permission.reportsExport,
    Permission.devicesRegister,
    Permission.auditRead,
    Permission.formulationsRead,
    Permission.referenceUpdate,
  },
  AppRoles.viewer: {
    Permission.orgRead,
    Permission.samplesRead,
    Permission.labResultsRead,
    Permission.qcRead,
    Permission.reportsRead,
    Permission.reportsExport,
    Permission.devicesRegister,
    Permission.formulationsRead,
  },
  AppRoles.nutritionist: {
    Permission.orgRead,
    Permission.samplesRead,
    Permission.labResultsRead,
    Permission.reportsRead,
    Permission.devicesRegister,
    Permission.formulationsRead,
    Permission.formulationsCreate,
    Permission.formulationsUpdate,
  },
  // Trial owner (plan §4): demo data + checks/analytics + inventory/quality,
  // but none of the sensitive operations (no users.*, no org.update, no
  // qc.approve/reject, no reports.export, no audit.read, no devices.update).
  AppRoles.trialOwner: {
    Permission.orgRead,
    Permission.samplesRead,
    Permission.samplesCreate,
    Permission.samplesUpdate,
    Permission.labResultsRead,
    Permission.labResultsCreate,
    Permission.labResultsUpdate,
    Permission.qcRead,
    Permission.qcWrite,
    Permission.reportsRead,
    Permission.reportsCreate,
    Permission.devicesRegister,
    Permission.formulationsRead,
    Permission.formulationsCreate,
    Permission.formulationsUpdate,
  },
};

/// Permissions granted to [role] (empty for unknown roles).
Set<Permission> rolePermissions(String? role) =>
    _rolePermissions[role] ?? const <Permission>{};

/// Additive grants for an employee with multiple roles.
Set<Permission> rolesPermissions(Iterable<String> roles) => {
  for (final role in roles) ...rolePermissions(role),
};

/// Permissions serialized for the offline session cache / device registry.
Set<String> rolePermissionIds(String? role) =>
    rolePermissions(role).map((p) => p.id).toSet();

/// True when the role set contains [permission].
bool roleHas(String? role, Permission permission) =>
    rolePermissions(role).contains(permission);

bool rolesHave(Iterable<String> roles, Permission permission) =>
    rolesPermissions(roles).contains(permission);

/// Read-only when the role grants no domain write permission (metadata writes
/// such as `devices.register` do not count).
bool roleIsReadOnly(String? role) =>
    !rolePermissions(role).any((p) => p.writes && !p.technical);

bool rolesAreReadOnly(Iterable<String> roles) =>
    !rolesPermissions(roles).any((p) => p.writes && !p.technical);

/// Map the pre-V2 role strings (`Admin`, `Lab User`, `Quality Manager`,
/// `Developer`, `Viewer`) onto the V2 roles. Unknown values degrade to
/// [AppRoles.viewer] so a corrupt row can never grant write access.
String normalizeRole(String? role) => switch (role) {
  'Developer' || 'Admin' => AppRoles.admin,
  'Lab User' || 'Lab' => AppRoles.lab,
  'Quality Manager' || 'QualityManager' => AppRoles.qualityManager,
  'Nutritionist' || 'nutritionist' => AppRoles.nutritionist,
  'Viewer' || 'viewer' => AppRoles.viewer,
  final String value when AppRoles.isValid(value) => value,
  _ => AppRoles.viewer,
};

/// Same idea for `status`; anything unknown or missing on an account that is
/// bound to an organization is treated as `pending_activation` (never active),
/// so a legacy row without a status waits for activation instead of entering
/// the dashboard automatically (plan §9). `AppSession.fromJson` still degrades
/// a corrupt local cache to `invited` via [normalizeCachedStatus].
String normalizeMemberStatus(String? status) => switch (status) {
  MemberStatus.active => MemberStatus.active,
  MemberStatus.disabled => MemberStatus.disabled,
  MemberStatus.pendingActivation => MemberStatus.pendingActivation,
  MemberStatus.invited => MemberStatus.invited,
  // Legacy: empty/missing status on a bound account ⇒ pending activation.
  _ => MemberStatus.pendingActivation,
};

/// Corrupt local cache variant: degrades to `invited` (never active).
String normalizeCachedStatus(String? status) => switch (status) {
  MemberStatus.active => MemberStatus.active,
  MemberStatus.disabled => MemberStatus.disabled,
  MemberStatus.pendingActivation => MemberStatus.pendingActivation,
  MemberStatus.invited => MemberStatus.invited,
  _ => MemberStatus.invited,
};
