import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../auth/app_session.dart';
import '../auth/session_source.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'conflict_resolver.dart';
import 'entity_registry.dart';
import 'remote/remote_data_source.dart';
import 'sync_metadata.dart';
import 'sync_queue.dart';

/// Outcome of one `pull_worker` pass.
class PullReport {
  const PullReport({
    required this.applied,
    required this.skipped,
    required this.pushedBack,
    required this.hasMore,
    this.failed = 0,
    this.error,
  });

  final int applied;
  final int skipped;
  final int pushedBack;
  final bool hasMore;

  /// Documents the local schema refused. They are counted and reported, never
  /// thrown: see [PullWorker._applyPage].
  final int failed;
  final String? error;

  static const PullReport empty = PullReport(
    applied: 0,
    skipped: 0,
    pushedBack: 0,
    hasMore: false,
  );
}

/// Downloads remote changes page by page and applies them locally
/// (plan §9.3). No Firestore-side filtering/search is ever used — this is a
/// pure `orderBy('updatedAt').orderBy(documentId)` cursor walk.
class PullWorker {
  PullWorker({
    required this.queue,
    required this.metadata,
    required this.remote,
    required this.conflicts,
    SessionSource? source,
    this.pageSize = 300,
    this.maxPagesPerCycle = 5,
    List<SyncEntity>? entities,
    this.quietPermissionErrors = false,
    this.marksPullTimestamp = true,
  }) : source = source ?? SessionSource.empty(),
       entities = entities ?? syncEntities;
  final SyncQueue queue;
  final SyncMetadata metadata;
  final RemoteDataSource remote;
  final ConflictResolver conflicts;

  SessionSource source;

  /// The entities this pass walks. The normal cycle uses every entry of
  /// `syncEntities`; the audit trail is pulled by its own instance so that a
  /// member without `audit.read` cannot break the data cycle with a
  /// permission-denied on `auditLogs`.
  final List<SyncEntity> entities;

  /// A permission-denied is a *permission*, not a failure: the entry is skipped
  /// and no error is recorded (the badge must not turn red because a viewer is
  /// not allowed to read the audit trail).
  final bool quietPermissionErrors;

  /// Only the main data cycle owns `last_pull_at` (the badge shows it); the
  /// dedicated audit pass must not move the "last synced" marker.
  final bool marksPullTimestamp;

  /// Read live: the session changes on sign-in, sign-out and org switch.
  AppSession get _session => source.session;
  final int pageSize;

  /// 5 × 300 = 1500 documents per cycle (plan §9.8).
  final int maxPagesPerCycle;

  Future<PullReport> runOnce() async {
    if (!remote.isSignedIn) return PullReport.empty;
    final organizationId = _session.organizationId;
    if (organizationId.isEmpty) return PullReport.empty;

    var applied = 0;
    var skipped = 0;
    var pushedBack = 0;
    var failed = 0;
    var hasMore = false;
    String? error;

    for (final entity in entities) {
      for (var page = 0; page < maxPagesPerCycle; page++) {
        final cursor = await metadata.cursor(entity.type);
        late RemotePage result;
        try {
          result = await remote.listSince(
            organizationId: organizationId,
            collection: entity.collection,
            startAtTs: cursor.timestamp,
            startAtId: cursor.documentId,
            limit: pageSize,
          );
        } on Object catch (e) {
          if (quietPermissionErrors && _isPermissionDenied(e)) {
            // Nothing to do for this entity on this device: stop walking it and
            // keep the cursor where it is.
            break;
          }
          error = '$e';
          break;
        }
        if (result.documents.isEmpty) {
          hasMore = hasMore || result.hasMore;
          break;
        }
        // One transaction for the whole page instead of one per document.
        // A page is at most `pageSize` (300) rows, so a single commit is
        // bounded work, and the page either lands completely or not at all --
        // which is what the cursor below assumes when it advances.
        final outcomes = await tracedTransaction(
          await queue.dbHelper.database,
          'pull.applyPage(${entity.type})',
          (txn) => _applyPage(txn, entity, result.documents, organizationId),
        );
        for (final outcome in outcomes) {
          switch (outcome) {
            case _ApplyOutcome.applied:
              applied++;
            case _ApplyOutcome.skipped:
              skipped++;
            case _ApplyOutcome.pushedBack:
              pushedBack++;
            case _ApplyOutcome.failed:
              failed++;
          }
        }
        final last = result.documents.last;
        await metadata.setCursor(
          entity.type,
          PullCursor(last.updatedAt ?? '', last.id),
        );
        if (!result.hasMore) break;
        hasMore = true;
      }
    }

    if (marksPullTimestamp) await metadata.markPull(DateTime.now());
    if (error != null) await metadata.markError(error);
    return PullReport(
      applied: applied,
      skipped: skipped,
      pushedBack: pushedBack,
      hasMore: hasMore,
      failed: failed,
      error: error,
    );
  }

