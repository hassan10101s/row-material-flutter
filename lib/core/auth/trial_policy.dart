import 'permissions.dart';

/// One-time 30-day trial policy (pure logic, no Firebase imports).
///
/// The safety guarantee lives here, in one place, so it can be unit-tested:
///
/// 1. A new organization starts as `trial` with `trialEndsAt = created + 30d`.
/// 2. After `trialEndsAt`, the org is blocked (`suspended`) until manual
///    activation by support.
/// 3. After manual activation (`manuallyActivated == true`, `status == active`)
///    the org is **never** blocked again, no matter how much time passes.
///
/// The server cron (`functions/index.js`) and the client gate
/// (`OfflineFirstAuthRepository.resolveProfile`) both implement this same
/// truth table; the client additionally treats an expired-but-not-yet-flipped
/// `trial` as blocked so there is no gap before the cron runs.
abstract final class TrialPolicy {
  /// Length of the free trial.
  static const int trialDays = OrgStatus.trialDays;

  /// Computes `trialEndsAt` for a company created at [createdAt].
  static DateTime endsAtFor(DateTime createdAt) =>
      createdAt.add(const Duration(days: trialDays));

  /// True when [now] is at or past [trialEndsAt].
  ///
  /// A missing/unparsable [trialEndsAt] is treated as "not expired" so legacy
  /// documents without trial fields keep working until the backfill cron
  /// stamps them; they are never locked by a parse error.
  static bool isExpired(DateTime now, Object? trialEndsAt) {
    final endsAt = parseDate(trialEndsAt);
    if (endsAt == null) return false;
    return !now.isBefore(endsAt);
  }

  /// Parses the `trialEndsAt` field, which may be an ISO-8601 string (cached
  /// session / sanitized Firestore map), a `DateTime`, or a Firestore
  /// `Timestamp` (which exposes `toDate()`).
  static DateTime? parseDate(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value.toLocal().isUtc ? value : value;
    if (value is String) return DateTime.tryParse(value);
    try {
      final dynamic dyn = value;
      final asDate = dyn.toDate() as DateTime?;
      return asDate;
    } on Object {
      return null;
    }
  }

  /// Whether the server cron should suspend this organization now.
  ///
  /// Only ever true for `status == trial` with no manual activation and a
  /// passed `trialEndsAt`. Every other combination — especially anything with
  /// `manuallyActivated == true` or `status == active` — returns false.
  static bool shouldSuspend({
    required String status,
    required bool manuallyActivated,
    required bool trialConsumed,
    required Object? trialEndsAt,
    required DateTime now,
  }) {
    if (manuallyActivated) return false;
    if (status != OrgStatus.trial) return false;
    if (trialConsumed) return false;
    return isExpired(now, trialEndsAt);
  }

  /// Whether the client must block this organization (show the trial-expired
  /// screen instead of the dashboard).
  ///
  /// This is the function that carries the hard guarantee: **a manually
  /// activated organization is never blocked**, regardless of `trialEndsAt`,
  /// `trialConsumed`, or how many days have passed.
  static bool shouldBlock({
    required String status,
    required bool manuallyActivated,
    required Object? trialEndsAt,
    required DateTime now,
  }) {
    // The permanent-activation guarantee: support activated it by hand, so no
    // timer may ever lock it again.
    if (manuallyActivated) return false;
    if (status == OrgStatus.active) return false;
    if (status == OrgStatus.suspended) return true;
    if (status == OrgStatus.disabled) return true;
    if (status == OrgStatus.trial) return isExpired(now, trialEndsAt);
    // Unknown status: fail closed (block) rather than opening the company.
    return true;
  }
}
