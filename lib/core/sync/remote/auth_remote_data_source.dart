import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_dartio/google_sign_in_dartio.dart'
    show GoogleSignInDart;

import '../sync_codec.dart';
import '../../constants/app_strings.dart';
import 'firestore_data_source.dart';
import 'remote_data_source.dart';

/// Identity + organization profile operations on Firestore (plan §8.2, §8.3,
/// §8.5). All Firestore calls of the auth flows live here; the repository above
/// stays storage-agnostic.
class AuthRemoteDataSourceImpl implements AuthRemoteDataSource {
  AuthRemoteDataSourceImpl({
    required this.firestore,
    required this.google,
    this.auth,
  });

  final FirestoreDataSource firestore;
  final GoogleAuthDataSource google;
  final FirebaseAuth? auth;

  FirebaseAuth? get _auth => auth;

  @override
  bool get isConfigured => firestore.isConfigured && _auth != null;

  @override
  Future<RemoteUser?> currentUser() async {
    final user = _auth?.currentUser;
    if (user == null) return null;
    return RemoteUser(
      uid: user.uid,
      email: user.email ?? '',
      displayName: user.displayName,
      photoUrl: user.photoURL,
    );
  }

  /// §8.2: on Windows the flow opens the system browser and listens on a
  /// loopback port, so a **Desktop app** OAuth client id is mandatory.
  ///
  /// `google_sign_in_dartio` binds `127.0.0.1` on an ephemeral port and sends
  /// `http://127.0.0.1:<port>` as `redirect_uri` (`token_sign_in.dart:29-31,
  /// 49`). Google ignores the port when matching a loopback URI **only for
  /// Desktop app clients** (RFC 8252 §7.3); a Web client requires a byte-exact
  /// match, so a Web client id yields `redirect_uri_mismatch` on every launch
  /// no matter what is registered.
  static Future<void> ensureGoogleRegistered({String? clientId}) async {
    // Desktop (Windows MSIX/EXE, Linux, macOS): loopback flow needs a Desktop
    // OAuth client. Mobile uses native SDKs / google-services.json instead.
    if (Platform.isAndroid || Platform.isIOS) return;
    if (_googleRegistered) return;
    final id = (clientId ?? googleClientId).trim();
    if (id.isEmpty) {
      throw const GoogleSignInException(
        'GOOGLE_DESKTOP_CLIENT_ID is missing — create an OAuth 2.0 client of type '
        '"Desktop app" in the Google Cloud console (project materiallab-63405), '
        'add http://127.0.0.1 to its authorized redirect URIs, then pass its client '
        'id via --dart-define',
      );
    }
    await GoogleSignInDart.register(clientId: id);
    _googleRegistered = true;
  }

  static bool _googleRegistered = false;

