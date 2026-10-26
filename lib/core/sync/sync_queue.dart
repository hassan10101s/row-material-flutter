import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'entity_registry.dart';
import 'sync_codec.dart';

/// One `sync_queue` row.
class QueueEntry {
  const QueueEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payload,
    required this.baseVersion,
    required this.retryCount,
    required this.status,
    this.revision = 0,
    this.ownerUid = '',
    this.localRef,
    this.lastError,
  });

  final int id;
  final String entityType;
  final String entityId;
  final String operation;
  final Map<String, dynamic> payload;
  final int baseVersion;
  final int retryCount;
  final String status;

  /// Optimistic-concurrency token (plan §9.6).
  ///
  /// Bumped by every [enqueue], [claim] and [recoverStalled] write. A claim
  /// captures the value it saw and the settlement only applies when the row
  /// still carries it, so a settlement whose entity was re-edited while the
  /// push was in flight cannot delete that newer edit.
  final int revision;
  final String ownerUid;
  final int? localRef;
  final String? lastError;

  SyncEntity? get entity => SyncEntity.byType(entityType);

  static QueueEntry fromRow(Map<String, Object?> row) => QueueEntry(
    id: (row['id'] as num).toInt(),
    entityType: '${row['entity_type']}',
    entityId: '${row['entity_id']}',
    operation: '${row['operation']}',
    payload: jsonDecode('${row['payload']}') as Map<String, dynamic>,
    baseVersion: (row['base_version'] as num?)?.toInt() ?? 0,
    retryCount: (row['retry_count'] as num?)?.toInt() ?? 0,
    status: '${row['status']}',
    revision: (row['revision'] as num?)?.toInt() ?? 0,
    ownerUid: '${row['owner_uid'] ?? ''}',
    localRef: (row['local_ref'] as num?)?.toInt(),
    lastError: row['last_error'] as String?,
  );

  static String? payloadOwner(
    String entityType,
    String operation,
    Map<String, dynamic> payload,
  ) {
    final actor = entityType == 'auditLog'
        ? payload['userId']
        : payload['updatedBy'] ??
              (operation == 'create' ? payload['createdBy'] : null);
    return actor is String && actor.isNotEmpty && !actor.startsWith('local_')
        ? actor
        : null;
  }

  /// A copy carrying [revision], used by [SyncQueue.claim] to stamp the token
  /// it wrote so the settlement can match it.
  QueueEntry withRevision(int revision) => QueueEntry(
    id: id,
    entityType: entityType,
    entityId: entityId,
    operation: operation,
    payload: payload,
    baseVersion: baseVersion,
    retryCount: retryCount,
    status: status,
    revision: revision,
    ownerUid: ownerUid,
    localRef: localRef,
    lastError: lastError,
  );
}

/// What should happen to a queue row once its push attempt is done.
enum QueueOutcome { done, retry, conflict }

/// One settled push attempt, handed to [SyncQueue.settleAll] so a whole batch
/// shares a single transaction.
class QueueSettlement {
  const QueueSettlement.done(this.entry, {required this.remoteVersion})
    : kind = QueueOutcome.done,
      error = null,
      direction = null,
      remotePayload = null;

  const QueueSettlement.retry(this.entry, this.error)
    : kind = QueueOutcome.retry,
      remoteVersion = null,
      direction = null,
      remotePayload = null;

  const QueueSettlement.conflict(
    this.entry, {
    this.direction = 'push_rejected',
    this.remotePayload,
    this.error,
  }) : kind = QueueOutcome.conflict,
       remoteVersion = null;

  final QueueEntry entry;
  final QueueOutcome kind;
  final int? remoteVersion;
  final String? error;
  final String? direction;
  final String? remotePayload;
}

/// Row operations of `sync_queue` (plan §14-P6.2).
///
/// `enqueue` is designed to be called **inside the same transaction** as the
/// business write, so a crash can never leave a row that nobody pushed.
class SyncQueue {
  SyncQueue(this.dbHelper) {
    // After a restore or an organization switch the connection this queue
    // memoized belongs to a file that is no longer the live one.
    dbHelper.onDatabaseClosed(() => _resolved = null);
  }

  final DatabaseHelper dbHelper;

  /// Fired at the end of every [enqueue] (inside the business transaction).
  ///
  /// The service locator points this at `SyncEngine.scheduleSync`, which turns
  /// every local mutation into a debounced push within seconds — no waiting
  /// for the 60 s timer and no manual "sync now" tap. Fires pre-commit, so a
  /// rolled-back transaction causes at most one empty sync cycle. Null in
  /// tests and in any context without an engine.
  void Function()? onEnqueued;

