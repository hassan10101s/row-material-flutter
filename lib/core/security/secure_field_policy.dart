import '../auth/app_session.dart';
import '../auth/permissions.dart';
import '../utils/app_format.dart';

enum SecureFieldPurpose { firstEntry, savedRecord, report }

/// Field privacy is separate from write permission and from a required flag.
/// Revealing data never makes it printable. First entry is transient: it must
/// not be reused for an already approved row or for an export preview.
class SecureFieldPolicy {
  const SecureFieldPolicy({required this.session, this.reveal = false});
  final AppSession session;
  final bool reveal;

  bool get mayManage =>
      session.isSignedIn &&
      session.isActiveMember &&
      session.hasOrganization &&
      !session.isOrgSuspended &&
      session.effectiveRoles.any(
        (role) =>
            role == AppRoles.admin ||
            role == AppRoles.trialOwner ||
            role == AppRoles.qualityManager,
      );

  bool visible(
    Object? reference,
    SecureFieldPurpose purpose, {
    bool isNewUnsavedRecord = false,
    bool canEnter = false,
  }) {
    if (!isReferenceSecure(reference)) return true;
    if (purpose == SecureFieldPurpose.report) return false;
    if (purpose == SecureFieldPurpose.firstEntry && isNewUnsavedRecord) {
      return session.canWrite && canEnter;
    }
    return mayManage && reveal;
  }

  /// Omits entire entries, including names; there is no masked placeholder.
  Map<String, dynamic> visibleParameters(
    Map<String, dynamic> values,
    Map<String, dynamic> references,
    SecureFieldPurpose purpose, {
    bool isNewUnsavedRecord = false,
    bool canEnter = false,
  }) => {
    for (final entry in values.entries)
      if (visible(
        references[entry.key],
        purpose,
        isNewUnsavedRecord: isNewUnsavedRecord,
        canEnter: canEnter,
      ))
        entry.key: entry.value,
  };
}

/// Public measurement columns omit secured fields. Definition metadata and
/// reference templates remain public so authorized staff can enter new tests;
/// only saved measurements are confidential.
/// The private part is submitted through a separate, create-only blind write.
/// It must not be merged back into the shared read cache or report inputs.
class SecureParameterPartition {
  SecureParameterPartition._(
    this.publicReferences,
    this.publicValues,
    this.privateReferences,
    this.privateValues,
  );
  final Map<String, dynamic> publicReferences;
  final Map<String, dynamic> publicValues;
  final Map<String, dynamic> privateReferences;
  final Map<String, dynamic> privateValues;

  factory SecureParameterPartition.split({
    required Map<String, dynamic> references,
    required Map<String, dynamic> values,
  }) {
    final secure = references.entries
        .where((entry) => isReferenceSecure(entry.value))
        .map((entry) => entry.key)
        .toSet();
    return SecureParameterPartition._(
      {
        for (final entry in references.entries)
          if (!secure.contains(entry.key)) entry.key: entry.value,
      },
      {
        for (final entry in values.entries)
          if (!secure.contains(entry.key)) entry.key: entry.value,
      },
      {
        for (final entry in references.entries)
          if (secure.contains(entry.key)) entry.key: entry.value,
      },
      {
        for (final entry in values.entries)
          if (secure.contains(entry.key)) entry.key: entry.value,
      },
    );
  }
}
