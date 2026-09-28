import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'entity_registry.dart';

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
        localRef: (row['local_ref'] as num?)?.toInt(),
        lastError: row['last_error'] as String?,
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
  })  : kind = QueueOutcome.conflict,
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
  Future<T> _withDb<T>(String label, Future<T> Function(Database db) action) async {
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
      where: "entity_type = ? AND entity_id = ? AND status IN ('pending','in_flight','blocked')",
      whereArgs: [entityType, entityId],
      limit: 1,
    );
    final now = nowIso();
    final encoded = jsonEncode(payload);
    if (existing.isEmpty) {
      await txn.insert('sync_queue', {
        'entity_type': entityType,
        'entity_id': entityId,
        'local_ref': localRef,
        'operation': operation,
        'payload': encoded,
        'base_version': baseVersion,
        'created_at': now,
        'updated_at': now,
        'retry_count': 0,
        'next_attempt_at': null,
        'status': 'pending',
        'last_error': null,
      });
      return;
    }
    final row = existing.first;
    final mergedOperation = _mergeOperations('${row['operation']}', operation);
    await txn.update(
      'sync_queue',
      {
        'operation': mergedOperation,
        'payload': encoded,
        'base_version': maxOf(baseVersion, (row['base_version'] as num?)?.toInt() ?? 0),
        'local_ref': localRef ?? row['local_ref'],
        'updated_at': now,
        'status': 'pending',
        'next_attempt_at': null,
        'last_error': null,
        'retry_count': 0,
      },
      where: 'id = ?',
      whereArgs: [row['id']],
    );
  }

  static int maxOf(int a, int b) => a > b ? a : b;

  /// `create` beats `update`; `tombstone` beats everything.
  static String _mergeOperations(String current, String next) {
    if (current == 'tombstone' || next == 'tombstone') return 'tombstone';
    if (current == 'create' || next == 'create') return 'create';
    return 'update';
  }

  /// Take up to [limit] ready rows, marking them `in_flight` (single-flight).
  Future<List<QueueEntry>> claim({int limit = 400}) async {
    return (await _db).transaction<List<QueueEntry>>((txn) async {
      final rows = await txn.query(
        'sync_queue',
        where: "status = 'pending' AND (next_attempt_at IS NULL OR next_attempt_at <= ?)",
        whereArgs: [nowIso()],
        orderBy: 'id ASC',
        limit: limit,
      );
      final claimed = <QueueEntry>[];
      for (final row in rows) {
        final id = (row['id'] as num).toInt();
        final updated = await txn.update(
          'sync_queue',
          {
            'status': 'in_flight',
            'updated_at': nowIso(),
          },
          where: "id = ? AND status = 'pending'",
          whereArgs: [id],
        );
        if (updated > 0) claimed.add(QueueEntry.fromRow(row));
      }
      return claimed;
    });
  }


  /// Push succeeded: the row is deleted and the local row is marked `synced`
  /// with the new remote version.
  Future<void> markDone(QueueEntry entry, {required int remoteVersion}) async {
    await tracedTransaction(
        await _db, 'queue.markDone', (txn) => _markDone(txn, entry, remoteVersion));
  }

  /// [markDone] on an existing transaction.
  Future<void> _markDone(
    DatabaseExecutor txn,
    QueueEntry entry,
    int remoteVersion,
  ) async {
    await txn.delete('sync_queue', where: 'id = ?', whereArgs: [entry.id]);
    final entity = entry.entity;
    if (entity == null) return;
    await txn.update(
      entity.localTable,
      {
        'remote_version': remoteVersion,
        'remote_synced_at': nowIso(),
        'sync_state': 'synced',
      },
      where: 'id = ?',
      whereArgs: [entry.localRef],
    );
  }

  /// Applies many push outcomes in a single transaction.
  ///
  /// The per-entry [markDone]/[markRetry]/[markConflict] methods each open
  /// their own transaction, so a 400-entry batch paid 400 fsyncs. A push
  /// worker runs a whole batch at once and only needs the results to be
  /// visible together, so the batch shares one commit.
  Future<void> settleAll(List<QueueSettlement> settlements) async {
    if (settlements.isEmpty) return;
    await tracedTransaction(await _db, 'queue.settleAll', (txn) async {
      for (final settlement in settlements) {
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
    });
  }

  /// Transient failure → exponential backoff (`min(5s * 2^n, 15min) ± 20%`).
  ///
  /// After [maxRetries] the row becomes `failed` and waits for a manual retry
  /// from the Sync screen (plan §9.5).
  Future<void> markRetry(QueueEntry entry, String error) async {
    await tracedTransaction(
        await _db, 'queue.markRetry', (txn) => _markRetry(txn, entry, error));
  }

  /// [markRetry] on an existing transaction.
  Future<void> _markRetry(
    DatabaseExecutor txn,
    QueueEntry entry,
    String error,
  ) async {
    final attempts = entry.retryCount + 1;
    final exhausted = attempts >= maxRetries;
    await txn.update(
      'sync_queue',
      {
        'status': exhausted ? 'failed' : 'pending',
        'retry_count': attempts,
        'next_attempt_at': exhausted
            ? null
            : nowIsoAt(DateTime.now().add(backoffDelay(attempts - 1))),
        'last_error': error,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [entry.id],
    );
    final entity = entry.entity;
    if (entity != null && entry.localRef != null) {
      await txn.update(
        entity.localTable,
        {'sync_state': exhausted ? 'conflict' : 'queued'},
        where: 'id = ?',
        whereArgs: [entry.localRef],
      );
    }
  }

  static const int maxRetries = 20;

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
    await tracedTransaction(await _db, 'queue.markConflict',
        (txn) => _markConflict(txn, entry,
            direction: direction, remotePayload: remotePayload, error: error));
  }

  /// [markConflict] on an existing transaction.
  Future<void> _markConflict(
    DatabaseExecutor txn,
    QueueEntry entry, {
    required String direction,
    String? remotePayload,
    String? error,
  }) async {
    await txn.update(
      'sync_queue',
      {
        'status': 'conflict',
        'last_error': error,
        'updated_at': nowIso(),
        'next_attempt_at': null,
      },
      where: 'id = ?',
      whereArgs: [entry.id],
    );
    await txn.insert('sync_conflicts', {
      'entity_type': entry.entityType,
      'entity_id': entry.entityId,
      'direction': direction,
      'local_payload': jsonEncode(entry.payload),
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
        where: 'id = ?',
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
    Future<void> Function(Map<String, Object?> conflict, String remoteJson)? onKeepRemote,
  }) async {
    if (resolution != 'keep_local' && resolution != 'keep_remote') {
      throw ArgumentError.value(resolution, 'resolution');
    }
    final conflicts = await (await _db).query(
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
    final db = await _db;
    await db.delete(
      'sync_queue',
      where: "status = 'conflict' AND entity_type = ? AND entity_id = ?",
      whereArgs: [conflict['entity_type'], conflict['entity_id']],
    );
    await db.update(
      'sync_conflicts',
      {
        'resolution': resolution,
        'resolved_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [conflictId],
    );
  }

  /// Manual retry from the Sync screen: `failed`/`conflict` → `pending`.
  Future<int> retryBlocked({String? entityType}) async {
    final where = entityType == null
        ? "status IN ('failed','conflict')"
        : "status IN ('failed','conflict') AND entity_type = ?";
    final args = entityType == null ? null : [entityType];
    return (await _db).rawUpdate(
      "UPDATE sync_queue SET status = 'pending', retry_count = 0, next_attempt_at = NULL, "
      "last_error = NULL, updated_at = ? WHERE $where",
      [nowIso(), ...?args],
    );
  }

  /// Manual retry of a single row from the Sync screen: `failed`/`conflict` →
  /// `pending`, with the backoff counter cleared.
  Future<int> retryRow(int id) async {
    return (await _db).update(
      'sync_queue',
      {
        'status': 'pending',
        'retry_count': 0,
        'next_attempt_at': null,
        'last_error': null,
        'updated_at': nowIso(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Drop queue rows whose local row disappeared (e.g. a restore that did not
  /// contain it). Tombstones are never purged: they must reach the server.
  Future<int> purgeSolved() async {
    final rows = await (await _db).query(
      'sync_queue',
      where: "status IN ('pending','in_flight') AND local_ref IS NOT NULL AND operation != 'tombstone'",
    );
    var removed = 0;
    for (final row in rows) {
      final entity = SyncEntity.byType('${row['entity_type']}');
      if (entity == null) continue;
      final local = await (await _db).query(
        entity.localTable,
        where: 'id = ?',
        whereArgs: [row['local_ref']],
        limit: 1,
      );
      if (local.isEmpty) {
        removed += await (await _db).delete('sync_queue', where: 'id = ?', whereArgs: [row['id']]);
      }
    }
    return removed;
  }

  Future<int> countPending() async => _count("status IN ('pending','in_flight')");

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
  Future<SyncQueueCounts> countBadge() => _withDb('queue.countBadge', (db) async {
        // One statement, three scalar subqueries: a single message to the shared
        // background isolate instead of four, and nothing left holding the
        // connection lock in between.
        final rows = await db.rawQuery('''
          SELECT
            (SELECT COUNT(*) FROM sync_queue
              WHERE status IN ('pending','in_flight')) AS pending,
            (SELECT COUNT(*) FROM sync_queue
              WHERE status IN ('failed','conflict')) AS blocked,
            (SELECT COUNT(*) FROM sync_conflicts
              WHERE resolution IS NULL
                 OR resolution NOT IN ('keep_local','keep_remote')) AS conflicts
        ''');
        final row = rows.first;
        return SyncQueueCounts(
          pending: (row['pending'] as num?)?.toInt() ?? 0,
          blocked: (row['blocked'] as num?)?.toInt() ?? 0,
          conflicts: (row['conflicts'] as num?)?.toInt() ?? 0,
        );
      });

  Future<int> _count(String where) async => _withDb('queue.count', (db) async {
        final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM sync_queue WHERE $where');
        return (rows.first['c'] as num).toInt();
      });

  /// Unresolved conflicts, counted in SQL.
  ///
  /// Replaces `listConflicts(limit: 1000).length`, which pulled a thousand full
  /// conflict rows across the isolate boundary to produce an integer.
  Future<int> countConflicts() => _withDb('queue.countConflicts', (db) async {
        final rows = await db.rawQuery(
          "SELECT COUNT(*) AS c FROM sync_conflicts WHERE resolution IS NULL "
          "OR resolution NOT IN ('keep_local','keep_remote')",
        );
        return (rows.first['c'] as num).toInt();
      });

  /// The live queue for the Sync screen: blocked rows first, then the pending
  /// ones. [onlyBlocked] is the "needs attention" view.
  Future<List<Map<String, Object?>>> listQueue({int limit = 200, bool onlyBlocked = false}) async =>
      (await _db).query(
        'sync_queue',
        where: onlyBlocked ? "status IN ('failed','conflict')" : null,
        orderBy: "CASE status WHEN 'failed' THEN 0 WHEN 'conflict' THEN 1 "
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
  });

  final int pending;
  final int blocked;
  final int conflicts;

  @override
  String toString() => 'SyncQueueCounts(pending: $pending, blocked: $blocked, '
      'conflicts: $conflicts)';
}