import 'dart:convert';

import '../auth/app_session.dart';
import '../auth/session_source.dart';
import '../auth/permissions.dart';
import '../utils/app_dates.dart';
import 'audit_logger.dart';
import 'entity_registry.dart';
import 'remote/remote_data_source.dart';
import 'sync_metadata.dart';
import 'sync_queue.dart';

/// Outcome of one `push_worker` pass.
class PushReport {
  const PushReport({
    required this.pushed,
    required this.retried,
    required this.conflicts,
    required this.failed,
    this.lastError,
  });

  final int pushed;
  final int retried;
  final int conflicts;
  final int failed;
  final String? lastError;

  static const PushReport empty = PushReport(pushed: 0, retried: 0, conflicts: 0, failed: 0);
}

/// Pushes `sync_queue` rows to the remote backend (plan §9.3).
///
/// Classification of failures is the whole point of this class:
/// * success            → delete row, bump `remote_version`
/// * permission-denied  → `sync_conflicts` (never retried automatically)
/// * payload too large  → `sync_conflicts` with `payload_too_large`
/// * anything transient  → exponential backoff
class PushWorker {
  PushWorker({
    required this.queue,
    required this.metadata,
    required this.remote,
    required this.audit,
    required this.source,
    this.batchSize = 400,
  });

  final SyncQueue queue;
  final SyncMetadata metadata;
  final RemoteDataSource remote;
  final AuditLogger audit;
  final SessionSource source;

  /// Read live: the session changes on sign-in, sign-out and org switch.
  AppSession get session => source.session;
  final int batchSize;

  Future<PushReport> runOnce() async {
    if (!remote.isSignedIn) return PushReport.empty;
    final entries = await queue.claim(limit: batchSize);
    if (entries.isEmpty) return PushReport.empty;

    var pushed = 0;
    var retried = 0;
    var conflicts = 0;
    var failed = 0;
    String? lastError;

    for (final entry in entries) {
      final entity = entry.entity;
      if (entity == null) {
        await queue.markConflict(entry,
            direction: 'push_rejected', error: 'Unknown entity type ${entry.entityType}');
        conflicts++;
        continue;
      }
      if (!_allowedLocally(entity)) {
        await queue.markConflict(entry,
            direction: 'push_rejected', error: 'Permission ${entity.permission} is not granted');
        await _auditDenied(entry);
        conflicts++;
        continue;
      }

      final result = entry.operation == 'tombstone'
          ? await _pushTombstone(entity, entry)
          : await _pushDocument(entity, entry);

      switch (result.kind) {
        case PushResultKind.success:
          await queue.markDone(entry, remoteVersion: result.version);
          pushed++;
          lastError = null;
        case PushResultKind.permissionDenied:
          await queue.markConflict(
            entry,
            direction: entry.operation == 'tombstone' ? 'push_rejected' : 'push_rejected',
            remotePayload: result.remote == null ? null : jsonEncode(result.remote),
            error: result.error,
          );
          await _logConflict(entry, result.error ?? 'permission denied');
          conflicts++;
          lastError = result.error;
        case PushResultKind.payloadTooLarge:
          await queue.markConflict(
            entry,
            direction: 'payload_too_large',
            error: result.error,
          );
          await _logConflict(entry, result.error ?? 'payload too large');
          conflicts++;
          lastError = result.error;
        case PushResultKind.retryable:
          await queue.markRetry(entry, result.error ?? 'unknown error');
          retried++;
          lastError = result.error;
      }
    }

    if (pushed > 0) {
      await metadata.markPush(DateTime.now());
      await metadata.markError(null);
    } else if (lastError != null) {
      await metadata.markError(lastError);
    }
    if (failed > 0) {
      lastError = 'failed';
    }
    return PushReport(
      pushed: pushed,
      retried: retried,
      conflicts: conflicts,
      failed: failed,
      lastError: lastError,
    );
  }

  Future<PushResult> _pushDocument(SyncEntity entity, QueueEntry entry) async {
    final organizationId = session.organizationId;
    if (organizationId.isEmpty) {
      return PushResult.retryable('no organization bound');
    }
    final payload = Map<String, dynamic>.from(entry.payload);
    if (entity.appendOnly) {
      return remote.appendDocument(
        organizationId: organizationId,
        collection: entity.collection,
        documentId: entry.entityId,
        data: payload,
      );
    }
    return remote.setDocument(
      organizationId: organizationId,
      collection: entity.collection,
      documentId: entry.entityId,
      data: payload,
      baseVersion: entry.baseVersion,
    );
  }

  Future<PushResult> _pushTombstone(SyncEntity entity, QueueEntry entry) async {
    final organizationId = session.organizationId;
    if (organizationId.isEmpty) return PushResult.retryable('no organization bound');
    try {
      await remote.deleteTombstone(
        organizationId: organizationId,
        collection: entity.collection,
        documentId: entry.entityId,
      );
      return PushResult.success(entry.baseVersion + 1);
    } on Object catch (e) {
      return PushResult.retryable('$e');
    }
  }

  /// Local gate before spending a network round-trip (the Rules are the second
  /// layer, this is the first one).
  bool _allowedLocally(SyncEntity entity) {
    final permission = entity.permission;
    if (permission == null) return true;
    final parsed = Permission.byId(permission);
    if (parsed == null) return true;
    return session.can(parsed);
  }

  Future<void> _auditDenied(QueueEntry entry) async {
    final db = await queue.dbHelper.database;
    await db.transaction((txn) async {
      await audit.log(
        txn,
        action: AuditAction.deniedEntry,
        entityType: entry.entityType,
        entityId: entry.entityId,
        details: {'reason': 'push blocked locally', 'at': nowIso()},
      );
    });
  }

  Future<void> _logConflict(QueueEntry entry, String error) async {
    final db = await queue.dbHelper.database;
    await db.transaction((txn) async {
      await audit.log(
        txn,
        action: AuditAction.syncConflict,
        entityType: entry.entityType,
        entityId: entry.entityId,
        details: {'error': error, 'operation': entry.operation},
      );
    });
  }
}