  @override
  Future<void> signInWithGoogle() async {
    final auth = _auth;
    if (auth == null) {
      throw const GoogleSignInException('FirebaseAuth is not initialized');
    }
    await ensureGoogleRegistered();
    final result = await google.signIn(
      clientId: AuthRemoteDataSourceImpl.effectiveGoogleClientId,
    );
    if (!result.isValid) {
      throw const GoogleSignInException('Google sign-in returned no ID token');
    }
    final credential = GoogleAuthProvider.credential(idToken: result.idToken);
    try {
      await auth.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'invalid-credential') {
        throw GoogleSignInException(
          Platform.isAndroid || Platform.isIOS
              ? 'Firebase rejected the Google identity. Check that the Android '
                    'OAuth client and google-services.json belong to project '
                    'materiallab-63405 and that the registered SHA-1 matches '
                    'this device.'
              : 'The Google client id was rejected — make sure it is a Desktop '
                    'app client id registered in project materiallab-63405',
        );
      }
      rethrow;
    }
  }

  @override
  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final auth = _auth;
    if (auth == null) {
      throw const RemoteAuthException('The account service is not available.');
    }
    try {
      await auth.signInWithEmailAndPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      throw RemoteAuthException(_emailAuthMessage(e.code), code: e.code);
    }
  }

  @override
  Future<void> createPasswordAccount({
    required String email,
    required String password,
  }) async {
    final auth = _auth;
    if (auth == null) {
      throw const RemoteAuthException('The account service is not available.');
    }
    final normalized = email.trim().toLowerCase();
    final credential = EmailAuthProvider.credential(
      email: normalized,
      password: password,
    );
    try {
      final current = auth.currentUser;
      if (current != null) {
        if ((current.email ?? '').trim().toLowerCase() != normalized) {
          throw const RemoteAuthException(
            'The password email must match the signed-in account.',
            code: 'email_mismatch',
          );
        }
        await current.linkWithCredential(credential);
      } else {
        await auth.createUserWithEmailAndPassword(
          email: normalized,
          password: password,
        );
      }
    } on FirebaseAuthException catch (e) {
      throw RemoteAuthException(_emailAuthMessage(e.code), code: e.code);
    }
  }

  @override
  Future<void> updateUserDisplayName({
    required String uid,
    required String displayName,
  }) async {
    final auth = _auth;
    if (auth == null) {
      throw const RemoteAuthException('The account service is not available.');
    }
    final name = displayName.trim();
    if (name.isEmpty) {
      throw const RemoteAuthException(
        'The name cannot be empty.',
        code: 'invalid_name',
      );
    }
    try {
      // Self-service profile write: the rules allow the signed-in member to
      // change only `displayName`/`photoUrl`/`lastSeenAt`/`lastDeviceId` on
      // their own `users/{uid}` document. Adding `updatedAt`/`version` here
      // would break the `hasOnly(...)` allow-list, so the payload stays to the
      // single affected key.
      await firestore.userDoc(uid).set(<String, dynamic>{
        'displayName': name,
      }, SetOptions(merge: true));
      await auth.currentUser?.updateDisplayName(name);
    } on FirebaseException catch (e) {
      throw RemoteAuthException(_emailAuthMessage(e.code), code: e.code);
    }
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    final auth = _auth;
    if (auth == null) {
      throw const RemoteAuthException('The account service is not available.');
    }
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty || !normalized.contains('@')) {
      throw const RemoteAuthException(
        'Enter a valid email address.',
        code: 'invalid-email',
      );
    }
    try {
      await auth.sendPasswordResetEmail(email: normalized);
    } on FirebaseAuthException catch (e) {
      throw RemoteAuthException(_emailAuthMessage(e.code), code: e.code);
    }
  }

  static String _emailAuthMessage(String code) => switch (code) {
    'invalid-email' => 'The email address is not valid.',
    'user-not-found' => 'No account was found for this email.',
    'wrong-password' ||
    'invalid-credential' => 'The email or password is incorrect.',
    'email-already-in-use' =>
      'This email already has an account. Sign in with email or Google first.',
    'credential-already-in-use' =>
      'This email is already linked to another account.',
    'weak-password' => 'Choose a stronger password (at least 6 characters).',
    'too-many-requests' => 'Too many attempts. Try again later.',
    'network-request-failed' =>
      'No internet connection. Check the network and try again.',
    _ => 'Unable to complete the account operation.',
  };

  @override
  Future<void> signOut() async {
    await _auth?.signOut();
  }

  @override
  Future<UserProfile?> loadProfile(String uid) async {
    final data = await firestore.userDoc(uid).get().then((s) => s.data());
    return UserProfile.fromMap(data, uid, _auth?.currentUser?.email ?? '');
  }

  @override
  Future<Invite?> findInvite(
    String organizationId,
    String normalizedEmail,
  ) async {
    final snapshot = await firestore
        .inviteRef(organizationId, inviteKey(normalizedEmail))
        .get();
    return Invite.fromMap(organizationId, snapshot.data());
  }

  /// `inviteKey = b64url(lower(email))` (plan §8.3).
  static String inviteKey(String email) => base64Url
      .encode(utf8.encode(email.trim().toLowerCase()))
      .replaceAll('=', '');

  static const String _desktopClientIdDefine = String.fromEnvironment(
    'GOOGLE_DESKTOP_CLIENT_ID',
  );
  static const String _webClientIdDefine = String.fromEnvironment(
    'GOOGLE_WEB_CLIENT_ID',
  );

  /// Client id used by the Windows loopback flow. `GOOGLE_DESKTOP_CLIENT_ID` is
  /// the supported key; `GOOGLE_WEB_CLIENT_ID` is kept as a fallback so existing
  /// `--dart-define` invocations keep resolving (they will still fail in the
  /// browser with `redirect_uri_mismatch` if the value is a Web client id).
  static final String googleClientId = _desktopClientIdDefine.isNotEmpty
      ? _desktopClientIdDefine
      : _webClientIdDefine;

  /// Android client id, passed via `--dart-define`. It is **not** handed to
  /// `GoogleSignIn(clientId:)`: on Android that parameter is ignored and Play
  /// Services resolves the id from `google-services.json`. It exists so the app
  /// can tell "configured for this platform" from "configured for some other
  /// platform" and show the right instructions.
  static const String googleAndroidClientId = String.fromEnvironment(
    'GOOGLE_ANDROID_CLIENT_ID',
  );

  /// The client id to hand to `GoogleSignIn(clientId:)` on the current platform,
  /// or `''` when the platform resolves its own.
  ///
  /// Passing a Desktop id on Android used to look like it worked — the
  /// parameter is simply dropped — so a misconfigured phone build failed much
  /// later, at the token exchange, with an opaque error.
  static String get effectiveGoogleClientId {
    if (Platform.isAndroid || Platform.isIOS) return '';
    return googleClientId;
  }

  /// Deterministic organization id: `org_` + base32(sha256(uid)[0..8])
  /// (plan §8.5). Retrying the creation can never produce a second organization
  /// and the rules can derive nothing from it — the founder is authorized by
  /// `organizations/{orgId}.ownerUid` instead.
  static String organizationIdFor(String uid) {
    final digest = sha256.convert(utf8.encode(uid)).bytes;
    return 'org_${_base32(digest.sublist(0, 5))}';
  }

  /// 5 bytes = 40 bits = exactly 8 base32 characters (RFC 4648, no padding).
  static String _base32(List<int> bytes) {
    final buffer = StringBuffer();
    var bits = 0;
    var value = 0;
    for (final byte in bytes) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        buffer.write(_base32Alphabet[(value >> (bits - 5)) & 0x1f]);
        bits -= 5;
      }
    }
    if (bits > 0) buffer.write(_base32Alphabet[(value << (5 - bits)) & 0x1f]);
    return buffer.toString();
  }

  static const String _base32Alphabet = 'abcdefghijklmnopqrstuvwxyz234567';

  @override
  Future<OrganizationProfile> loadOrganization(String organizationId) async {
    final data = await firestore
        .organizationRef(organizationId)
        .get()
        .then((s) => s.data());
    return OrganizationProfile.fromMap(organizationId, data)!;
  }

  @override
  Future<String> createOrganization({
    required String uid,
    required String email,
    required String displayName,
    required String organizationName,
  }) async {
    final auth = _auth;
    if (auth == null) {
      throw const GoogleSignInException('FirebaseAuth is not initialized');
    }
    // Deterministic id: `org_` + base32(sha256(uid)[0..8]) - retrying the
    // creation can never produce a second organization (plan 8.5).
    final orgId = organizationIdFor(uid);
    final memberId = memberIdFor(email);
    // Single-company policy (§2): a bound account (invited/pending/active)
    // cannot create a second company. Sign-out alone never unblocks this.
    final existingProfile = await firestore
        .userDoc(uid)
        .get()
        .then((s) => s.data());
    final boundOrg = '${existingProfile?['organizationId'] ?? ''}';
    final boundStatus = '${existingProfile?['status'] ?? ''}';
    if (boundOrg.isNotEmpty &&
        (boundStatus == RemoteMemberStatus.invited ||
            boundStatus == RemoteMemberStatus.pendingActivation ||
            boundStatus == RemoteMemberStatus.active)) {
      throw RemoteAuthException(
        AppText.t(
          'هذا الحساب مرتبط بشركة حالية. غادر الشركة الحالية أولًا لإنشاء شركة جديدة.',
          'This account is already linked to a company. Leave the current company first to create a new one.',
        ),
        code: 'member_exists',
      );
    }
    final orgRef = firestore.organizationRef(orgId);
    final existing = await orgRef.get();
    final ownedByCaller =
        existing.exists && existing.data()?['ownerUid'] == uid;
    if (existing.exists && !ownedByCaller) {
      throw RemoteAuthException(
        AppText.t('الشركة موجودة بالفعل.', 'Organization already exists.'),
        code: 'organization_exists',
      );
    }

    if (!existing.exists) {
      // Step 1 - the organization itself, in its own commit so the rules can
      // authorize the founder profile with `get(org).data.ownerUid == uid`
      // instead of trusting a self-asserted `status: 'active'`.
      // New companies start as `trial` with a one-time 30-day window
      // (trialStartedAt/trialEndsAt); expiry flips the org to `suspended`
      // via the server cron, and manual activation by support is permanent
      // (manuallyActivated=true is never auto-suspended again).
      final now = DateTime.now().toUtc();
      final trialEndsAt = now.add(const Duration(days: 30));
      final orgBatch = firestore.newBatch();
      orgBatch.set(orgRef, <String, dynamic>{
        'name': organizationName,
        'ownerUid': uid,
        'status': 'trial',
        'schemaVersion': 2,
        'trialStartedAt': Timestamp.fromDate(now),
        'trialEndsAt': Timestamp.fromDate(trialEndsAt),
        'trialConsumed': false,
        'manuallyActivated': false,
        'createdAt': firestore.serverTimestamp(),
        'createdBy': uid,
        'updatedBy': uid,
        'updatedAt': firestore.serverTimestamp(),
        'version': 1,
      });
      orgBatch.set(firestore.organizationMetaRef(orgId), <String, dynamic>{
        'lastWriteAt': firestore.serverTimestamp(),
        'lastWriteBy': uid,
        'lastEntity': 'org',
        'version': 1,
      });
      await orgBatch.commit();
    }

    // Step 2 - the founder is the first (active) member of the organization.
    // A new company is a trial: the founder is `trial_owner` with limited
    // permissions (plan §4). Promotion to `admin` happens on approval.
    final memberBatch = firestore.newBatch();
    memberBatch.set(firestore.memberRef(orgId, memberId), <String, dynamic>{
      'uid': uid,
      'email': email,
      'role': 'trial_owner',
      'status': 'active',
      'displayName': displayName,
      'activatedAt': firestore.serverTimestamp(),
      'version': 1,
      'updatedBy': uid,
      'updatedAt': firestore.serverTimestamp(),
      'createdAt': firestore.serverTimestamp(),
    });
    memberBatch.set(firestore.userDoc(uid), <String, dynamic>{
      'email': email,
      'organizationId': orgId,
      'role': 'trial_owner',
      'status': 'active',
      'memberId': memberId,
      'displayName': displayName,
      'version': 1,
      'updatedBy': uid,
      'updatedAt': firestore.serverTimestamp(),
      'createdAt': firestore.serverTimestamp(),
    });
    await memberBatch.commit();
    return orgId;
  }

  @override
  Future<void> updateOrganization(
    String organizationId,
    Map<String, dynamic> data,
  ) async {
    await firestore.organizationRef(organizationId).update({
      ...data,
      'updatedBy': _auth?.currentUser?.uid,
      'updatedAt': firestore.serverTimestamp(),
    });
  }

  @override
  Future<void> acceptInvite({
    required String organizationId,
    required Invite invite,
    required String uid,
    required String email,
  }) async {
    final batch = firestore.newBatch();
    batch.set(firestore.userDoc(uid), <String, dynamic>{
      'email': email,
      'organizationId': organizationId,
      'role': invite.role,
      // Claimed but waiting for manager activation (plan §5): the member
      // signed in (password or Google) and is now `pending_activation`.
      'status': RemoteMemberStatus.pendingActivation,
      'memberId': invite.memberId,
      'inviteKey': inviteKey(email),
      'version': 1,
      'updatedBy': uid,
      'updatedAt': firestore.serverTimestamp(),
      'createdAt': firestore.serverTimestamp(),
    });
    // Link the invite to the account that claimed it.
    batch.set(
      firestore.inviteRef(organizationId, inviteKey(email)),
      <String, dynamic>{
        'claimedBy': uid,
        'claimedAt': firestore.serverTimestamp(),
        'updatedAt': firestore.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    // Bind the member document to the claiming uid. Until the admin activates
    // the account the member stays `pending_activation`, so it can never write.
    // The version has to move exactly one step (the same envelope invariant the
    // rules enforce on every other write), so it is read from the member
    // document the admin created instead of being assumed to be 1.
    final memberSnapshot = await firestore
        .memberRef(organizationId, invite.memberId)
        .get();
    final memberVersion =
        ((memberSnapshot.data()?['version'] as num?)?.toInt() ?? 0) + 1;
    batch.set(
      firestore.memberRef(organizationId, invite.memberId),
      <String, dynamic>{
        'uid': uid,
        'email': email,
        'role': invite.role,
        'status': RemoteMemberStatus.pendingActivation,
        'version': memberVersion,
        'updatedBy': uid,
        'updatedAt': firestore.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    await batch.commit();
  }

  @override
  Future<List<RemoteDocument>> listMembers(String organizationId) async {
    try {
      final snapshot = await firestore
          .membersCollection(organizationId)
          .orderBy('email')
          .limit(500)
          .get();
      return snapshot.docs.map((doc) {
        // Raw member docs carry Timestamp (activatedAt/invitedAt/...);
        // sanitize so downstream mirrors/encoders never see Timestamp.
        final raw = Map<String, dynamic>.from(doc.data());
        Object? versionRaw;
        try {
          versionRaw = doc.get('version');
        } catch (_) {
          versionRaw = raw['version'];
        }
        Object? updatedRaw;
        try {
          updatedRaw = doc.get('updatedAt');
        } catch (_) {
          updatedRaw = raw['updatedAt'];
        }
        return RemoteDocument(
          id: doc.id,
          data: SyncCodec.sanitizeMap(raw),
          version: (versionRaw as num?)?.toInt() ?? 1,
          updatedAt: _timestampOf(updatedRaw),
          exists: doc.exists,
        );
      }).toList();
    } on FirebaseException catch (e) {
      // Permission errors are real errors (wrong org, revoked member): the
      // screen must show them instead of a misleading "no members yet".
      // Transport errors (offline) fall through to [] so the cached view stays.
      if (e.code == 'permission-denied' || e.code == 'unauthenticated') {
        throw RemoteAuthException(
          AppText.t(
            'تم الرفض من الخادم — تحقق من صلاحياتك وحدّث القائمة.',
            'Rejected by the server — check your permissions and refresh.',
          ),
          code: 'not_allowed',
        );
      }
      return const [];
    } on Object {
      return const [];
    }
  }

  @override
  Future<String> createInvite({
    required String organizationId,
    required String email,
    required String role,
    required String invitedBy,
  }) async {
    final normalized = email.trim().toLowerCase();
    if (normalized.isEmpty ||
        !normalized.contains('@') ||
        normalized.contains(' ') ||
        normalized.split('@').length != 2 ||
        !(normalized.split('@')[1].contains('.'))) {
      throw const RemoteAuthException(
        'Enter a valid email address.',
        code: 'invalid_email',
      );
    }
    const validRoles = {
      'admin',
      'quality_manager',
      'lab',
      'viewer',
      'trial_owner',
    };
    if (!validRoles.contains(role)) {
      throw const RemoteAuthException('Invalid role.', code: 'invalid_role');
    }
    // `member_<localUserId>` — generated by the admin device (plan §8.3) and
    // stable across retries because it is derived from the organization and the
    // normalized e-mail.
    final memberId =
        'member_${AuthRemoteDataSourceImpl.memberIdFor(normalized)}';
    final existing = await firestore.memberRef(organizationId, memberId).get();
    final existingData = existing.data();
    final existingStatus = '${existingData?['status'] ?? ''}';
    if (existingData != null && existingStatus == RemoteMemberStatus.active) {
      throw const RemoteAuthException(
        'This email is already an active company member.',
        code: 'member_exists',
      );
    }
    final existingInvite = await firestore
        .inviteRef(organizationId, inviteKey(normalized))
        .get();
    final memberVersion =
        ((existingData?['version'] as num?)?.toInt() ?? 0) + 1;
    final inviteVersion =
        ((existingInvite.data()?['version'] as num?)?.toInt() ?? 0) + 1;
    final now = firestore.serverTimestamp();
    final batch = firestore.newBatch();
    // Resend (existing doc) must only bump `version`/`updated*` (+ role/status
    // refresh): rewriting `invitedBy/invitedAt` trips the rules allow-list and
    // churns audit metadata. First invite carries the full payload.
    final isResend = existingData != null;
    final memberPayload = <String, dynamic>{
      'email': normalized,
      'role': role,
      'status': RemoteMemberStatus.invited,
      if (!isResend) 'displayName': '',
      if (!isResend) 'invitedBy': invitedBy,
      if (!isResend) 'invitedByName': _auth?.currentUser?.displayName ?? '',
      if (!isResend) 'invitedAt': now,
      'version': memberVersion,
      'updatedBy': invitedBy,
      'updatedAt': now,
      if (existingData == null) 'uid': '',
      if (existingData == null) 'createdAt': now,
    };
    batch.set(
      firestore.memberRef(organizationId, memberId),
      memberPayload,
      SetOptions(merge: true),
    );
    final isInviteResend = existingInvite.data() != null;
    batch.set(
      firestore.inviteRef(organizationId, inviteKey(normalized)),
      <String, dynamic>{
        'email': normalized,
        'role': role,
        'memberId': memberId,
        'status': RemoteMemberStatus.invited,
        if (!isInviteResend) 'invitedBy': invitedBy,
        if (!isInviteResend)
          'invitedByName': _auth?.currentUser?.displayName ?? '',
        if (existingInvite.data() == null) 'createdAt': now,
        'updatedAt': now,
        'version': inviteVersion,
      },
      SetOptions(merge: true),
    );
    await batch.commit();
    return memberId;
  }

  @override
  Future<void> updateMember({
    required String organizationId,
    required String memberId,
    required Map<String, dynamic> data,
  }) async {
    // Perf: member read is needed for uid/version; user read is deferred until
    // uid is known, but the version bump below reuses the same snapshot shape
    // so a future parallel prefetch can land here without semantic change.
    final member = await firestore.memberRef(organizationId, memberId).get();
    final uid = '${member.data()?['uid'] ?? ''}';
    // Prefetch the user doc concurrently with payload building where possible.
    // When uid is empty this stays a no-op (no extra RTT).
    final userFuture = uid.isNotEmpty ? firestore.userDoc(uid).get() : null;
    final now = firestore.serverTimestamp();
    final activating = data['status'] == RemoteMemberStatus.active;
    final payload = <String, dynamic>{
      ...data,
      'updatedBy': _auth?.currentUser?.uid,
      'updatedAt': now,
      'version': ((member.data()?['version'] as num?)?.toInt() ?? 0) + 1,
      // Activation audit (plan §6): who activated and when, in one batch.
      if (activating) 'activatedBy': _auth?.currentUser?.uid,
    };
    if (data['activatedAt'] == null && data.containsKey('activatedAt')) {
      payload['activatedAt'] = now;
    }
    final batch = firestore.newBatch();
    // merge:true - a full set would drop email/uid/invitedAt from the member doc
    // and the rules see removed fields as ffectedKeys.
    batch.set(
      firestore.memberRef(organizationId, memberId),
      payload,
      SetOptions(merge: true),
    );
    if (uid.isNotEmpty) {
      // `users/{uid}` is the authorization source: it must never drift from the
      // member document. Activation audit (plan §6) lands in the same batch:
      // status + activatedAt + activatedBy + version bump together.
      // Perf: user snapshot was prefetched concurrently above (1 RTT saved).
      final userDoc = firestore.userDoc(uid);
      final user = await userFuture!;
      final userFields = _userFieldsFrom(data);
      if (activating) {
        userFields['activatedAt'] = now;
        userFields['activatedBy'] = _auth?.currentUser?.uid;
      }
      // merge:true - the user document is the authorization source; a full
      // overwrite would strip email/organizationId/memberId and revoke access.
      batch.set(userDoc, <String, dynamic>{
        ...userFields,
        'updatedBy': _auth?.currentUser?.uid,
        'updatedAt': now,
        'version': ((user.data()?['version'] as num?)?.toInt() ?? 0) + 1,
      }, SetOptions(merge: true));
    }
    await batch.commit();
  }

  @override
  Future<void> deleteMember({
    required String organizationId,
    required String memberId,
  }) async {
    final member = await firestore.memberRef(organizationId, memberId).get();
    final data = member.data() ?? const <String, dynamic>{};
    final now = firestore.serverTimestamp();
    final batch = firestore.newBatch();
    batch.set(firestore.memberRef(organizationId, memberId), <String, dynamic>{
      'status': RemoteMemberStatus.disabled,
      'deletedAt': now,
      'updatedBy': _auth?.currentUser?.uid,
      'updatedAt': now,
      'version': ((data['version'] as num?)?.toInt() ?? 0) + 1,
    }, SetOptions(merge: true));
    final uid = '${data['uid'] ?? ''}';
    if (uid.isNotEmpty) {
      final userDoc = firestore.userDoc(uid);
      final user = await userDoc.get();
      batch.set(userDoc, <String, dynamic>{
        'status': RemoteMemberStatus.disabled,
        'organizationId': FieldValue.delete(),
        'memberId': FieldValue.delete(),
        'updatedBy': _auth?.currentUser?.uid,
        'updatedAt': now,
        'version': ((user.data()?['version'] as num?)?.toInt() ?? 0) + 1,
      }, SetOptions(merge: true));
    }
    await batch.commit();
  }

  @override
  Future<void> leaveOrganization({
    required String organizationId,
    required String memberId,
    required String uid,
  }) async {
    final now = firestore.serverTimestamp();
    final batch = firestore.newBatch();

    final memberDoc = firestore.memberRef(organizationId, memberId);
    final userDoc = firestore.userDoc(uid);
    // Perf: uid is a parameter here (unlike update/delete where it must be
    // read from the member doc first), so both snapshots load concurrently —
    // 1 RTT instead of 2 serial RTTs. Same snapshots, same batch semantics.
    final results = await Future.wait([memberDoc.get(), userDoc.get()]);
    final member = results[0];
    final user = results[1];
    final memberData = member.data() ?? const <String, dynamic>{};
    batch.set(memberDoc, <String, dynamic>{
      'status': RemoteMemberStatus.disabled,
      'deletedAt': now,
      'updatedBy': uid,
      'updatedAt': now,
      'version': ((memberData['version'] as num?)?.toInt() ?? 0) + 1,
    }, SetOptions(merge: true));

    // The binding is dropped from the profile rather than pointed at another
    // organization, which is what the rules enforce on the self-leave branch.
    // `memberId` is dropped too so the account returns to `no_company` and may
    // create a trial company or join with a new invite (plan §3). The member
    // row itself is kept as `disabled` audit history, never hard-deleted.
    batch.set(userDoc, <String, dynamic>{
      'status': RemoteMemberStatus.disabled,
      'organizationId': FieldValue.delete(),
      'memberId': FieldValue.delete(),
      'updatedBy': uid,
      'updatedAt': now,
      'version': ((user.data()?['version'] as num?)?.toInt() ?? 0) + 1,
    }, SetOptions(merge: true));

    await batch.commit();
  }

  @override
  Future<void> writeAudit({
    required String organizationId,
    required String action,
    required String entityType,
    required String entityId,
    Map<String, dynamic>? details,
  }) async {
    final uid = _auth?.currentUser?.uid ?? '';
    final now = firestore.serverTimestamp();
    // Sortable, collision-free id: the member id is stable while the
    // timestamp prefix keeps the audit log chronological.
    final logId =
        'log_${DateTime.now().toUtc().microsecondsSinceEpoch}_${_deviceSuffix(uid)}';
    await firestore.auditLogRef(organizationId, logId).set(<String, dynamic>{
      'userId': uid,
      'userName': _auth?.currentUser?.displayName ?? '',
      'organizationId': organizationId,
      'action': action,
      'entityType': entityType,
      'entityId': entityId,
      'detailsJson': details == null ? null : SyncCodec.encode(details),
      'deviceId': _deviceId,
      'occurredAt': now,
      'version': 1,
    });
  }

  /// `member_<localUserId>` suffix: the first 10 hex characters of the
  /// normalized e-mail. Deterministic so a retried invite never duplicates the
  /// member document.
  static String memberIdFor(String normalizedEmail) =>
      sha1.convert(utf8.encode(normalizedEmail)).toString().substring(0, 10);

  /// Firestore document ids may not contain `/`, so the uid is shortened.
  static String _deviceSuffix(String uid) =>
      uid.isEmpty ? 'anon' : uid.replaceAll('/', '_');

  static Map<String, dynamic> _userFieldsFrom(Map<String, dynamic> memberData) {
    final out = <String, dynamic>{};
    for (final key in const ['role', 'status', 'activatedBy']) {
      final value = memberData[key];
      if (value != null) out[key] = value;
    }
    return out;
  }

  static String? _timestampOf(Object? value) => switch (value) {
    Timestamp ts => ts.toDate().toIso8601String(),
    null => null,
    _ => '$value',
  };

  static String? _deviceId;
}

/// `status` values duplicated as plain strings so the remote layer stays free
/// of Flutter/Dart UI imports (kept identical to `MemberStatus`).
abstract final class RemoteMemberStatus {
  static const String invited = 'invited';
  static const String pendingActivation = 'pending_activation';
  static const String active = 'active';
  static const String disabled = 'disabled';
}

class GoogleSignInException implements Exception {
  const GoogleSignInException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Raised by the remote layer when an identity/organization operation is
/// refused. The organization repository translates it into an
/// `OrganizationFailure` so the UI never sees a Firestore error.
class RemoteAuthException implements Exception {
  const RemoteAuthException(this.message, {this.code = 'remote_error'});

  final String message;
  final String code;

  @override
  String toString() => 'RemoteAuthException($code): $message';
}

/// `google_sign_in` adapter. Isolated so repository tests can fake it and the
/// Windows-only `google_sign_in_dartio` import stays in one file.
class GoogleAuthDataSourceImpl implements GoogleAuthDataSource {
  GoogleAuthDataSourceImpl({GoogleSignIn? signIn})
    : _signIn =
          signIn ??
          // Empty on Android/iOS on purpose - see [effectiveGoogleClientId].
          GoogleSignIn(
            clientId: AuthRemoteDataSourceImpl.effectiveGoogleClientId,
          );

  final GoogleSignIn _signIn;

  /// True when sign-in can plausibly work on **this** platform.
  ///
  /// This used to check a Desktop client id unconditionally, which reported
  /// "configured" on a phone and then failed later at the token exchange.
  @override
  bool get isConfigured {
    if (Platform.isAndroid || Platform.isIOS) {
      return AuthRemoteDataSourceImpl.googleAndroidClientId.isNotEmpty;
    }
    return AuthRemoteDataSourceImpl.googleClientId.isNotEmpty;
  }

  @override
  Future<GoogleAuthResult> signIn({required String clientId}) async {
    await AuthRemoteDataSourceImpl.ensureGoogleRegistered(clientId: clientId);
    final account = await _signIn.signIn();
    if (account == null) {
      throw const GoogleSignInException('Google sign-in was cancelled');
    }
    final auth = await account.authentication;
    return GoogleAuthResult(
      idToken: auth.idToken,
      email: account.email,
      displayName: account.displayName,
      photoUrl: account.photoUrl,
    );
  }

  @override
  Future<GoogleAuthResult?> signInSilently({required String clientId}) async {
    await AuthRemoteDataSourceImpl.ensureGoogleRegistered(clientId: clientId);
    final account = await _signIn.signInSilently();
    if (account == null) return null;
    final auth = await account.authentication;
    return GoogleAuthResult(
      idToken: auth.idToken,
      email: account.email,
      displayName: account.displayName,
      photoUrl: account.photoUrl,
    );
  }
}
