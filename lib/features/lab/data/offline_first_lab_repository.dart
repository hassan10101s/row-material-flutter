import 'package:sqflite/sqflite.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/entity_registry.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/lab_result_repository.dart';
import 'lab_repo.dart';

/// Offline-first facade over the local [LabRepo] (plan P5.2, P7.1).
///
/// Same arrangement as the inspections facade: the local repository keeps all of
/// its SQL, and this class is the seam that owns the V2 write contract - the
/// `lab_sample_tests` row, its `sync_queue` entry and its `audit_logs` outbox
/// row commit in one transaction, guarded by §9.4. It extends [LabRepo] so the
/// lab cubits and widgets keep their current dependency type (GetIt registers
/// this class under the name `LabRepo`).
///
/// Only the *lab results* replicate (plan §6.3): inventory, consumption and the
/// worksheet stay device-local, so `saveWorksheet` is left alone and only
/// `runSampleTest` — the row behind `organizations/{orgId}/labResults` — is
/// wrapped.
class OfflineFirstLabRepository extends LabRepo
    implements LabResultRepository, LabConfigurationRepository {
  OfflineFirstLabRepository({
    required super.dbHelper,
    required this.guard,
    required this.queue,
    required this.audit,
  });

  final WriteGuard guard;
  final SyncQueue queue;
  final AuditLogger audit;

  static final SyncEntity _labResult =
      syncEntities.firstWhere((e) => e.type == 'labResult');

  /// `lab_results.create` - a lab technician saves a test result.
  @override
  Future<Map<String, dynamic>> runSampleTest({
    required int analysisId,
    required String sourceType,
    int? sourceRefId,
    required String sourceName,
    required String sampleName,
    String resultText = '',
    Map<String, dynamic>? dynamicValues,
    Map<String, dynamic>? user,
    String entryCode = '',
    bool manualResult = false,
    DatabaseExecutor? exec,
  }) async {
    if (exec != null) {
      return super.runSampleTest(
        analysisId: analysisId,
        sourceType: sourceType,
        sourceRefId: sourceRefId,
        sourceName: sourceName,
        sampleName: sampleName,
        resultText: resultText,
        dynamicValues: dynamicValues,
        user: user,
        entryCode: entryCode,
        manualResult: manualResult,
        exec: exec,
      );
    }
    _check(Permission.labResultsCreate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final result = await super.runSampleTest(
        analysisId: analysisId,
        sourceType: sourceType,
        sourceRefId: sourceRefId,
        sourceName: sourceName,
        sampleName: sampleName,
        resultText: resultText,
        dynamicValues: dynamicValues,
        user: user,
        entryCode: entryCode,
        manualResult: manualResult,
        exec: txn,
      );
      await _enqueueResult(txn, result['test'] as Map<String, dynamic>?);
      return result;
    });
  }

  // ── Transaction plumbing ─────────────────────────────────────────────────

  /// §9.4: active member + permission + not a read-only device, and
  /// connectivity for the privileged operations.
  void _check(Permission permission) {
    if (guard.allows(permission.id)) return;
    final privileged = permissionRequiresFreshSession(permission);
    throw AuthorizationError(
      privileged && !guard.online
          ? AppErrors.privilegedOperationNeedsConnection
          : AppErrors.notAuthorizedForOperation,
    );
  }

  /// Same bookkeeping as the inspections facade: bump the local sync version,
  /// snapshot the remote payload, queue it and append the audit entry - all on
  /// the caller's executor, so a failure rolls the whole test back.
  Future<void> _enqueueResult(
      DatabaseExecutor txn, Map<String, dynamic>? test) async {
    final id = (test?['id'] as num?)?.toInt();
    if (test == null || id == null) return;
    final current = await txn.query('lab_sample_tests',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (current.isEmpty) return;
    final fresh = Map<String, dynamic>.from(current.first);
    final localVersion = (fresh['version'] as num?)?.toInt() ?? 0;
    final remoteVersion = (fresh['remote_version'] as num?)?.toInt() ?? 0;
    final isFirstPush = remoteVersion == 0;
    final nextVersion = isFirstPush
        ? 1
        : (localVersion > remoteVersion ? localVersion : remoteVersion) + 1;
    await txn.update('lab_sample_tests', {
      'version': nextVersion,
      'sync_state': 'queued',
    }, where: 'id = ?', whereArgs: [id]);

    final snapshot = Map<String, dynamic>.from(fresh)
      ..['version'] = nextVersion
      ..['sync_state'] = 'queued';
    final ctx = SyncPayloadContext(
      organizationId: guard.organizationId,
      uid: guard.uid,
      deviceId: guard.deviceId,
      version: nextVersion,
      versionField: 'version',
    );
    final docId = _labResult.docId(snapshot);
    await queue.enqueue(
      txn,
      entityType: _labResult.type,
      entityId: docId,
      localRef: id,
      operation: isFirstPush ? 'create' : 'update',
      payload: buildRemotePayload(_labResult, snapshot, ctx, asCreate: isFirstPush),
      baseVersion: remoteVersion,
    );
    await audit.log(
      txn,
      action: AuditAction.labResultSaved,
      entityType: _labResult.type,
      entityId: docId,
      details: {
        'localId': id,
        'version': nextVersion,
        'analysisId': snapshot['analysis_id'],
        'sourceName': snapshot['source_name'],
        'sampleName': snapshot['sample_name'],
      },
    );
  }
}
