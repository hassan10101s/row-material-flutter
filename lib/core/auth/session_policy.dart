/// Refreshing an ID token or a profile must never renew this deadline.
class SessionPolicy {
  static const currentVersion = 1;
  static const maximumAge = Duration(days: 10);

  static bool requiresSignIn(
    DateTime? signedInAt,
    DateTime now, {
    int policyVersion = currentVersion,
  }) {
    if (policyVersion != currentVersion || signedInAt == null) return true;
    final age = now.toUtc().difference(signedInAt.toUtc());
    // A future timestamp cannot establish a trustworthy sign-in age.
    return age.isNegative || age >= maximumAge;
  }
}
