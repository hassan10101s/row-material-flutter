import '../../members/domain/member_repository.dart';

/// Organization lifecycle (plan §8.5): only the first founder calls this, once.
abstract interface class OrganizationRepository {
  /// Creates `organizations/{orgId}` + `meta` + the admin `members/{member_<uid>}`
  /// + `users/{uid}` in one batch and returns the organization id.
  Future<String> createOrganization({required String name});

  /// The signed-in account has no profile: let the user join with an invite
  /// code (`organizations/{orgId}/invites/{b64url(lower(email))}`).
  Future<void> joinWithInvite({required String organizationId});

  /// Organization profile (name, owner, schema version).
  Future<OrganizationProfile?> loadOrganization();

  /// Renames the organization. `org.update` + a fresh session are required.
  Future<void> rename(String name);

  /// Member management, exposed here so the members screen needs a single
  /// dependency (and a Django implementation can swap both together).
  MemberRepository get members;
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
}
