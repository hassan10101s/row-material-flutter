import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../../../core/auth/app_session.dart';
import '../../../core/auth/permissions.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/firebase/firebase_bootstrap.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/sync/device_registry.dart';
import '../../../core/sync/remote/auth_remote_data_source.dart'
    show GoogleSignInException, RemoteAuthException;
import '../../../core/sync/remote/remote_data_source.dart';
import '../../../core/sync/sync_metadata.dart';
import '../domain/auth_repository.dart';

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
    this.onSignedOut,
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
  /// Runs for `active` members only (plan §8): a pending/disabled account
  /// never opens the company database and never starts the sync cycle.
  Future<void> Function(String organizationId)? onOrganizationBound;

  /// Hook invoked on sign-out / leave so the sync cycle stops with the
  /// session (plan §3/§8): no heartbeat, no push/pull after unbinding.
  Future<void> Function()? onSignedOut;

  final StreamController<AuthState> _states =
      StreamController<AuthState>.broadcast();

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
  List<String> get missingConfiguration =>
      bootstrap.isReady ? const [] : bootstrap.missingKeys;

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
      // No local leak (plan §8): only an `active` member binds the company
      // database and starts the sync cycle. Anything else unbinds.
      if (_session.isActiveMember) {
        await _bindOrganization(_session.organizationId);
        return _set(AuthState.ready);
      }
      await dbHelper.bindOrg(null);
      return _set(AuthState.awaitingActivation);
    }
    return _set(AuthState.signedOut);
  }

  // ── Sign in ─────────────────────────────────────────────────────────────

  @override
  Future<void> signInWithGoogle() async {
    if (!remote.isConfigured) {
      throw AuthFailure(
        AppText.t(
          'تعذر تسجيل الدخول: لم يتم ضبط تسجيل Google بشكل صحيح. أعد تشغيل التطبيق بعد ضبط الإعدادات.',
          'Unable to sign in: Google sign-in is not configured correctly. Restart the app after fixing the configuration.',
        ),
        code: 'missing_config',
      );
    }
    try {
      await remote.signInWithGoogle();
    } on GoogleSignInException catch (e) {
      final code = _googleCode(e.message);
      debugPrint('[auth] google sign-in failed ($code): ${e.message}');
      throw AuthFailure(_userFacingMessage(code), code: code);
    } on Object catch (e) {
      debugPrint('[auth] google sign-in failed (unknown): $e');
      throw AuthFailure(_userFacingMessage('auth_failed'), code: 'auth_failed');
    }
    final user = await remote.currentUser();
    if (user == null) {
      throw AuthFailure(
        AppText.t('تم إلغاء تسجيل الدخول', 'Sign-in was cancelled'),
        code: 'cancelled',
      );
    }
    await resolveProfile(user: user);
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    if (!remote.isConfigured) {
      throw AuthFailure(
        AppText.t(
          'Firebase غير مضبوط. أكمل إعداد Firebase أولاً.',
          'Firebase is not configured. Complete the Firebase setup first.',
        ),
        code: 'missing_config',
      );
    }
    try {
      await remote.signInWithEmail(email: email, password: password);
      final user = await remote.currentUser();
      if (user == null) {
        throw AuthFailure(
          AppText.t(
            'تعذر استعادة حساب Firebase بعد تسجيل الدخول.',
            'Could not restore the Firebase account after sign-in.',
          ),
        );
      }
      await resolveProfile(user: user);
    } on RemoteAuthException catch (e) {
      throw AuthFailure(_emailMessage(e.code, e.message), code: e.code);
    }
  }

  @override
  Future<void> createPasswordAccount({
    required String email,
    required String password,
  }) async {
    if (!remote.isConfigured) {
      throw AuthFailure(
        AppText.t(
          'Firebase غير مضبوط. أكمل إعداد Firebase أولاً.',
          'Firebase is not configured. Complete the Firebase setup first.',
        ),
        code: 'missing_config',
      );
    }
    try {
      await remote.createPasswordAccount(email: email, password: password);
      final user = await remote.currentUser();
      if (user == null) {
        throw AuthFailure(
          AppText.t(
            'تعذر إنشاء حساب Firebase.',
            'Could not create the Firebase account.',
          ),
        );
      }
      await resolveProfile(user: user);
    } on RemoteAuthException catch (e) {
      throw AuthFailure(_emailMessage(e.code, e.message), code: e.code);
    }
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
          // A cached non-active session must never be reported as ready:
          // the shell would offer a dashboard the account cannot use, and
          // the company database must stay closed (plan §8).
          if (!_session.isActiveMember) {
            await dbHelper.bindOrg(null);
            return _set(AuthState.awaitingActivation);
          }
          await _bindOrganization(_session.organizationId);
          return _set(AuthState.ready);
        }
      }

      final code = connectivity.isOnline ? 'auth_failed' : 'offline';
      debugPrint('[auth] failed to load profile ($code): $e');
      throw AuthFailure(_userFacingMessage(code), code: code);
    }

    if (profile == null) {
      // `no_company` (plan §1): no `users/{uid}` binding yet. The account may
      // create a trial company or join with an invite.
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
      await dbHelper.bindOrg(null);
      return _set(AuthState.noProfile);
    }

    final readOnly = roleIsReadOnly(normalizeRole(profile.role));
    _session = AppSession(
      uid: profile.uid,
      email: profile.email,
      displayName: profile.displayName.isNotEmpty
          ? profile.displayName
          : (account.displayName ?? ''),
      photoUrl: account.photoUrl,
      organizationId: profile.organizationId,
      memberId: profile.memberId,
      role: normalizeRole(profile.role),
      status: normalizeMemberStatus(profile.status),
      deviceId: _deviceId,
      readOnlyDevice: readOnly,
      signedInAt: DateTime.now(),
    );
    // Plan §8: the company database opens and the sync cycle starts for
    // `active` members only. Anything else (invited/pending_activation /
    // disabled) unbinds locally and waits on the activation screen.
    if (!_session.isActiveMember) {
      await dbHelper.bindOrg(null);
      await _persistSession();
      return _set(AuthState.awaitingActivation);
    }
    await _bindOrganization(_session.organizationId);
    await _persistSession();

    return _set(AuthState.ready);
  }

  // ── Organization switch / sign out ─────────────────────────────────────

  @override
  Future<void> changeOrganization(String organizationId) async {
    final profile = await remote.loadProfile(_session.uid);
    if (profile == null) {
      throw AuthFailure(
        AppText.t(
          'لا يوجد ملف مستخدم لهذا الحساب',
          'No user profile exists for this account.',
        ),
      );
    }
    if (profile.organizationId != organizationId) {
      throw AuthFailure(
        AppText.t(
          'هذا الحساب غير مرتبط بالمؤسسة المختارة',
          'This account is not linked to the selected organization.',
        ),
      );
    }
    // A disabled/invited/pending member must not re-bind the org database:
    // the profile check above only verified the org id, not that the member
    // may still enter it.
    if (profile.status != 'active') {
      throw AuthFailure(
        AppText.t(
          'تم تعطيل عضويتك في هذه المؤسسة',
          'Your membership in this organization is not active.',
        ),
      );
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
    // Plan §3: leaving/sign-out drops the local binding (the company database
    // is closed) and stops the sync cycle; records stay server-side as audit
    // history and are never hard-deleted here.
    await dbHelper.bindOrg(null);
    try {
      await onSignedOut?.call();
    } on Object {
      // Stopping the engine must not block the local sign-out.
    }
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
    final digest = sha256
        .convert(utf8.encode(seed))
        .toString()
        .substring(0, 16);
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

  /// The only strings a sign-in failure may surface: clear, bilingual and free
  /// of any technical/exception detail. The raw plugin error is logged, never
  /// shown to the user.
  static String _userFacingMessage(String code) {
    switch (code) {
      case 'missing_config':
        return AppText.t(
          'تعذر تسجيل الدخول: لم يتم ضبط تسجيل Google بشكل صحيح. أعد تشغيل التطبيق بعد ضبط الإعدادات.',
          'Unable to sign in: Google sign-in is not set up correctly. Restart the app after fixing the configuration.',
        );
      case 'cancelled':
        return AppText.t('تم إلغاء تسجيل الدخول', 'Sign-in was cancelled');
      case 'access_denied':
        return AppText.t(
          'لم يُسمح بتسجيل الدخول. تحقق من إذن الوصول إلى حساب Google ثم حاول مرة أخرى.',
          'Sign-in was not allowed. Check Google account access and try again.',
        );
      case 'offline':
        return AppText.t(
          'لا يوجد اتصال بالإنترنت. تحقق من الشبكة ثم حاول مرة أخرى.',
          'No internet connection. Check your network and try again.',
        );
      default:
        return AppText.t(
          'تعذر تسجيل الدخول بحساب Google الآن. حاول مرة أخرى.',
          'Unable to sign in with Google right now. Please try again.',
        );
    }
  }

  /// Firebase Auth codes use hyphens (`invalid-email`) while the local
  /// contract uses underscores (`invalid_email`): normalize first so a
  /// hyphenated code never falls through to the raw English fallback.
  static String _emailMessage(String code, String fallback) {
    final normalized = code.replaceAll('-', '_');
    return switch (normalized) {
      'invalid_email' => AppText.t(
        'أدخل بريدًا إلكترونيًا صحيحًا.',
        'Enter a valid email address.',
      ),
    'member_exists' => AppText.t(
      'هذا البريد عضو نشط بالفعل في الشركة.',
      'This email is already an active company member.',
    ),
      'email_already_in_use' || 'credential_already_in_use' => AppText.t(
        'البريد مرتبط بحساب آخر. سجّل الدخول بالبريد أو Google أولًا.',
        'This email is already linked to another account. Sign in first.',
      ),
      'user_not_found' || 'wrong_password' || 'invalid_credential' =>
        AppText.t(
          'البريد أو كلمة المرور غير صحيحة.',
          'The email or password is incorrect.',
        ),
      'weak_password' => AppText.t(
        'اختر كلمة مرور أقوى من 6 أحرف.',
        'Choose a stronger password.',
      ),
      'network_request_failed' => AppText.t(
        'لا يوجد اتصال بالإنترنت.',
        'No internet connection.',
      ),
      'email_mismatch' => AppText.t(
        'بريد كلمة المرور يجب أن يطابق الحساب المسجل.',
        'The password email must match the signed-in account.',
      ),
      'too_many_requests' => AppText.t(
        'محاولات كثيرة. حاول لاحقًا.',
        'Too many attempts. Try again later.',
      ),
      // Unknown codes never leak raw English technical text to the UI; the
      // code itself stays on AuthFailure.code for debugging.
      _ => AppText.t(
        'تعذر إكمال العملية. حاول مرة أخرى.',
        'Unable to complete the operation. Try again.',
      ),
    };
  }
}
