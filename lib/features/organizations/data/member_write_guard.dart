import '../../../core/auth/app_session.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/auth/session_source.dart';

/// The session view the write paths need (plan §9.4).
///
/// Kept as an interface so tests can pass a plain object, and so the
/// repositories never depend on how the session is stored. It started life as
/// `MemberWriteGuard`; §9.4 applies to *every* local write, so the interface is
/// now generic and [memberWriteGuard] keeps the old name working.
abstract interface class WriteGuard {
  String get uid;
  String get email;
  String get organizationId;
  String get memberId;

  /// Organization-scoped identity of this device; it is what a local write
  /// stamps into the queued payload so the next push can attribute it.
  String get deviceId;
  bool get online;

  /// True when the session may perform [permissionId] *right now*: a fresh
  /// token **and** connectivity for the privileged operations.
  bool allows(String permissionId);
}

/// Backwards-compatible alias for the organization/member repositories.
typedef MemberWriteGuard = WriteGuard;

/// Production implementation reading straight from the live [AppSession].
///
/// Both the session and the connectivity are pulled on every call, so a
/// sign-in, a sign-out, an organization switch or a connectivity change is
/// picked up without re-registering anything.
class SessionWriteGuard implements WriteGuard {
  const SessionWriteGuard({
    required this.source,
    required this.isOnline,
  });

  final SessionSource source;
  final bool Function() isOnline;

  AppSession get session => source.session;

  @override
  String get uid => session.uid;

  @override
  String get email => session.email;

  @override
  String get organizationId => session.organizationId;

  @override
  String get memberId => session.memberId;

  @override
  String get deviceId => session.deviceId;

  @override
  bool get online => isOnline();

  @override
  bool allows(String permissionId) {
    final permission = Permission.byId(permissionId);
    if (permission == null) return false;
    return session.canDo(permission, online: online);
  }
}