  void _notifyEnqueued() {
    try {
      onEnqueued?.call();
    } on Object {
      // A listener must never break the business write it observes.
    }
  }

  Database? _resolved;

  /// `DatabaseHelper.database` is a `Future`, so it has to be awaited; the
  /// result is memoized because the queue is used per operation, and dropped as
  /// soon as the helper closes the connection.
  Future<Database> get _db async => _resolved ??= await dbHelper.database;

  /// Run [action] against the live connection, surviving a concurrent close.
  ///
  /// Memoizing the handle has an unavoidable window: `await _db` yields, the
  /// helper closes the database underneath us (an organization switch or a
  /// restore), and the caller's query then lands on a closed handle and throws
  /// `DatabaseException(error database_closed)`. The sync engine reads the
  /// counters below from an unawaited timer, so that escaped as an unhandled
  /// exception and killed the app during startup:
  ///
  ///     Unhandled Exception: DatabaseException(error database_closed)
  ///     #3 SyncQueue._count (package:material_lab/core/sync/sync_queue.dart)
  ///     #4 SyncEngine._current (package:material_lab/core/sync/sync_engine.dart)
  ///
  /// Dropping the memo and retrying once on a *fresh* connection turns that
  /// race into a slightly later, correct read. Any other error propagates
  /// untouched, so a genuine failure is never masked.
  Future<T> _withDb<T>(
    String label,
    Future<T> Function(Database db) action,
  ) async {
    try {
      final db = await _db;
      return await DbTrace.run(label, () => action(db));
    } on DatabaseException catch (e) {
      if (!e.isDatabaseClosedError()) rethrow;
      _resolved = null;
      final db = await _db;
      return await DbTrace.run(label, () => action(db));
    }
  }

