import 'package:sqflite/sqflite.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/entity_registry.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/sync/sync_write.dart' show newRemoteId;
import '../../../core/utils/app_exceptions.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/inspection_repository.dart';
import 'inspection_repo.dart';

/// Shared inspection writes run through the server-confirmed business gateway.
/// SQLite holds the approved read cache; unsent work remains a manual draft.
/// Candidate changes and their audit are captured atomically, and success is
/// returned only after the server receipt. Queue rows never trigger auto-send.
class ServerConfirmedInspectionRepository extends InspectionRepo
    implements InspectionRepository, SampleRepository, QualityCheckRepository {
  ServerConfirmedInspectionRepository({
    required super.dbHelper,
    required super.referenceRepo,
    super.htmlBuilder,
    required this.guard,
    required this.queue,
    required this.audit,
  });

  final WriteGuard guard;
  final SyncQueue queue;
  final AuditLogger audit;

  static final SyncEntity _sample = syncEntities.firstWhere(
    (e) => e.type == 'sample',
  );
  static final SyncEntity _qualityCheck = syncEntities.firstWhere(
    (e) => e.type == 'qualityCheck',
  );

  // ── §9.4 writes ──────────────────────────────────────────────────────────

  /// `samples.create` — a new inspection.
  @override
  Future<Map<String, dynamic>> create(
    Map<String, dynamic> payload,
    UserContext user, {
    DatabaseExecutor? exec,
  }) async {
    if (exec != null) return super.create(payload, user, exec: exec);
    _check(Permission.samplesCreate);
    // The entry-code generator needs the device tag. Warm it before opening
    // the write transaction so metadata cannot be read through a second
    // connection while this transaction owns the database lock.
    await referenceRepo.warmDeviceTag();
    if (dbHelper.businessGateway != null &&
        InspectionRepo.normalizeKind(payload['inspection_kind']) ==
            InspectionRepo.kindProduct) {
      // Product inspections still need a local SQLite FK placeholder. Like
      // CentralProjection, prepare that inactive cache-only helper outside
      // business capture; it is never a shared material or a command effect.
      final db = await dbHelper.database;
      await db.transaction(
        (txn) => dbHelper.ensureProductSentinelMaterialId(txn),
      );
    }
    final row = await _inTransaction((txn) async {
      final row = await super.create(payload, user, exec: txn);
      await _enqueueSample(
        txn,
        row,
        user,
        operation: 'create',
        action: AuditAction.sampleCreated,
        details: {'entryCode': row['entry_code']},
      );
      return row;
    });
    // After the commit, never inside it: the report builder reads on the root
    // handle, which a parked-until-commit statement cannot do. See
    // `InspectionRepo.refreshReportHtml`.
    await refreshReportHtml((row['id'] as num).toInt());
    return row;
  }

  /// `samples.update` — editing the inspection data.
  @override
  Future<Map<String, dynamic>> update(
    int inspectionId,
    Map<String, dynamic> payload,
    UserContext user, {
    DatabaseExecutor? exec,
  }) async {
    if (exec != null) {
      return super.update(inspectionId, payload, user, exec: exec);
    }
    _check(Permission.samplesUpdate);
    final updated = await _inTransaction((txn) async {
      final row = await super.update(inspectionId, payload, user, exec: txn);
      await _enqueueSample(
        txn,
        row,
        user,
        operation: 'update',
        action: AuditAction.sampleUpdated,
        details: {'entryCode': row['entry_code']},
      );
      return row;
    });
    // See `create`: the report is rendered from committed state.
    await refreshReportHtml(inspectionId);
    return updated;
  }

  /// A QC decision is privileged ([Permission.qcApprove] / [Permission.qcReject]
  /// are in `privilegedPermissions`), so §9.4 rule 4 applies: it needs
  /// connectivity and a fresh token. The decision, the sample update and the
  /// append-only `qualityCheck` entry all commit together.
  @override
  Future<Map<String, dynamic>> updateStatus(
    int inspectionId,
    Map<String, dynamic> payload,
    UserContext user, {
    DatabaseExecutor? exec,
  }) async {
    if (exec != null) {
      return super.updateStatus(inspectionId, payload, user, exec: exec);
    }
    final status = '${payload['decision_status'] ?? ''}'.toLowerCase();
    final rejected = status.contains('reject') || status.contains('رفض');
    _check(rejected ? Permission.qcReject : Permission.qcApprove);
    final decided = await _inTransaction((txn) async {
      final before = await txn.query(
        'inspections',
        columns: ['decision_status'],
        where: 'id = ?',
        whereArgs: [inspectionId],
        limit: 1,
      );
      final row = await super.updateStatus(
        inspectionId,
        payload,
        user,
        exec: txn,
      );
      await _enqueueSample(
        txn,
        row,
        user,
        operation: 'update',
        action: rejected ? AuditAction.qcRejected : AuditAction.qcApproved,
        details: {
          'entryCode': row['entry_code'],
          'decisionStatus': row['decision_status'],
        },
      );
      // Notes/reasons can change while the status stays the same. In that
      // case no history row was inserted; re-sending the latest old history
      // would attempt to update an immutable Firestore qualityCheck.
      if (before.isNotEmpty &&
          before.single['decision_status'] != row['decision_status']) {
        await _enqueueDecisionHistory(txn, row);
      }
      return row;
    });
    // See `create`: the report is rendered from committed state.
    await refreshReportHtml(inspectionId);
    return decided;
  }

  /// A tombstone, not a delete (plan §5/P7.1): the local row survives so the
  /// deletion replicates and is audited, and every list hides it.
  @override
  Future<void> delete(int inspectionId, {DatabaseExecutor? exec}) async {
    if (exec != null) return super.delete(inspectionId, exec: exec);
    _check(Permission.samplesUpdate);
    await _inTransaction<void>((txn) async {
      await super.delete(inspectionId, exec: txn);
      final rows = await txn.query(
        'inspections',
        where: 'id = ?',
        whereArgs: [inspectionId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final row = Map<String, dynamic>.from(rows.first);
      await _enqueueSample(
        txn,
        row,
        _systemUser(),
        operation: 'tombstone',
        action: AuditAction.sampleDeleted,
        details: {'entryCode': row['entry_code']},
      );
    });
  }

  // ── Transaction plumbing ─────────────────────────────────────────────────

  Future<T> _inTransaction<T>(
    Future<T> Function(DatabaseExecutor txn) body,
  ) async {
    return dbHelper.businessTransaction<T>(body);
  }

  /// §9.4: active member + permission + not a read-only device, and
  /// connectivity for the privileged operations. Throws
  /// [AuthorizationError] otherwise, before anything is written.
  void _check(Permission permission) {
    if (guard.allows(permission.id)) return;
    final privileged = permissionRequiresFreshSession(permission);
    throw AuthorizationError(
      privileged && !guard.online
          ? AppErrors.privilegedOperationNeedsConnection
          : AppErrors.notAuthorizedForOperation,
    );
  }

  /// Bumps the sync bookkeeping of the row, snapshots the remote payload, queues
  /// it and appends the audit entry — all on the caller's executor.
  Future<void> _enqueueSample(
    DatabaseExecutor txn,
    Map<String, dynamic> row,
    UserContext user, {
    required String operation,
    required String action,
    required Map<String, dynamic> details,
  }) async {
    final id = (row['id'] as num?)?.toInt();
    if (id == null) return;
    final current = await txn.query(
      'inspections',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (current.isEmpty) return;
    final fresh = Map<String, dynamic>.from(current.first);
    // Children must be able to reference a newly saved inspection before
    // another database open runs the legacy-id backfill.
    if ('${fresh['remote_id'] ?? ''}'.isEmpty) {
      fresh['remote_id'] = newRemoteId();
      row['remote_id'] = fresh['remote_id'];
    }
    // Optimistic sync version (plan §9.2): a row the remote has never seen is
    // created at v1 however many offline edits collapse into that one push,
    // and every edit after the first acknowledgement moves the local version one
    // step past the remote. `baseVersion` stays at the acknowledged version.
    final localVersion = (fresh['version'] as num?)?.toInt() ?? 0;
    final remoteVersion = (fresh['remote_version'] as num?)?.toInt() ?? 0;
    final isFirstPush = remoteVersion == 0;
    final nextVersion = isFirstPush
        ? 1
        : (localVersion > remoteVersion ? localVersion : remoteVersion) + 1;
    await txn.update(
      'inspections',
      {
        'remote_id': fresh['remote_id'],
        'version': nextVersion,
        'sync_state': 'queued',
      },
      where: 'id = ?',
      whereArgs: [id],
    );

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
    final docId = _sample.docId(snapshot);
    await queue.enqueue(
      txn,
      entityType: _sample.type,
      entityId: docId,
      localRef: id,
      operation: operation,
      payload: buildRemotePayload(
        _sample,
        snapshot,
        ctx,
        asCreate: isFirstPush,
      ),
      baseVersion: remoteVersion,
    );
    await audit.log(
      txn,
      action: action,
      entityType: _sample.type,
      entityId: docId,
      details: {
        ...details,
        'localId': id,
        'version': nextVersion,
        'operation': operation,
        if (user.fullName.isNotEmpty) 'actor': user.fullName,
      },
    );
  }

  /// The decision history is an append-only `qualityCheck` document
  /// (`qc_{inspectionId}_{version}`); it is queued in the same transaction as
  /// the decision itself so the two can never diverge.
  Future<void> _enqueueDecisionHistory(
    DatabaseExecutor txn,
    Map<String, dynamic> row,
  ) async {
    final inspectionId = (row['id'] as num?)?.toInt();
    if (inspectionId == null) return;
    final history = await txn.query(
      'inspection_status_history',
      where: 'inspection_id = ?',
      whereArgs: [inspectionId],
      orderBy: 'version DESC, id DESC',
      limit: 1,
    );
    if (history.isEmpty) return;
    final entry = Map<String, dynamic>.from(history.first);
    final version = (entry['version'] as num?)?.toInt() ?? 1;
    final ctx = SyncPayloadContext(
      organizationId: guard.organizationId,
      uid: guard.uid,
      deviceId: guard.deviceId,
      version: version,
      versionField: 'version',
    );
    await queue.enqueue(
      txn,
      entityType: _qualityCheck.type,
      entityId: _qualityCheck.docId(entry),
      localRef: (entry['id'] as num?)?.toInt(),
      operation: 'create',
      payload: buildRemotePayload(_qualityCheck, entry, ctx, asCreate: true),
      baseVersion: 0,
    );
  }

  UserContext _systemUser() =>
      UserContext(id: null, fullName: guard.actorName, role: '');
}
