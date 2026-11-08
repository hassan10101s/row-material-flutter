import 'dart:async';

/// A user-started archive privacy job migrates whole independent records.
/// Every record retains one atomic, versioned command and the normal effect
/// limit; inventory, decisions and unrelated records never join this family.
class SecureMigrationScope {
  const SecureMigrationScope(
    this.jobId,
    this.parameterNames, {
    this.secureTargets = const {},
    this.privacyEpoch = 0,
    this.metadataOnly = false,
  });
  final int privacyEpoch;
  final bool metadataOnly;
  final Map<String, Set<String>> secureTargets;
  final String jobId;
  final Set<String> parameterNames;
  static final _key = Object();
  static SecureMigrationScope? get current =>
      Zone.current[_key] as SecureMigrationScope?;
  Future<T> run<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_key: this});
}