  /// Applies a whole page inside [txn], returning the outcome per document in
  /// the same order. Runs sequentially because sqflite serialises statements on
  /// a single connection anyway, and the per-document `Future` bookkeeping in
  /// [_userIds]/[_columnCache] is keyed on the transaction.
  Future<List<_ApplyOutcome>> _applyPage(
    DatabaseExecutor txn,
    SyncEntity entity,
    List<RemoteDocument> documents,
    String organizationId,
  ) async {
    // A document the local schema cannot hold is contained to itself.
    //
    // `txn` is one transaction for the whole page, so a `NOT NULL` / `CHECK` /
    // `UNIQUE` violation used to roll back every document in the page and
    // surface as a thrown exception from `runOnce` - the sync engine reported
    // a hard error, the cursor never advanced, and the same bad document
    // blocked the cycle forever, silently withholding every healthy change
    // behind it. The page still commits; the offending row is counted as
    // [PullReport.failed] and left for a later version of itself to fix.
    final outcomes = <_ApplyOutcome>[];
    for (final document in documents) {
      try {
        outcomes.add(
          await _applyDocument(txn, entity, document, organizationId),
        );
      } on Object catch (e) {
        // ignore: avoid_print
        print('[sync] pull skipped ${entity.type}/${document.id}: $e');
        outcomes.add(_ApplyOutcome.failed);
      }
    }
    return outcomes;
  }

