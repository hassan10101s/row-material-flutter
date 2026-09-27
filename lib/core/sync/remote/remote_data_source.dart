/// **The Django seam** (plan §5, P5): every remote call the app makes goes
/// through these interfaces. Swapping Firestore for Django/PostgreSQL means
/// registering different implementations in `service_locator.dart` — no
/// repository, cubit or widget changes.
///
/// Firestore implementation: `lib/core/sync/remote/firestore_data_source.dart`.
/// Test implementation: `lib/core/sync/remote/in_memory_data_source.dart`.
library;

/// A remote document plus the bookkeeping the sync engine needs.
class RemoteDocument {
  const RemoteDocument({
    required this.id,
    required this.data,
    required this.version,
    this.updatedAt,
    this.exists = true,
  });

  final String id;
  final Map<String, dynamic> data;

  /// `version` field of the document (optimistic concurrency).
  final int version;

  final String? updatedAt;

  /// False when the document is missing (deleted upstream).
  final bool exists;

  static const RemoteDocument missing = RemoteDocument(id: '', data: {}, version: 0, exists: false);
}

/// Result of a push: either a new version, or a classified failure.
class PushResult {
  const PushResult.success(this.version, {this.payload})
      : kind = PushResultKind.success,
        error = null,
        remote = null;
  const PushResult.rejected(this.error, {this.remote, this.kind = PushResultKind.permissionDenied})
      : version = 0,
        payload = null;
  const PushResult.retryable(this.error)
      : kind = PushResultKind.retryable,
        version = 0,
        payload = null,
        remote = null;
  const PushResult.oversized(this.error)
      : kind = PushResultKind.payloadTooLarge,
        version = 0,
        payload = null,
        remote = null;

  final PushResultKind kind;
  final int version;
  final String? error;
  final Map<String, dynamic>? remote;
  final String? payload;

  bool get isSuccess => kind == PushResultKind.success;
}

enum PushResultKind { success, permissionDenied, retryable, payloadTooLarge }

/// A page of documents ordered by (`updatedAt`, documentId).
class RemotePage {
  const RemotePage(this.documents, {this.hasMore = false});

  final List<RemoteDocument> documents;
  final bool hasMore;
}

/// Everything remote: data + identity + organizations.
///
/// Register with GetIt as a **factory** so a Django implementation can be
/// swapped in later (plan §12.2).
abstract interface class RemoteDataSource {
  bool get isConfigured;
  bool get isSignedIn;

  /// True when a valid ID token is available for privileged operations.
  Future<bool> isFresh();

  /// Raw push of a document inside `organizations/{organizationId}/{collection}`.
  Future<PushResult> setDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
    required Map<String, dynamic> data,
    required int baseVersion,
  });

  /// Append-only write (audit logs, immutable QC rows).
  Future<PushResult> appendDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
    required Map<String, dynamic> data,
  });

  Future<RemoteDocument> getDocument({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
  });

  /// Incremental page for `pull_worker` (plan §9.3).
  Future<RemotePage> listSince({
    required String organizationId,
    required SyncCollection collection,
    String startAtTs,
    String startAtId,
    int limit = 300,
  });

  Future<void> deleteTombstone({
    required String organizationId,
    required SyncCollection collection,
    required String documentId,
  });

  /// Heartbeat of `organizations/{orgId}/meta` — cheap "did anything change"
  /// probe that replaces full pull cycles.
  Future<RemoteDocument> readHeartbeat(String organizationId);

  /// Registry of devices (`organizations/{orgId}/devices`).
  Future<void> registerDevice({
    required String organizationId,
    required String deviceId,
    required Map<String, dynamic> data,
  });

  Future<void> unregisterDevice({
    required String organizationId,
    required String deviceId,
  });

  Future<List<RemoteDocument>> listDevices(String organizationId);
}

/// Collections used by the sync engine. Kept as an enum so a Django backend
/// can map it to its own table names in one `switch`.
enum SyncCollection {
  samples('samples'),
  qualityChecks('qualityChecks'),
  labResults('labResults'),
  labConfig('labConfig'),
  members('members'),
  invites('invites'),
  auditLogs('auditLogs'),
  devices('devices'),
  meta('meta');

  const SyncCollection(this.path);

  final String path;
}

/// Identity + organization profile operations (plan §8.2/§8.3/§8.5).
abstract interface class AuthRemoteDataSource {
  bool get isConfigured;

  Future<RemoteUser?> currentUser();

  Future<void> signInWithGoogle();

  Future<void> signOut();

  /// `users/{uid}` — the binding between the Firebase account and an
  /// organization/role. Null ⇒ no profile ⇒ create-organization flow.
  Future<UserProfile?> loadProfile(String uid);

  /// `organizations/{orgId}/invites/{b64url(lower(email))}`.
  Future<Invite?> findInvite(String organizationId, String normalizedEmail);

  /// §8.5 step 2-3: deterministic `orgId` (derived from the uid) + batch write.
  Future<String> createOrganization({
    required String uid,
    required String email,
    required String displayName,
    required String organizationName,
  });

  Future<OrganizationProfile?> loadOrganization(String organizationId);

  Future<void> updateOrganization(String organizationId, Map<String, dynamic> data);

