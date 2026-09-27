/// Single source of truth for roles → permissions (plan §7.1).
///
/// The identical lists live in `firestore.rules`
/// (`function rolePermissions(role)`); `test/security/permissions_parity_test.dart`
/// fails if the two ever drift apart.
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
  qcApprove('qc.approve', true),
  qcReject('qc.reject', true),
  reportsRead('reports.read', false),
  reportsCreate('reports.create', true),
  reportsExport('reports.export', true),
  devicesRead('devices.read', false),
  devicesRegister('devices.register', true, technical: true),
  devicesUpdate('devices.update', true, technical: true),
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

/// True when [permission] may only run online with a non-expired token.
bool permissionRequiresFreshSession(Permission permission) =>
    privilegedPermissions.contains(permission);

/// The four organization roles (V1).
abstract final class AppRoles {
  static const String admin = 'admin';
  static const String qualityManager = 'quality_manager';
  static const String lab = 'lab';
  static const String viewer = 'viewer';

  static const List<String> all = [admin, qualityManager, lab, viewer];

  static bool isValid(String? role) => role != null && all.contains(role);

  /// Viewer devices are read-only dashboards (plan §14-P8.3).
  static bool isReadOnlyRole(String? role) => role == viewer;

  static String label(String role) => switch (role) {
        admin => 'مدير المؤسسة',
        qualityManager => 'مدير الجودة',
        lab => 'فني مختبر',
        viewer => 'اطّلاع فقط',
        _ => role,
      };
}

/// Member states.
abstract final class MemberStatus {
  static const String invited = 'invited';
  static const String active = 'active';
  static const String disabled = 'disabled';

  static const List<String> all = [invited, active, disabled];
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
    Permission.qcApprove,
    Permission.qcReject,
    Permission.reportsRead,
    Permission.reportsCreate,
    Permission.reportsExport,
    Permission.devicesRead,
    Permission.devicesRegister,
    Permission.devicesUpdate,
    Permission.auditRead,
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
    Permission.qcApprove,
    Permission.qcReject,
    Permission.reportsRead,
    Permission.reportsCreate,
    Permission.reportsExport,
    Permission.auditRead,
  },
  AppRoles.lab: {
    Permission.orgRead,
    Permission.samplesRead,
    Permission.samplesCreate,
    Permission.samplesUpdate,
    Permission.labResultsRead,
    Permission.labResultsCreate,
    Permission.labResultsUpdate,
    Permission.reportsRead,
    Permission.devicesRegister,
  },
  AppRoles.viewer: {
    Permission.orgRead,
    Permission.samplesRead,
    Permission.labResultsRead,
    Permission.qcRead,
    Permission.reportsRead,
    Permission.devicesRegister,
  },
};

/// Permissions granted to [role] (empty for unknown roles).
Set<Permission> rolePermissions(String? role) =>
    _rolePermissions[role] ?? const <Permission>{};

/// Permissions serialized for the offline session cache / device registry.
Set<String> rolePermissionIds(String? role) =>
    rolePermissions(role).map((p) => p.id).toSet();

/// True when the role set contains [permission].
bool roleHas(String? role, Permission permission) =>
    rolePermissions(role).contains(permission);

/// Read-only when the role grants no domain write permission (metadata writes
/// such as `devices.register` do not count).
bool roleIsReadOnly(String? role) =>
    !rolePermissions(role).any((p) => p.writes && !p.technical);

/// Map the pre-V2 role strings (`Admin`, `Lab User`, `Quality Manager`,
/// `Developer`, `Viewer`) onto the V2 roles. Unknown values degrade to
/// [AppRoles.viewer] so a corrupt row can never grant write access.
String normalizeRole(String? role) => switch (role) {
      'Developer' || 'Admin' => AppRoles.admin,
      'Lab User' || 'Lab' => AppRoles.lab,
      'Quality Manager' || 'QualityManager' => AppRoles.qualityManager,
      'Viewer' || 'viewer' => AppRoles.viewer,
      final String value when AppRoles.isValid(value) => value,
      _ => AppRoles.viewer,
    };

/// Same idea for `status`; anything unknown is treated as `invited` (never
/// active), which keeps a damaged row from unlocking the UI.
String normalizeMemberStatus(String? status) => switch (status) {
      MemberStatus.active => MemberStatus.active,
      MemberStatus.disabled => MemberStatus.disabled,
      _ => MemberStatus.invited,
    };