  Future<_ApplyOutcome> _applyDocument(
    DatabaseExecutor txn,
    SyncEntity entity,
    RemoteDocument document,
    String organizationId,
  ) async {
    {
      // Several entities may share one remote collection (every lab-settings
      // table lives in `labConfig`), so the first question is whether this
      // document is ours at all. Applying another table's document would
      // overwrite an unrelated local row that happens to share the id.
      final accepts = entity.accepts;
      if (accepts != null && !accepts(document)) return _ApplyOutcome.skipped;
      // `localId` first, then the natural key: a document written on another
      // device carries an id that means nothing in this database.
      final localRef = await findLocalRef(
        txn,
        entity,
        document.id,
        document.data,
      );
      final existing = localRef == null
          ? const <Map<String, Object?>>[]
          : await txn.query(
              entity.localTable,
              where: 'id = ?',
              whereArgs: [localRef],
              limit: 1,
            );
      final remoteVersion = document.version;

      if (existing.isEmpty) {
        final row = await _localRow(
          txn,
          entity,
          remoteToLocalRow(
            entity,
            document.data,
            organizationId: organizationId,
          ),
        );
        row['remote_synced_at'] = nowIso();
        row['sync_state'] = 'synced';
        row.removeWhere(
          (key, value) => value == null && _nullableColumns.contains(key),
        );
        await txn.insert(
          entity.localTable,
          _withDefaults(entity, row, await _availableColumns(txn, entity)),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        return _ApplyOutcome.applied;
      }

      final local = existing.first;
      final localVersion = (local['version'] as num?)?.toInt() ?? 0;
      final syncedVersion = (local['remote_version'] as num?)?.toInt() ?? 0;
      final hasLocalEdits =
          (local['sync_state'] == 'queued') ||
          (localVersion > syncedVersion && syncedVersion > 0);

      if (remoteVersion == syncedVersion) {
        return _ApplyOutcome.skipped;
      }
      if (remoteVersion < localVersion && hasLocalEdits) {
        // Local is newer: keep the local edit and push it on top of the remote.
        await txn.update(
          entity.localTable,
          {'sync_state': 'queued'},
          where: 'id = ?',
          whereArgs: [local['id']],
        );
        await queue.enqueue(
          txn,
          entityType: entity.type,
          entityId: entity.docId(local),
          localRef: (local['id'] as num?)?.toInt(),
          operation: local['deleted_at'] == null ? 'update' : 'tombstone',
          payload: buildRemotePayload(
            entity,
            Map<String, Object?>.from(local).cast<String, dynamic>(),
            SyncPayloadContext(
              organizationId: organizationId,
              uid: _session.uid,
              deviceId: _session.deviceId,
              version: syncedVersion,
              versionField: 'version',
            ),
          ),
          baseVersion: syncedVersion,
        );
        return _ApplyOutcome.pushedBack;
      }

      final row = await _localRow(
        txn,
        entity,
        remoteToLocalRow(entity, document.data, organizationId: organizationId),
      );
      row['remote_synced_at'] = nowIso();
      row['sync_state'] = 'synced';
      await txn.update(
        entity.localTable,
        _withDefaults(entity, row, await _availableColumns(txn, entity))
          ..remove('id'),
        where: 'id = ?',
        whereArgs: [local['id']],
      );
      return _ApplyOutcome.applied;
    }
  }

  /// Keeps only the keys that are real columns of [entity].localTable.
  ///
  /// The Firestore envelope is richer than any single local table (it always
  /// carries `organizationId`, `updatedBy`, `deviceId`, `payloadBytes`), and
  /// writing an unknown column would abort the whole transaction. Cached per
  /// table: one `PRAGMA table_info` per table per process.
  ///
  /// The two user-reference columns arrive as Firebase uids and are translated
  /// back to local `users.id` (plan §6.6): an author this device has not
  /// mirrored yet maps to the reserved row `id = 0`.
  Future<Map<String, dynamic>> _localRow(
    DatabaseExecutor txn,
    SyncEntity entity,
    Map<String, dynamic> row,
  ) async {
    final columns = _columnCache.putIfAbsent(
      entity.localTable,
      () => availableColumns(txn, entity.localTable),
    );
    final available = await columns;
    final resolved = <String, dynamic>{
      for (final entry in row.entries)
        if (available.contains(entry.key)) entry.key: entry.value,
    };
    for (final column in _userRefColumns) {
      final value = resolved[column];
      if (value is String) resolved[column] = await _localUserId(txn, value);
    }
    return resolved;
  }

  /// Real columns of [entity].localTable, cached for the length of the cycle.
  Future<Set<String>> _availableColumns(
    DatabaseExecutor txn,
    SyncEntity entity,
  ) => _columnCache.putIfAbsent(
    entity.localTable,
    () => availableColumns(txn, entity.localTable),
  );

  /// Firebase uid → local `users.id`, cached for the length of the cycle.
  Future<int> _localUserId(DatabaseExecutor txn, String uid) async {
    if (uid.isEmpty) return 0;
    final byUid = _userIds.putIfAbsent(uid, () async {
      final rows = await txn.query(
        'users',
        where: 'uid = ?',
        whereArgs: [uid],
        limit: 1,
      );
      return rows.isEmpty ? 0 : (rows.first['id'] as num).toInt();
    });
    return byUid;
  }

  static const Set<String> _userRefColumns = {'created_by', 'changed_by'};

  final Map<String, Future<Set<String>>> _columnCache = {};
  final Map<String, Future<int>> _userIds = {};

  static const Set<String> _nullableColumns = {
    'photo_url',
    'member_id',
    'uid',
    'display_name',
    'updated_by',
    'deleted_at',
  };

  /// Local defaults for columns the remote document does not carry.
  ///
  /// Only the tables that really have the column get it: `qualityCheck` maps
  /// onto `inspection_status_history`, which is a history log with its own
  /// `changed_at` and no `created_at`/`updated_at` at all. Writing a column
  /// that does not exist aborts the whole pull transaction, so the extra
  /// timestamps are filtered against the real schema.
  static Map<String, dynamic> _withDefaults(
    SyncEntity entity,
    Map<String, dynamic> row,
    Set<String> available,
  ) {
    Map<String, dynamic> withTimestamps() => {
      ...row,
      if (available.contains('created_at'))
        'created_at': row['created_at'] ?? nowIso(),
      if (available.contains('updated_at'))
        'updated_at': row['updated_at'] ?? nowIso(),
    };

    switch (entity.localTable) {
      case 'inspections':
        return {
          ...withTimestamps(),
          'decision_status': row['decision_status'] ?? 'PENDING',
          'created_by': row['created_by'] ?? 0,
          'created_by_name': row['created_by_name'] ?? '',
        };
      case 'users':
        return {
          ...row,
          'full_name': row['full_name'] ?? '',
          'status': row['status'] ?? 'invited',
          'permissions_json': row['permissions_json'] ?? '[]',
          'version': row['version'] ?? 1,
          'created_at': row['created_at'] ?? nowIso(),
        };
      default:
        return withTimestamps();
    }
  }
}

enum _ApplyOutcome { applied, skipped, pushedBack, failed }

bool _isPermissionDenied(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('permission-denied') ||
      text.contains('permission_denied') ||
      text.contains('permission denied') ||
      text.contains('unauthenticated');
}
