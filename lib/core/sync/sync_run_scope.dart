import '../auth/app_session.dart';
import '../auth/session_source.dart';
import '../database/database_helper.dart';

/// A network response belongs to the session and file that initiated it.
/// Reading the live organization again after an await can send or apply an
/// old organization's rows in the newly bound organization.
class SyncRunScope {
  SyncRunScope(this.source, this.database)
    : session = source.session,
      generation = database.connectionGeneration;

  final SessionSource source;
  final DatabaseHelper database;
  final AppSession session;
  final int generation;
  bool _cancelled = false;

  void cancel() => _cancelled = true;

  bool get isCurrent {
    final current = source.session;
    return !_cancelled &&
        database.connectionGeneration == generation &&
        current.uid == session.uid &&
        current.memberId == session.memberId &&
        current.organizationId == session.organizationId &&
        current.deviceId == session.deviceId &&
        current.role == session.role &&
        current.rolesKey == session.rolesKey &&
        current.status == session.status &&
        current.readOnlyDevice == session.readOnlyDevice &&
        current.organizationStatus == session.organizationStatus &&
        current.trialEndsAt == session.trialEndsAt &&
        current.manuallyActivated == session.manuallyActivated;
  }

  void check() {
    if (!isCurrent) throw const SyncRunCancelled();
  }
}

class SyncRunCancelled implements Exception {
  const SyncRunCancelled();

  @override
  String toString() => 'Sync cancelled: session or database changed';
}