  /// Claims an invite: writes `users/{uid}` from the invite content.
  Future<void> acceptInvite({
    required String organizationId,
    required Invite invite,
    required String uid,
    required String email,
  });

  // ── Members / invites (plan §8.3, P3.1) ───────────────────────────────

  /// `organizations/{orgId}/members` — the roster mirrored into `users`.
  Future<List<RemoteDocument>> listMembers(String organizationId);

  /// Batch write `{members/memberId, invites/inviteKey}` and returns the new
  /// `member_<localUserId>` id the admin device generated.
  Future<String> createInvite({
    required String organizationId,
    required String email,
    required String role,
    required String invitedBy,
  });

  /// Updates `members/{memberId}`; when the member has a `uid`, the same change
  /// is applied to `users/{uid}` in the same batch (plan §8.3 "Activate").
  Future<void> updateMember({
    required String organizationId,
    required String memberId,
    required Map<String, dynamic> data,
  });

  /// Writes a tombstone instead of deleting (the deletion must replicate and be
  /// auditable).
  Future<void> deleteMember({
    required String organizationId,
    required String memberId,
  });

  /// Self-service departure: the signed-in member leaves the organization on
  /// their own, with no `users.disable` permission.
  ///
  /// Same tombstone shape as [deleteMember] — `users/{uid}` is
  /// `allow delete: if false`, so the membership is never hard-deleted: the
  /// member row goes `disabled` and the organization binding is dropped from
  /// the profile so the account can be invited again later.
  Future<void> leaveOrganization({
    required String organizationId,
    required String memberId,
    required String uid,
  });

  /// `organizations/{orgId}/auditLogs/{logId}` — append-only.
  Future<void> writeAudit({
    required String organizationId,
    required String action,
    required String entityType,
    required String entityId,
    Map<String, dynamic>? details,
  });
}

/// Google Sign-In adapter (Windows uses the loopback browser flow).
abstract interface class GoogleAuthDataSource {
  bool get isConfigured;

  /// [clientId] must be a **Desktop app** OAuth client id — the Windows flow
  /// sends `http://127.0.0.1:<random port>` as `redirect_uri`, and Google only
  /// ignores the port for that client type.
  Future<GoogleAuthResult> signIn({required String clientId});

  Future<GoogleAuthResult?> signInSilently({required String clientId});
}

class GoogleAuthResult {
  const GoogleAuthResult({this.idToken, this.email, this.displayName, this.photoUrl});

  final String? idToken;
  final String? email;
  final String? displayName;
  final String? photoUrl;

  bool get isValid => idToken != null && idToken!.isNotEmpty;
}

class RemoteUser {
  const RemoteUser({required this.uid, required this.email, this.displayName, this.photoUrl});

  final String uid;
  final String email;
  final String? displayName;
  final String? photoUrl;
}

class UserProfile {
  const UserProfile({
    required this.uid,
    required this.email,
    required this.organizationId,
    required this.role,
    required this.status,
    this.memberId = '',
    this.displayName = '',
    this.photoUrl,
    this.version = 1,
  });

  final String uid;
  final String email;
  final String organizationId;
  final String role;
  final String status;
  final String memberId;
  final String displayName;
  final String? photoUrl;
  final int version;

  static UserProfile? fromMap(Map<String, dynamic>? data, String uid, String email) {
    if (data == null) return null;
    final orgId = '${data['organizationId'] ?? ''}';
    if (orgId.isEmpty) return null;
    return UserProfile(
      uid: uid,
      email: '${data['email'] ?? email}',
      organizationId: orgId,
      role: '${data['role'] ?? 'viewer'}',
      status: '${data['status'] ?? 'invited'}',
      memberId: '${data['memberId'] ?? ''}',
      displayName: '${data['displayName'] ?? ''}',
      photoUrl: data['photoUrl'] as String?,
      version: (data['version'] as num?)?.toInt() ?? 1,
    );
  }
}

class Invite {
  const Invite({
    required this.organizationId,
    required this.email,
    required this.role,
    this.memberId = '',
    this.status = 'invited',
  });

  final String organizationId;
  final String email;
  final String role;
  final String memberId;
  final String status;

  static Invite? fromMap(String organizationId, Map<String, dynamic>? data) {
    if (data == null) return null;
    return Invite(
      organizationId: '${data['organizationId'] ?? organizationId}',
      email: '${data['email'] ?? ''}',
      role: '${data['role'] ?? 'viewer'}',
      memberId: '${data['memberId'] ?? ''}',
      status: '${data['status'] ?? 'invited'}',
    );
  }
}

class OrganizationProfile {
  const OrganizationProfile({
    required this.id,
    required this.name,
    required this.ownerUid,
    this.status = 'active',
    this.schemaVersion = 2,
  });

  final String id;
  final String name;
  final String ownerUid;
  final String status;
  final int schemaVersion;

  static OrganizationProfile? fromMap(String id, Map<String, dynamic>? data) {
    if (data == null) return null;
    return OrganizationProfile(
      id: id,
      name: '${data['name'] ?? id}',
      ownerUid: '${data['ownerUid'] ?? ''}',
      status: '${data['status'] ?? 'active'}',
      schemaVersion: (data['schemaVersion'] as num?)?.toInt() ?? 2,
    );
  }
}
