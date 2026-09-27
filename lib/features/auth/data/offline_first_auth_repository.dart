import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../../core/auth/app_session.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/firebase/firebase_bootstrap.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/sync/device_registry.dart';
import '../../../core/sync/remote/auth_remote_data_source.dart' show GoogleSignInException;
import '../../../core/sync/remote/remote_data_source.dart';
import '../../../core/sync/sync_metadata.dart';
import 'auth_repository.dart';

/// Offline-first authentication (plan §8.4, §14-P2.3).
///
/// Order of the state machine implemented here:
/// 1. `restoreSession()` — online: `users/{uid}`; offline: encrypted cache.
/// 2. no profile → [AuthState.noProfile] ⇒ `create-organization` screen.
/// 3. profile but `status != active` → [AuthState.awaitingActivation].
/// 4. active → [AuthState.ready] and the organization database is opened.
class OfflineFirstAuthRepository implements AuthRepository {
  OfflineFirstAuthRepository({
    required this.remote,
    required this.sessionStore,
    required this.dbHelper,
    required this.connectivity,
    required this.metadata,
    required this.bootstrap,
    this.devices,
    this.onOrganizationBound,
  });

  final AuthRemoteDataSource remote;
  final SessionStore sessionStore;
  final DatabaseHelper dbHelper;
  final ConnectivityService connectivity;
  final SyncMetadata metadata;
  final FirebaseBootstrapResult bootstrap;

  /// Device registry - only needed for "sign out of this device only"
  /// (plan §14-P9.1); absent in tests that do not exercise it.
  final DeviceRegistry? devices;


  /// Hook invoked once the organization database is ready (start the sync
  /// engine, run the per-org seeds, ...). Wired in `app_bootstrap.dart`.
  Future<void> Function(String organizationId)? onOrganizationBound;

  final StreamController<AuthState> _states = StreamController<AuthState>.broadcast();

  AppSession _session = kEmptySession;
  AuthState _state = AuthState.signedOut;
  String _deviceId = '';

  @override
  Stream<AuthState> get currentState => _states.stream;

  @override
  AuthState get state => _state;

  @override
  AppSession get session => _session;

  @override
  bool get isFirebaseAvailable => remote.isConfigured;

  @override
  List<String> get missingConfiguration => bootstrap.isReady ? const [] : bootstrap.missingKeys;

  // ── Restore ─────────────────────────────────────────────────────────────

  @override
  Future<AuthState> restoreSession() async {
    if (bootstrap.isUnconfigured) return _set(AuthState.needsBootstrap);
    _deviceId = await metadata.ensureDeviceId(_generateDeviceId);

    if (connectivity.isOnline && remote.isConfigured) {
      final user = await remote.currentUser();
      if (user != null) return _set(await resolveProfile(user: user));
    }
    final cached = await sessionStore.restore();
    if (cached != null) {
      _session = cached.copyWith(offline: true, clearToken: true);
      await _bindOrganization(_session.organizationId);
      // Same rule as the offline branch of `resolveProfile`: a cached
      // `invited`/`disabled` member must not be reported as ready, otherwise
      // booting offline hands the shell a dashboard the account cannot use.
      if (!_session.isActiveMember) return _set(AuthState.awaitingActivation);
      return _set(AuthState.ready);
    }
    return _set(AuthState.signedOut);
  }

  // ── Sign in ─────────────────────────────────────────────────────────────

  @override
  Future<void> signInWithGoogle() async {
    if (!remote.isConfigured) {
      throw const AuthFailure(
        'Firebase غير مهيأ — أضف إعدادات Firebase ثم أعد تشغيل التطبيق',
        code: 'missing_config',
      );
    }
    try {
      await remote.signInWithGoogle();
    } on GoogleSignInException catch (e) {
      throw AuthFailure(_googleMessage(e.message), code: _googleCode(e.message));
    } on Object catch (e) {
      throw AuthFailure('$e');
    }
    final user = await remote.currentUser();
    if (user == null) {
      throw const AuthFailure('لم يتم تسجيل الدخول عبر Google', code: 'cancelled');
    }
    await resolveProfile(user: user);
  }

  // ── Profile resolution ──────────────────────────────────────────────────

