import '../../../core/sync/remote/remote_data_source.dart';

/// Member entity as stored in Firestore `organizations/{orgId}/members` and
/// mirrored into the local `users` table (plan §6.2, §8.3).
class Member {
  const Member({
    required this.id,
    required this.email,
    required this.role,
    required this.status,
    this.uid = '',
    this.displayName = '',
    this.version = 1,
  });

  final String id;
  final String uid;
  final String email;
  final String role;
  final String status;
  final String displayName;
  final int version;

  bool get isActive => status == 'active';
  bool get isInvited => status == 'invited';
  bool get isDisabled => status == 'disabled';

  /// True once the member signed in with Google and claimed the invite.
  bool get isLinked => uid.isNotEmpty;

  String get label => displayName.isNotEmpty ? displayName : email;

  static Member fromDocument(RemoteDocument document) {
    final data = document.data;
    return Member(
      id: document.id,
      uid: '${data['uid'] ?? ''}',
      email: '${data['email'] ?? ''}',
      role: '${data['role'] ?? 'viewer'}',
      status: '${data['status'] ?? 'invited'}',
      displayName: '${data['displayName'] ?? ''}',
      version: document.version,
    );
  }
}

/// Member + invite management (plan P3.1/P3.2).
///
/// All methods are **online only**: the roster is the authorization source, so
/// it is committed to Firestore first and then mirrored locally. Nothing here
/// goes through the sync queue.
abstract interface class MemberRepository {
  Future<List<Member>> listMembers();

  /// Invites by e-mail. `inviteKey = base64url_nopad(lower(email))`.
  Future<void> invite({required String email, required String role});

  Future<void> changeRole({required String memberId, required String role});

  /// `active` | `disabled`. Activating also flips `users/{uid}` remotely, so
  /// the employee device picks the permissions up on its next pull.
  Future<void> setStatus({required String memberId, required String status});

  /// Writes a tombstone (never a hard delete) so the removal replicates.
  Future<void> removeMember({required String memberId});

  /// Self-service departure: the signed-in member leaves the organization.
  ///
  /// Deliberately **unguarded** — any role may leave, so it must not require a
  /// `users.*` permission. `firestore.rules` has a matching self-leave branch
  /// that can only ever move the row to `disabled`, so leaving can never be
  /// used to change a role or an e-mail.
  Future<void> leave();
}
