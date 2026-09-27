import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_dartio/google_sign_in_dartio.dart' show GoogleSignInDart;

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
    if (!Platform.isWindows) return;
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
    final result = await google.signIn(clientId: googleClientId);
    if (!result.isValid) {
      throw const GoogleSignInException('Google sign-in returned no ID token');
    }
    final credential = GoogleAuthProvider.credential(idToken: result.idToken);
    try {
      await auth.signInWithCredential(credential);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'invalid-credential') {
        throw const GoogleSignInException(
          'The Google client id was rejected — make sure it is a Desktop app client '
          'id registered in project materiallab-63405',
        );
      }
      rethrow;
    }
  }

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
  Future<Invite?> findInvite(String organizationId, String normalizedEmail) async {
    final snapshot = await firestore
        .inviteRef(organizationId, inviteKey(normalizedEmail))
        .get();
    return Invite.fromMap(organizationId, snapshot.data());
  }

  /// `inviteKey = b64url(lower(email))` (plan §8.3).
  static String inviteKey(String email) =>
      base64Url.encode(utf8.encode(email.trim().toLowerCase())).replaceAll('=', '');

  static const String _desktopClientIdDefine =
      String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID');
  static const String _webClientIdDefine =
      String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

  /// Client id used by the Windows loopback flow. `GOOGLE_DESKTOP_CLIENT_ID` is
  /// the supported key; `GOOGLE_WEB_CLIENT_ID` is kept as a fallback so existing
  /// `--dart-define` invocations keep resolving (they will still fail in the
  /// browser with `redirect_uri_mismatch` if the value is a Web client id).
  static final String googleClientId = _desktopClientIdDefine.isNotEmpty
      ? _desktopClientIdDefine
      : _webClientIdDefine;

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
    final data = await firestore.organizationRef(organizationId).get().then((s) => s.data());
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
    final orgRef = firestore.organizationRef(orgId);
    final existing = await orgRef.get();
    final ownedByCaller = existing.exists && existing.data()?['ownerUid'] == uid;
    if (existing.exists && !ownedByCaller) {
      throw const RemoteAuthException(
        'organization already exists',
        code: 'organization_exists',
      );
    }

    if (!existing.exists) {
      // Step 1 - the organization itself, in its own commit so the rules can
      // authorize the founder profile with `get(org).data.ownerUid == uid`
      // instead of trusting a self-asserted `status: 'active'`.
      final orgBatch = firestore.newBatch();
      orgBatch.set(orgRef, <String, dynamic>{
        'name': organizationName,
        'ownerUid': uid,
        'status': 'active',
        'schemaVersion': 2,
        'createdAt': firestore.serverTimestamp(),
        'createdBy': uid,
        'updatedBy': uid,
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
    final memberBatch = firestore.newBatch();
    memberBatch.set(firestore.memberRef(orgId, memberId), <String, dynamic>{
      'uid': uid,
      'email': email,
      'role': 'admin',
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
      'role': 'admin',
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
  Future<void> updateOrganization(String organizationId, Map<String, dynamic> data) async {
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
      'status': RemoteMemberStatus.invited,
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
    // the account the member stays `invited`, so it can never write.
    // The version has to move exactly one step (the same envelope invariant the
    // rules enforce on every other write), so it is read from the member
    // document the admin created instead of being assumed to be 1.
    final memberSnapshot =
        await firestore.memberRef(organizationId, invite.memberId).get();
    final memberVersion =
        ((memberSnapshot.data()?['version'] as num?)?.toInt() ?? 0) + 1;
    batch.set(
      firestore.memberRef(organizationId, invite.memberId),
      <String, dynamic>{
        'uid': uid,
        'email': email,
        'role': invite.role,
        'status': RemoteMemberStatus.invited,
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
          .get();
      return snapshot.docs
          .map((doc) => RemoteDocument(
                id: doc.id,
                data: Map<String, dynamic>.from(doc.data()),
                version: (doc.get('version') as num?)?.toInt() ?? 1,
                updatedAt: _timestampOf(doc.get('updatedAt')),
                exists: doc.exists,
              ))
          .toList();
    } on Object {
      // A permission error must not break the members screen; the local
      // `users` mirror stays authoritative for what this device can see.
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
    // `member_<localUserId>` — generated by the admin device (plan §8.3) and
    // stable across retries because it is derived from the organization and the
    // normalized e-mail.
    final memberId = 'member_${AuthRemoteDataSourceImpl.memberIdFor(normalized)}';
    final now = firestore.serverTimestamp();
    final batch = firestore.newBatch();
    batch.set(firestore.memberRef(organizationId, memberId), <String, dynamic>{
      'uid': '',
      'email': normalized,
      'role': role,
      'status': RemoteMemberStatus.invited,
      'displayName': '',
      'invitedBy': invitedBy,
      'invitedByName': _auth?.currentUser?.displayName ?? '',
      'invitedAt': now,
      'version': 1,
      'updatedBy': invitedBy,
      'updatedAt': now,
      'createdAt': now,
    });
    batch.set(firestore.inviteRef(organizationId, inviteKey(normalized)), <String, dynamic>{
      'email': normalized,
      'role': role,
      'memberId': memberId,
      'status': RemoteMemberStatus.invited,
      'invitedBy': invitedBy,
      'invitedByName': _auth?.currentUser?.displayName ?? '',
      'createdAt': now,
      'updatedAt': now,
      'version': 1,
    });
    await batch.commit();
    return memberId;
  }

  @override
  Future<void> updateMember({
    required String organizationId,
    required String memberId,
    required Map<String, dynamic> data,
  }) async {
    final member = await firestore.memberRef(organizationId, memberId).get();
    final uid = '${member.data()?['uid'] ?? ''}';
    final now = firestore.serverTimestamp();
    final payload = <String, dynamic>{
      ...data,
      'updatedBy': _auth?.currentUser?.uid,
      'updatedAt': now,
      'version': ((member.data()?['version'] as num?)?.toInt() ?? 0) + 1,
    };
    if (data['activatedAt'] == null && data.containsKey('activatedAt')) {
      payload['activatedAt'] = now;
    }
    final batch = firestore.newBatch();
    // merge:true - a full set would drop email/uid/invitedAt from the member doc
    // and the rules see removed fields as ffectedKeys.
    batch.set(firestore.memberRef(organizationId, memberId), payload, SetOptions(merge: true));
    if (uid.isNotEmpty) {
      // `users/{uid}` is the authorization source: it must never drift from the
      // member document.
      final userDoc = firestore.userDoc(uid);
      final user = await userDoc.get();
      // merge:true - the user document is the authorization source; a full
      // overwrite would strip email/organizationId/memberId and revoke access.
      batch.set(userDoc, <String, dynamic>{
        ..._userFieldsFrom(data),
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
    final member = await memberDoc.get();
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
    final userDoc = firestore.userDoc(uid);
    final user = await userDoc.get();
    batch.set(userDoc, <String, dynamic>{
      'status': RemoteMemberStatus.disabled,
      'organizationId': FieldValue.delete(),
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
    final logId = 'log_${DateTime.now().toUtc().microsecondsSinceEpoch}_${_deviceSuffix(uid)}';
    await firestore.auditLogRef(organizationId, logId).set(<String, dynamic>{
      'userId': uid,
      'userName': _auth?.currentUser?.displayName ?? '',
      'organizationId': organizationId,
      'action': action,
      'entityType': entityType,
      'entityId': entityId,
      'detailsJson': details == null ? null : jsonEncode(details),
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
    for (final key in const ['role', 'status']) {
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
      : _signIn = signIn ??
            GoogleSignIn(clientId: AuthRemoteDataSourceImpl.googleClientId);

  final GoogleSignIn _signIn;

  @override
  bool get isConfigured => AuthRemoteDataSourceImpl.googleClientId.isNotEmpty;

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
