import 'dart:math';

import '../auth/app_session.dart';
import '../auth/session_source.dart';
import '../auth/permissions.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'audit_logger.dart';
import 'entity_registry.dart';
import 'remote/remote_data_source.dart';
import 'sync_codec.dart';
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
    this.maxConcurrency = 8,
  });

  final SyncQueue queue;
  final SyncMetadata metadata;
  final RemoteDataSource remote;
  final AuditLogger audit;
  final SessionSource source;

  /// Read live: the session changes on sign-in, sign-out and org switch.
  AppSession get session => source.session;
  final int batchSize;

  /// Upper bound on simultaneous Firestore writes from one device.
  ///
  /// 8 keeps a burst of writes under the Firestore per-client limit while
  /// still overlapping the network latency, which is what the serial version
  /// was paying in full.
  final int maxConcurrency;

  int get effectiveConcurrency => min(maxConcurrency, batchSize);

  Future<PushReport> runOnce() async {
    if (!remote.isSignedIn) return PushReport.empty;
    final entries = await queue.claim(limit: batchSize);
    if (entries.isEmpty) return PushReport.empty;

    var pushed = 0;
    var retried = 0;
    var conflicts = 0;
    var failed = 0;
    String? lastError;

    // Phase 1: the purely local rejections. They cost no network round-trip, so
    // they are settled on their own instead of occupying a concurrency slot.
    final sendable = <QueueEntry>[];
    final settlements = <QueueSettlement>[];
    final audits = <Future<void> Function()>[];

    for (final entry in entries) {
      final entity = entry.entity;
      if (entity == null) {
        settlements.add(QueueSettlement.conflict(
          entry,
          direction: 'push_rejected',
          error: 'Unknown entity type ${entry.entityType}',
        ));
        conflicts++;
        continue;
      }
      if (!_allowedLocally(entity)) {
        settlements.add(QueueSettlement.conflict(
          entry,
          direction: 'push_rejected',
          error: 'Permission ${entity.permission} is not granted',
        ));
        final target = entry;
        audits.add(() => _auditDenied(target));
        conflicts++;
        continue;
      }
      sendable.add(entry);
    }

    // Phase 2: the network round-trips, at most [maxConcurrency] in flight.
    // They were fully serial, so a 400-row batch paid 400 round-trip latencies
    // back to back. Entities are independent documents, so overlapping them is
    // safe; the cap keeps the socket pool and the Firestore rate limit in view.
    // Each push is individually guarded: a poisoned remote map or a throwing
    // data-source must degrade to retry/conflict for that entry, never abort
    // the whole 400-row batch (the old jsonEncode(Timestamp) crash did).
    final results = await _mapWithConcurrency(
      sendable,
      effectiveConcurrency,
      (entry) => _pushOneGuarded(entry),
    );

    for (var i = 0; i < results.length; i++) {
      final entry = sendable[i];
      final result = results[i];
      switch (result.kind) {
        case PushResultKind.success:
          settlements.add(QueueSettlement.done(entry, remoteVersion: result.version));
          pushed++;
          lastError = null;
        case PushResultKind.permissionDenied:
          settlements.add(QueueSettlement.conflict(
            entry,
            direction: 'push_rejected',
            // Never throws: sanitized + try/catch inside. Previously a raw
            // Firestore Timestamp here crashed the entire batch.
            remotePayload: SyncCodec.tryEncodeMap(result.remote),
            error: result.error,
          ));
          final target = entry;
          audits.add(() => _logConflict(target, result.error ?? 'permission denied'));
          conflicts++;
          lastError = result.error;
        case PushResultKind.payloadTooLarge:
          settlements.add(QueueSettlement.conflict(
            entry,
            direction: 'payload_too_large',
            error: result.error,
          ));
          final target = entry;
          audits.add(() => _logConflict(target, result.error ?? 'payload too large'));
          conflicts++;
          lastError = result.error;
        case PushResultKind.retryable:
          settlements.add(QueueSettlement.retry(entry, result.error ?? 'unknown error'));
          retried++;
          lastError = result.error;
      }
    }

    // Phase 3: one commit for the whole batch. Writing each outcome as it
    // arrived meant an fsync per entry, and a crash midway left the queue
    // describing a push that had already happened.
    await queue.settleAll(settlements);
    for (final audit in audits) {
      await audit();
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

  /// Per-entry guard: the data-source contract returns [PushResult], but a
  /// hostile map (raw Timestamp) or a throwing implementation must not escape
  /// as an unhandled exception and strand the batch in `in_flight`.
  Future<PushResult> _pushOneGuarded(QueueEntry entry) async {
    try {
      return await _pushOne(entry);
    } on Object catch (e) {
      return PushResult.retryable('$e');
    }
  }

  /// The remote call for one entry, tombstone or document.
  Future<PushResult> _pushOne(QueueEntry entry) {
    final entity = entry.entity;
    if (entity == null) {
      // Unreachable from [runOnce]: unresolvable entities are rejected locally
      // before they reach the send phase.
      return Future.value(PushResult.retryable('Unknown entity type ${entry.entityType}'));
    }
    return entry.operation == 'tombstone'
        ? _pushTombstone(entity, entry)
        : _pushDocument(entity, entry);
  }

  /// Applies [action] over [items] with at most [limit] calls in flight,
  /// preserving input order in the result.
  static Future<List<R>> _mapWithConcurrency<T, R>(
    List<T> items,
    int limit,
    Future<R> Function(T item) action,
  ) async {
    if (items.isEmpty) return const [];
    final results = List<R?>.filled(items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= items.length) return;
        results[index] = await action(items[index]);
      }
    }

    final workers = min(limit, items.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return results.cast<R>();
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
    await tracedTransaction(db, 'push.auditDenied', (txn) async {
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
    await tracedTransaction(db, 'push.auditConflict', (txn) async {
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
