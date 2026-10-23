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
    this.trialStartedAt,
    this.trialEndsAt,
    this.trialConsumed = false,
    this.manuallyActivated = false,
  });

  final String id;
  final String name;
  final String ownerUid;
  final String status;
  final int schemaVersion;

  /// ISO-8601 of when the 30-day trial started (null for legacy documents).
  final String? trialStartedAt;

  /// ISO-8601 of when the 30-day trial ends (null for legacy documents).
  final String? trialEndsAt;

  /// True once the trial has expired (server cron only). Stays true after
  /// manual activation so the cron can never re-suspend the company.
  final bool trialConsumed;

  /// True once support manually activated the company. Permanent: such a
  /// company must never be auto-suspended again.
  final bool manuallyActivated;

  bool get isSuspended => status == 'suspended' || status == 'disabled';

  bool get isUsable => status == 'trial' || status == 'active';
}

/// Raised when an organization/member write is rejected.
///
/// Lives in the domain rather than beside the Firestore implementation because
/// it is part of what a caller has to handle: the members screen catches it by
/// type, and importing the data layer to name an exception would be exactly the
/// dependency inversion the boundary test exists to prevent.
class OrganizationFailure implements Exception {
  const OrganizationFailure(this.message, {this.code = 'failed'});

  final String message;
  final String code;

  @override
  String toString() => message;
}