  @override
  Future<AuthState> resolveProfile({RemoteUser? user}) async {
    final account = user ?? await remote.currentUser();
    if (account == null) {
      _session = kEmptySession;
      return _set(AuthState.signedOut);
    }
    UserProfile? profile;
    try {
      profile = await remote.loadProfile(account.uid);
    } on Object catch (e) {
      if (!connectivity.isOnline) {
        final cached = await sessionStore.restore();
        if (cached != null) {
          _session = cached.copyWith(offline: true, clearToken: true);
          await _bindOrganization(_session.organizationId);
          // A cached `invited`/`disabled` session must never be reported as
          // ready: the shell would offer a dashboard the account cannot use.
          if (!_session.isActiveMember) return _set(AuthState.awaitingActivation);
          return _set(AuthState.ready);
        }
      }

      throw AuthFailure('$e');
    }

    if (profile == null) {
      _session = AppSession(
        uid: account.uid,
        email: account.email,
        displayName: account.displayName ?? '',
        photoUrl: account.photoUrl,
        deviceId: _deviceId,
        readOnlyDevice: false,
        signedInAt: DateTime.now(),
        status: MemberStatus.invited,
        organizationId: '',
      );
      return _set(AuthState.noProfile);
    }

    final readOnly = profile.role == AppRoles.viewer;
    _session = AppSession(
      uid: profile.uid,
      email: profile.email,
      displayName: profile.displayName.isNotEmpty ? profile.displayName : (account.displayName ?? ''),
      photoUrl: account.photoUrl,
      organizationId: profile.organizationId,
      memberId: profile.memberId,
      role: normalizeRole(profile.role),
      status: normalizeMemberStatus(profile.status),
      deviceId: _deviceId,
      readOnlyDevice: readOnly,
      signedInAt: DateTime.now(),
    );
    await _bindOrganization(_session.organizationId);
    await _persistSession();

    if (!_session.isActiveMember) return _set(AuthState.awaitingActivation);
    return _set(AuthState.ready);
  }

  // ── Organization switch / sign out ─────────────────────────────────────

  @override
  Future<void> changeOrganization(String organizationId) async {
    final profile = await remote.loadProfile(_session.uid);
    if (profile == null) {
      throw const AuthFailure('لا يوجد ملف مستخدم لهذا الحساب');
    }
    if (profile.organizationId != organizationId) {
      throw const AuthFailure('هذا الحساب غير مرتبط بالمؤسسة المختارة');
    }
    await _bindOrganization(organizationId);
    await _persistSession();
    _set(AuthState.ready);
  }

  @override
  Future<void> signOut() async {
    _session = kEmptySession;
    _state = AuthState.signedOut;
    await sessionStore.clear();
    await dbHelper.bindOrg(null);
    try {
      await remote.signOut();
    } on Object {
      // A failing network sign-out must not block the local sign-out.
    }
    _emit();
  }

  /// Signs out of **this** device only (plan §14-P9.1).
  ///
  /// The member stays active: their other devices keep their own session, the
  /// role is untouched, and nothing in the organization is modified. On the
  /// server this device is revoked (`status = 'revoked'`; the Rules forbid
  /// deleting a device document because the audit trail points at it), and
  /// locally the session is dropped exactly like [signOut].
  @override
  Future<void> signOutThisDevice() async {
    try {
      await devices?.signOutThisDevice();
    } on Object {
      // Offline or revoked: the local sign-out below must still happen.
    }
    await signOut();
  }


  // ── Internals ───────────────────────────────────────────────────────────

  /// Opens (or creates) the organization-scoped database and seeds it. Every
  /// read/write of the UI happens against this database afterwards.
  ///
  /// The [onOrganizationBound] side effects (seeds, auto-backup, device
  /// registration, sync engine) are expensive and destructive to the write path
  /// — `autoBackup` runs `VACUUM INTO`, which needs the database to itself — so
  /// they run **only when the organization actually changed**. `restoreSession`,
  /// `signInWithGoogle` and `CreateOrganizationCubit` all funnel through
  /// `resolveProfile`, so without this guard the whole binder ran three times in
  /// one startup and the live database was vacuumed while the UI was idle in the
  /// dashboard.
  Future<void> _bindOrganization(String organizationId) async {
    if (organizationId.isEmpty) return;
    final alreadyBound = dbHelper.boundOrgId == organizationId;
    await dbHelper.bindOrg(organizationId);
    if (alreadyBound) return;
    final callback = onOrganizationBound;
    if (callback != null) await callback(organizationId);
  }

  Future<void> _persistSession() async {
    if (!_session.isSignedIn) {
      await sessionStore.clear();
      return;
    }
    // The cached copy never carries a live token (plan §8.4).
    await sessionStore.save(_session.copyWith(offline: false));
  }

  AuthState _set(AuthState next) {
    _state = next;
    _emit();
    return next;
  }

  /// Stable per-machine id: `device_<os>_<hash of the user profile dir>`.
  /// Deliberately *not* a hardware id (plan P1.4) — no `device_info_plus`.
  static String _generateDeviceId() {
    final seed = '${Platform.operatingSystem}:${Platform.localHostname}';
    final digest = sha256.convert(utf8.encode(seed)).toString().substring(0, 16);
    return 'device_${Platform.operatingSystem}_$digest';
  }

  void _emit() {
    if (_states.isClosed) return;
    _states.add(_state);
  }

  void dispose() => _states.close();

  static String _googleCode(String message) {
    if (message.contains('cancelled')) return 'cancelled';
    if (message.contains('GOOGLE_WEB_CLIENT_ID') ||
        message.contains('GOOGLE_DESKTOP_CLIENT_ID')) {
      return 'missing_config';
    }
    if (message.contains('rejected')) return 'access_denied';
    return 'auth_failed';
  }

  static String _googleMessage(String message) => message;
}