  /// Queue (or refresh) the change of [entityType]/[entityId].
  ///
  /// The partial unique index `idx_sync_queue_entity` means one row per entity;
  /// consecutive offline edits collapse into a single push (`create` wins over
  /// `update`, and `tombstone` over both).
  ///
  /// A merge into a row that is currently `in_flight` is deliberate and safe:
  /// the running push settles against the revision *it* claimed (see
  /// `QueueEntry.revision`), so resetting the row to `pending` here keeps the
  /// newer edit queued instead of letting the older push's `markDone` delete it
  /// (the lost-update race).
  Future<void> enqueue(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
    int? localRef,
    required String operation,
    required Map<String, dynamic> payload,
    int baseVersion = 0,
  }) async {
    final existing = await txn.query(
      'sync_queue',
      where:
          "entity_type = ? AND entity_id = ? AND status IN ('pending','in_flight','blocked','conflict','failed')",
      whereArgs: [entityType, entityId],
      orderBy:
          "CASE WHEN status IN ('pending','in_flight','blocked') THEN 0 ELSE 1 END, id DESC",
      limit: 1,
    );
    final now = nowIso();
    // Sanitized: enqueue runs inside the business txn, so a Timestamp in the
    // payload must not abort the local write with `Instance of 'Timestamp'`.
    final encoded = SyncCodec.encodeMap(payload);
    if (existing.isEmpty) {
      await txn.insert('sync_queue', {
        'entity_type': entityType,
        'entity_id': entityId,
        'local_ref': localRef,
        'operation': operation,
        'payload': encoded,
        'owner_uid': QueueEntry.payloadOwner(entityType, operation, payload),
        'base_version': baseVersion,
        'created_at': now,
        'updated_at': now,
        'retry_count': 0,
        'next_attempt_at': null,
        'status': 'pending',
        'last_error': null,
        'revision': 0,
      });
      _notifyEnqueued();
      return;
    }
    final row = existing.first;
    // Editing a parked record supersedes its old conflict, not its new edit.
    // Reuse the same queue identity so late responses keep their revision guard.
    await txn.update(
      'sync_conflicts',
      {'resolution': 'superseded', 'resolved_at': now},
      where: 'entity_type = ? AND entity_id = ? AND resolution IS NULL',
      whereArgs: [entityType, entityId],
    );
    await txn.delete(
      'sync_queue',
      where:
          "entity_type = ? AND entity_id = ? AND id <> ? AND status IN ('conflict','failed')",
      whereArgs: [entityType, entityId, row['id']],
    );
    final mergedOperation = _mergeOperations('${row['operation']}', operation);
    await txn.update(
      'sync_queue',
      {
        'operation': mergedOperation,
        'payload': encoded,
        'owner_uid': QueueEntry.payloadOwner(entityType, operation, payload),
        'base_version': maxOf(
          baseVersion,
          (row['base_version'] as num?)?.toInt() ?? 0,
        ),
        'local_ref': localRef ?? row['local_ref'],
        'updated_at': now,
        'status': 'pending',
        'next_attempt_at': null,
        'last_error': null,
        'retry_count': 0,
        // Supersedes any settlement still in flight for the previous claim.
        'revision': ((row['revision'] as num?)?.toInt() ?? 0) + 1,
      },
      where: 'id = ?',
      whereArgs: [row['id']],
    );
    _notifyEnqueued();
  }

  static int maxOf(int a, int b) => a > b ? a : b;

  /// `create` beats `update`; `tombstone` beats everything.
  static String _mergeOperations(String current, String next) {
    if (current == 'tombstone' || next == 'tombstone') return 'tombstone';
    if (current == 'create' || next == 'create') return 'create';
    return 'update';
  }

  /// Take up to [limit] ready rows, marking them `in_flight` (single-flight).
  ///
  /// Each claim bumps `revision` and returns the bump it wrote, so the
  /// settlement that follows only lands while the row is untouched (see
  /// [QueueEntry.revision]).
  Future<List<QueueEntry>> claim({
    int limit = 400,
    String? uid,
    void Function()? checkCurrent,
  }) async {
    return _withDb(
      'queue.claim',
      (db) => tracedTransaction<List<QueueEntry>>(db, 'queue.claim', (
        txn,
      ) async {
        checkCurrent?.call();
        if (uid != null) {
          if (uid.isEmpty) return [];
          // Bounded lazy migration: explicit historical actors are retained,
          // never replaced with whichever account happened to sign in next.
          final legacy = await txn.query(
            'sync_queue',
            where: "owner_uid = ''",
            orderBy: 'id ASC',
            limit: 400,
          );
          for (final row in legacy) {
            checkCurrent?.call();
            final decoded =
                jsonDecode('${row['payload']}') as Map<String, dynamic>;
            await txn.update(
              'sync_queue',
              {
                'owner_uid': QueueEntry.payloadOwner(
                  '${row['entity_type']}',
                  '${row['operation']}',
                  decoded,
                ),
              },
              where: "id = ? AND owner_uid = ''",
              whereArgs: [row['id']],
            );
          }
        }
        final rows = await txn.query(
          'sync_queue',
          where:
              "status = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= ?)"
              "${uid == null ? '' : ' AND (owner_uid = ? OR owner_uid IS NULL)'}",
          whereArgs: [nowIso(), ?uid],
          orderBy: 'id ASC',
          limit: limit,
        );
        final claimed = <QueueEntry>[];
        for (final row in rows) {
          checkCurrent?.call();
          final id = (row['id'] as num).toInt();
          final revision = ((row['revision'] as num?)?.toInt() ?? 0) + 1;
          final updated = await txn.update(
            'sync_queue',
            {
              'status': 'in_flight',
              'updated_at': nowIso(),
              'revision': revision,
            },
            where: "id = ? AND status = 'pending'",
            whereArgs: [id],
          );
          if (updated > 0) {
            claimed.add(QueueEntry.fromRow(row).withRevision(revision));
          }
        }
        checkCurrent?.call();
        return claimed;
      }),
    );
  }

  /// Returns every `in_flight` row to `pending` and returns how many were
  /// recovered.
  ///
  /// `in_flight` is written in exactly one place — [claim] — and nothing else in
  /// the repository moves a row back to `pending`. So any process death between
  /// the claim and the settlement (an app kill, an OS kill, or an org
  /// switch/restore that closes the database mid-batch) strands the row
  /// permanently. The consequences are all silent:
  ///
  ///   * `countPending`/`countBadge` count `in_flight`, so the badge shows a
  ///     pending count that never drains;
  ///   * the Sync screen's "needs attention" list filters to `failed`/`conflict`,
  ///     so a stranded row cannot be retried from the UI either;
  ///   * [reconcileAfterRestore] was the only consumer, and it runs only after a
  ///     restore.
  ///
  /// `retry_count` is deliberately preserved rather than reset: a push that
  /// crashes the process every attempt keeps climbing the backoff ladder
  /// instead of being granted an infinite series of fresh first attempts.
  /// It never parks for a manual tap — transient work retries forever.
  Future<int> recoverStalled({void Function()? checkCurrent}) async {
    return _withDb('queue.recoverStalled', (db) async {
      return tracedTransaction(db, 'queue.recoverStalled', (txn) async {
        checkCurrent?.call();
        final rows = await txn.query(
          'sync_queue',
          columns: ['id', 'retry_count', 'revision'],
          where: "status = 'in_flight'",
        );
        final now = nowIso();
        var recovered = 0;
        for (final row in rows) {
          checkCurrent?.call();
          // Crash recovery preserves the backoff climb: a push that crashes
          // the process every attempt keeps its retry_count (see the note on
          // recoverStalled), it just never parks for a manual tap anymore.
          final attempts = (row['retry_count'] as num?)?.toInt() ?? 0;
          final updated = await txn.update(
            'sync_queue',
            {
              'status': 'pending',
              'next_attempt_at': nowIsoAt(
                DateTime.now().add(backoffDelay(attempts)),
              ),
              'last_error': 'interrupted mid-push',
              'updated_at': now,
              // Bumps past whatever the dead claim captured, so a settlement
              // that somehow survived the crash cannot clobber the requeue.
              'revision': ((row['revision'] as num?)?.toInt() ?? 0) + 1,
            },
            where: "id = ? AND status = 'in_flight'",
            whereArgs: [(row['id'] as num).toInt()],
          );
          if (updated > 0) recovered++;
        }
        checkCurrent?.call();
        return recovered;
      });
    });
  }

  /// Push succeeded: the row is deleted and the local row is marked `synced`
  /// with the new remote version.
  Future<void> markDone(
    QueueEntry entry, {
    required int remoteVersion,
    DatabaseExecutor? executor,
  }) async {
    if (executor != null) {
      await _markDone(executor, entry, remoteVersion);
      return;
    }
    await tracedTransaction(
      await _db,
      'queue.markDone',
      (txn) => _markDone(txn, entry, remoteVersion),
    );
  }

  /// Reconsider old transport denials once after installing the corrected
  /// envelope protocol. This does not grant permission: the local guard and
  /// server rules still evaluate every retry. Genuine denials park again.
  Future<int> recoverEnvelopeUpgrade({
    void Function()? checkCurrent,
  }) async => _withDb(
    'queue.envelopeUpgrade',
    (db) => tracedTransaction(db, 'queue.envelopeUpgrade', (txn) async {
      checkCurrent?.call();
      const marker = 'remote_envelope_policy_v2';
      final done = await txn.query(
        'sync_metadata',
        columns: const ['value'],
        where: 'key = ?',
        whereArgs: [marker],
        limit: 1,
      );
      if (done.isNotEmpty) return 0;
      final count = await txn.rawUpdate(
        "UPDATE sync_queue SET status='pending', retry_count=0, next_attempt_at=NULL, "
        "last_error=NULL, updated_at=?, revision=revision+1 "
        "WHERE status='conflict' AND operation<>'tombstone' "
        "AND last_error LIKE '%Missing or insufficient permissions%'",
        [nowIso()],
      );
      await txn.insert('sync_metadata', {'key': marker, 'value': '1'});
      checkCurrent?.call();
      return count;
    }),
  );

  /// [markDone] on an existing transaction.
  ///
  /// Guarded by the claimed [QueueEntry.revision]: if the entity was re-edited
  /// (its queue row re-`enqueue`d, which bumps the revision) while this push was
  /// in flight, the settlement matches nothing and the newer `pending` row is
  /// left intact - the fix for the lost-update race.
  Future<void> _markDone(
    DatabaseExecutor txn,
    QueueEntry entry,
    int remoteVersion,
  ) async {
    final deleted = await txn.delete(
      'sync_queue',
      where: 'id = ? AND revision = ?',
      whereArgs: [entry.id, entry.revision],
    );
    if (deleted == 0) {
      await _acknowledgePredecessor(txn, entry, remoteVersion);
      return;
    }
    final entity = entry.entity;
    if (entity == null) return;
    await txn.update(
      entity.localTable,
      {
        'remote_version': remoteVersion,
        'remote_synced_at': nowIso(),
        'sync_state': 'synced',
        if (!entity.appendOnly &&
            !const {
              'qc_templates',
              'qc_inspections',
            }.contains(entity.localTable))
          'version': remoteVersion,
      },
      where: '${entity.pkColumn} = ?',
      whereArgs: [entry.localRef],
    );
    await txn.update(
      'sync_conflicts',
      {'resolution': 'synced', 'resolved_at': nowIso()},
      where:
          "entity_type=? AND entity_id=? AND direction='push_rejected' AND resolution IS NULL",
      whereArgs: [entry.entityType, entry.entityId],
    );
  }

  /// The old payload reached the server while a newer local edit was staged.
  /// Keep that edit queued, but advance its known server base. Otherwise the
  /// next pull/retry can mistake our own predecessor for a competing edit and
  /// overwrite the newer values with the server's older payload.
  Future<void> _acknowledgePredecessor(
    DatabaseExecutor txn,
    QueueEntry entry,
    int remoteVersion,
  ) async {
    final entity = entry.entity;
    if (entity == null || entity.appendOnly || remoteVersion <= 0) return;
    final rows = await txn.query(
      'sync_queue',
      where:
          "id = ? AND entity_type = ? AND entity_id = ? AND status = 'pending' AND revision > ?",
      whereArgs: [entry.id, entry.entityType, entry.entityId, entry.revision],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final pending = rows.single;
    final base = (pending['base_version'] as num?)?.toInt() ?? 0;
    if (base > remoteVersion) return;
    await txn.update(
      'sync_queue',
      {'base_version': remoteVersion, 'updated_at': nowIso()},
      where: 'id = ? AND revision = ?',
      whereArgs: [entry.id, pending['revision']],
    );
    if (entry.localRef == null || pending['local_ref'] != entry.localRef) {
      return;
    }
    await txn.rawUpdate(
      'UPDATE ${entity.localTable} SET remote_version = MAX(COALESCE(remote_version, 0), ?), '
      "sync_state = 'queued' WHERE ${entity.pkColumn} = ?",
      [remoteVersion, entry.localRef],
    );
  }

  Future<bool> isCurrentClaim(DatabaseExecutor txn, QueueEntry entry) async =>
      (await txn.query(
        'sync_queue',
        columns: ['id'],
        where: "id = ? AND revision = ? AND status = 'in_flight'",
        whereArgs: [entry.id, entry.revision],
        limit: 1,
      )).isNotEmpty;

  /// Applies many push outcomes in a single transaction.
  ///
  /// The per-entry [markDone]/[markRetry]/[markConflict] methods each open
  /// their own transaction, so a 400-entry batch paid 400 fsyncs. A push
  /// worker runs a whole batch at once and only needs the results to be
  /// visible together, so the batch shares one commit.
  Future<void> settleAll(
    List<QueueSettlement> settlements, {
    bool Function()? isCurrent,
    void Function()? checkCurrent,
  }) async {
    if (settlements.isEmpty) return;
    await _withDb('queue.settleAll', (db) async {
      await tracedTransaction(db, 'queue.settleAll', (txn) async {
        if (isCurrent != null && !isCurrent()) return;
        checkCurrent?.call();
        for (final settlement in settlements) {
          checkCurrent?.call();
          final entry = settlement.entry;
          switch (settlement.kind) {
            case QueueOutcome.done:
              await _markDone(txn, entry, settlement.remoteVersion ?? 0);
            case QueueOutcome.retry:
              await _markRetry(txn, entry, settlement.error ?? 'unknown error');
            case QueueOutcome.conflict:
              await _markConflict(
                txn,
                entry,
                direction: settlement.direction ?? 'push_rejected',
                remotePayload: settlement.remotePayload,
                error: settlement.error,
              );
          }
        }
        checkCurrent?.call();
      });
    });
  }

  /// Transient failure → exponential backoff (`min(5s * 2^n, 15min) ± 20%`),
  /// retried forever.
  ///
  /// A push that can never succeed on its own (denied, oversized, unknown
  /// entity) never reaches this path — those become manual `conflict` rows.
  /// Everything landing here is transient by construction (offline,
  /// throttled, 5xx), so parking it for a manual "retry" tap after N attempts
  /// only guaranteed that every network blip needed a human. The `failed`
  /// status survives for rows written by older versions; nothing new creates
  /// it, and `retryBlocked`/`retryRow` still drain it.
  Future<void> markRetry(QueueEntry entry, String error) async {
    await tracedTransaction(
      await _db,
      'queue.markRetry',
      (txn) => _markRetry(txn, entry, error),
    );
  }

  /// [markRetry] on an existing transaction.
  ///
  /// Revision-guarded: a fresher edit that superseded this claim owns the row
  /// now, so this backoff must not overwrite it (or stamp the local row back to
  /// `queued` on the stale entry's behalf).
  Future<void> _markRetry(
    DatabaseExecutor txn,
    QueueEntry entry,
    String error,
  ) async {
    final attempts = entry.retryCount + 1;
    final updated = await txn.update(
      'sync_queue',
      {
        'status': 'pending',
        'retry_count': attempts,
        'next_attempt_at': nowIsoAt(
          DateTime.now().add(backoffDelay(attempts - 1)),
        ),
        'last_error': error,
        'updated_at': nowIso(),
        'revision': entry.revision + 1,
      },
      where: 'id = ? AND revision = ?',
      whereArgs: [entry.id, entry.revision],
    );
    if (updated == 0) return;
    final entity = entry.entity;
    if (entity != null && entry.localRef != null) {
      await txn.update(
        entity.localTable,
        {'sync_state': 'queued'},
        where: '${entity.pkColumn} = ?',
        whereArgs: [entry.localRef],
      );
    }
  }

  /// Deterministic-with-jitter backoff; [attempt] is 0-based.
  static Duration backoffDelay(int attempt) {
    final seconds = 5 * (1 << attempt.clamp(0, 20));
    final capped = seconds > 900 ? 900 : seconds;
    // ±20% deterministic jitter (no Random dependency: reproducible in tests).
    final jitter = (capped * 0.2 * ((attempt % 5) - 2) / 2).round();
    return Duration(seconds: capped + jitter);
  }

  /// Permission-denied / version conflict / oversized payload: never retried
  /// automatically, a `sync_conflicts` row is written for the Sync screen.
  Future<void> markConflict(
    QueueEntry entry, {
    required String direction,
    String? remotePayload,
    String? error,
  }) async {
    await tracedTransaction(
      await _db,
      'queue.markConflict',
      (txn) => _markConflict(
        txn,
        entry,
        direction: direction,
        remotePayload: remotePayload,
        error: error,
      ),
    );
  }

  /// [markConflict] on an existing transaction.
  ///
  /// Revision-guarded: if the entity was re-edited while the push that produced
  /// this conflict was in flight, the stale conflict is **not** parked - the
  /// newer `pending` row keeps draining and the user is never asked to resolve a
  /// conflict against a payload that no longer reflects the local row.
  Future<void> _markConflict(
    DatabaseExecutor txn,
    QueueEntry entry, {
    required String direction,
    String? remotePayload,
    String? error,
  }) async {
    final updated = await txn.update(
      'sync_queue',
      {
        'status': 'conflict',
        'last_error': error,
        'updated_at': nowIso(),
        'next_attempt_at': null,
        'revision': entry.revision + 1,
      },
      where: 'id = ? AND revision = ?',
      whereArgs: [entry.id, entry.revision],
    );
    if (updated == 0) return;
    await txn.insert('sync_conflicts', {
      'entity_type': entry.entityType,
      'entity_id': entry.entityId,
      'direction': direction,
      'local_payload': SyncCodec.encodeMap(entry.payload),
      'remote_payload': remotePayload,
      'detected_at': nowIso(),
      'resolution': null,
      'resolved_at': null,
    });
    final entity = entry.entity;
    if (entity != null && entry.localRef != null) {
      await txn.update(
        entity.localTable,
        {'sync_state': 'conflict'},
        where: '${entity.pkColumn} = ?',
        whereArgs: [entry.localRef],
      );
    }
  }

  /// Unresolved conflicts for the Sync screen.
  Future<List<Map<String, Object?>>> listConflicts({int limit = 100}) async =>
      (await _db).query(
        'sync_conflicts',
        where: 'resolution IS NULL',
        orderBy: 'detected_at DESC',
        limit: limit,
      );

  /// `keep_local` → the local row goes back to the queue with the remote
  /// version it lost against; `keep_remote` → the remote document is applied
  /// locally and the queue row disappears.
  Future<void> resolveConflict(
    int conflictId, {
    required String resolution,
    required Future<void> Function(Map<String, Object?> conflict) onKeepLocal,
    Future<void> Function(Map<String, Object?> conflict, String remoteJson)?
    onKeepRemote,
  }) async {
    if (resolution != 'keep_local' && resolution != 'keep_remote') {
      throw ArgumentError.value(resolution, 'resolution');
    }
    final generation = dbHelper.connectionGeneration;
    final conflictDb = await _db;
    final conflicts = await conflictDb.query(
      'sync_conflicts',
      where: 'id = ?',
      whereArgs: [conflictId],
      limit: 1,
    );
    if (conflicts.isEmpty) return;
    final conflict = conflicts.first;
    if (conflict['resolution'] != null) return;
    if (resolution == 'keep_local') {
      await onKeepLocal(conflict);
    } else if (onKeepRemote != null) {
      await onKeepRemote(conflict, '${conflict['remote_payload']}');
    }
    // The parked row must not survive the decision: `keep_local` already
    // re-queued the payload as a fresh `pending` row and `keep_remote` means
    // there is nothing left to push. Leaving it in `conflict` would keep the
    // blocked counter up forever and show the entity twice in the queue. The
    // full history stays in `sync_conflicts`.
    if (dbHelper.connectionGeneration != generation) {
      throw StateError('Database changed during conflict resolution');
    }
    await tracedTransaction(conflictDb, 'queue.finishResolution', (txn) async {
      final remaining = await txn.query(
        'sync_conflicts',
        where: 'id = ? AND resolution IS NULL',
        whereArgs: [conflictId],
      );
      if (remaining.isEmpty) return; // Resolver already committed atomically.
      await assertCurrentConflict(txn, conflict);
      await txn.delete(
        'sync_queue',
        where: "status = 'conflict' AND entity_type = ? AND entity_id = ?",
        whereArgs: [conflict['entity_type'], conflict['entity_id']],
      );
      await txn.update(
        'sync_conflicts',
        {'resolution': resolution, 'resolved_at': nowIso()},
        where: 'id = ?',
        whereArgs: [conflictId],
      );
    });
  }

  /// Revalidate inside the same transaction that applies a manual choice.
  /// A screen can stay open while another edit supersedes its old conflict.
  Future<void> assertCurrentConflict(
    DatabaseExecutor txn,
    Map<String, Object?> conflict,
  ) async {
    final open = await txn.query(
      'sync_conflicts',
      columns: ['id'],
      where: 'id = ? AND resolution IS NULL',
      whereArgs: [conflict['id']],
      limit: 1,
    );
    if (open.isEmpty) {
      throw StateError('Conflict was already superseded or resolved');
    }
    final newer = await txn.query(
      'sync_queue',
      columns: ['id'],
      where: "entity_type = ? AND entity_id = ? AND status <> 'conflict'",
      whereArgs: [conflict['entity_type'], conflict['entity_id']],
      limit: 1,
    );
    if (newer.isNotEmpty) throw StateError('Conflict has a newer local edit');
  }

  /// Manual retry from the Sync screen: `failed`/`conflict` → `pending`.
  Future<int> retryBlocked({String? entityType}) async {
    final where = entityType == null
        ? "status IN ('failed','conflict')"
        : "status IN ('failed','conflict') AND entity_type = ?";
    final args = entityType == null ? null : [entityType];
    return (await _db).rawUpdate(
      "UPDATE sync_queue SET status = 'pending', retry_count = 0, next_attempt_at = NULL, "
      "last_error = NULL, updated_at = ?, revision = revision + 1 WHERE $where",
      [nowIso(), ...?args],
    );
  }

  /// Manual retry of a single row from the Sync screen: `failed`/`conflict` →
  /// `pending`, with the backoff counter cleared.
  Future<int> retryRow(int id) async {
    return (await _db).rawUpdate(
      "UPDATE sync_queue SET status = 'pending', retry_count = 0, "
      "next_attempt_at = NULL, last_error = NULL, updated_at = ?, "
      "revision = revision + 1 WHERE id = ?",
      [nowIso(), id],
    );
  }

  /// Drop queue rows whose local row disappeared (e.g. a restore that did not
  /// contain it). Tombstones are never purged: they must reach the server.
  Future<int> purgeSolved() async {
    final db = await _db;
    final rows = await db.query(
      'sync_queue',
      columns: ['id', 'entity_type'],
      where:
          "status IN ('pending','in_flight') AND local_ref IS NOT NULL AND operation != 'tombstone'",
    );
    final idsByEntity = <String, List<int>>{};
    for (final row in rows) {
      final entity = SyncEntity.byType('${row['entity_type']}');
      if (entity == null) continue;
      idsByEntity
          .putIfAbsent(entity.type, () => <int>[])
          .add((row['id'] as num).toInt());
    }
    var removed = 0;
    for (final entry in idsByEntity.entries) {
      final entity = SyncEntity.byType(entry.key);
      if (entity == null) continue;
      final orphaned = await db.rawQuery('''
        SELECT q.id
        FROM sync_queue q
        LEFT JOIN ${entity.localTable} local ON local.${entity.pkColumn} = q.local_ref
        WHERE q.id IN (${List.filled(entry.value.length, '?').join(',')})
          AND local.id IS NULL
      ''', entry.value);
      if (orphaned.isEmpty) continue;
      removed += await db.delete(
        'sync_queue',
        where: 'id IN (${List.filled(orphaned.length, '?').join(',')})',
        whereArgs: [for (final row in orphaned) row['id']],
      );
    }
    return removed;
  }

  Future<int> countPending() async =>
      _count("status IN ('pending','in_flight')");

  Future<int> countBlocked() async => _count("status IN ('failed','conflict')");

  /// Pending, blocked and unresolved-conflict counts in **one** round trip.
  ///
  /// The badge used to add these up from `countPending`, `countBlocked` and
  /// `listConflicts(limit: 1000)`. On the FFI factory each of those is a separate
  /// message to the one shared background isolate, and a root-handle call blocks
  /// every other root-handle call on the connection's non-reentrant `_rawLock`
  /// while it waits - so a badge that was three cheap reads became three
  /// opportunities to sit in that queue. The conflict count was the worst of
  /// them: it loaded whole rows just to call `.length`.
  Future<SyncQueueCounts> countBadge() =>
      _withDb('queue.countBadge', (db) async {
        // One statement, four scalar subqueries: a single message to the shared
        // background isolate instead of four, and nothing left holding the
        // connection lock in between.
        final rows = await db.rawQuery('''
          SELECT
            (SELECT COUNT(*) FROM sync_queue
              WHERE status IN ('pending','in_flight')) AS pending,
            (SELECT COUNT(*) FROM sync_queue
              WHERE status IN ('failed','conflict')) AS blocked,
            (SELECT COUNT(*) FROM sync_queue
              WHERE status = 'failed') AS failed,
            (SELECT COUNT(*) FROM sync_conflicts
              WHERE resolution IS NULL
                 OR resolution NOT IN ('keep_local','keep_remote','ignored','synced')) AS conflicts
        ''');
        final row = rows.first;
        return SyncQueueCounts(
          pending: (row['pending'] as num?)?.toInt() ?? 0,
          blocked: (row['blocked'] as num?)?.toInt() ?? 0,
          failed: (row['failed'] as num?)?.toInt() ?? 0,
          conflicts: (row['conflicts'] as num?)?.toInt() ?? 0,
        );
      });

  Future<int> _count(String where) async => _withDb('queue.count', (db) async {
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM sync_queue WHERE $where',
    );
    return (rows.first['c'] as num).toInt();
  });

  /// Unresolved conflicts, counted in SQL.
  ///
  /// Replaces `listConflicts(limit: 1000).length`, which pulled a thousand full
  /// conflict rows across the isolate boundary to produce an integer.
  Future<int> countConflicts() => _withDb('queue.countConflicts', (db) async {
    final rows = await db.rawQuery(
      "SELECT COUNT(*) AS c FROM sync_conflicts WHERE resolution IS NULL "
      "OR resolution NOT IN ('keep_local','keep_remote','ignored','synced')",
    );
    return (rows.first['c'] as num).toInt();
  });

  /// The live queue for the Sync screen: blocked rows first, then the pending
  /// ones. [onlyBlocked] is the "needs attention" view.
  Future<List<Map<String, Object?>>> listQueue({
    int limit = 200,
    bool onlyBlocked = false,
  }) async => (await _db).query(
    'sync_queue',
    where: onlyBlocked ? "status IN ('failed','conflict')" : null,
    orderBy:
        "CASE status WHEN 'failed' THEN 0 WHEN 'conflict' THEN 1 "
        "WHEN 'pending' THEN 2 WHEN 'in_flight' THEN 3 ELSE 4 END, id ASC",
    limit: limit,
  );
}

/// The three numbers the sync badge shows, read in one round trip.
class SyncQueueCounts {
  const SyncQueueCounts({
    required this.pending,
    required this.blocked,
    required this.conflicts,
    this.failed = 0,
  });

  final int pending;
  final int blocked;
  final int conflicts;
  final int failed;

  @override
  String toString() =>
      'SyncQueueCounts(pending: $pending, blocked: $blocked, '
      'failed: $failed, conflicts: $conflicts)';
}
