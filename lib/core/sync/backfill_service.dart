import 'package:flutter/foundation.dart';

import '../../features/organizations/data/member_write_guard.dart';
import '../database/database_helper.dart';
import '../utils/app_dates.dart';
import 'entity_registry.dart';
import 'sync_queue.dart';
import 'sync_write.dart' show ensureRemoteId;

/// Result of one [BackfillService.enqueueUnsyncedSamples] pass.
class BackfillReport {
  const BackfillReport({
    this.queued = 0,
    this.tombstones = 0,
    this.skipped = 0,
    this.alreadyQueued = 0,
  });

  final int queued;
  final int tombstones;
  final int skipped;

  /// Rows that already have a queue entry (pending push or awaiting a manual
  /// conflict decision): left untouched so backfill never duplicates a queue
  /// row (unique index) and never clobbers a conflict under review.
  final int alreadyQueued;

  int get total => queued + tombstones;

  @override
  String toString() =>
      'BackfillReport(queued: $queued, tombstones: $tombstones, '
      'skipped: $skipped, alreadyQueued: $alreadyQueued)';
}

/// One-time / on-demand uploader for rows that exist locally but never reached
/// the server (imports, restores, or queue rows lost before the push-drain and
/// tombstone fixes).
///
/// It pages the local `inspections` table for rows whose `sync_state` is not
/// `synced`, rebuilds the exact remote payload the normal write path would
/// have queued (`buildRemotePayload` with the same envelope), and hands them
/// to [SyncQueue.enqueue] — which merges with any existing pending row, so
/// calling this twice is safe. The next `SyncEngine.syncNow` then pushes them
/// in batches (5 x 400 per manual tap).
///
/// Deleted rows (`deleted_at` set, not yet synced) are re-queued as
/// `tombstone` operations so the deletion replicates instead of lingering
/// locally forever.
class BackfillService {
  BackfillService({
    required this.dbHelper,
    required this.queue,
    required this.guard,
  });

  final DatabaseHelper dbHelper;
  final SyncQueue queue;
  final WriteGuard guard;

  static const int pageSize = 100;

  Future<BackfillReport> enqueueUnsyncedSamples({int limit = 5000}) async {
    return enqueueUnsyncedAll(limit: limit, onlyTypes: const {'sample'});
  }

  /// Generic backfill for every synced table (imports/restores of
  /// lab/reference/inventory/consumption/worksheet previously never
  /// re-queued — only samples were; plan P8 adds the whole QC family, so
  /// checklists / sheets / NC-CAPA rows that predate the sync also reach
  /// the server here). Walks each [SyncEntity] and re-queues
  /// rows whose `sync_state` is not `synced`, using the same envelope as the
  /// normal write path. Safe to call twice (merges via SyncQueue.enqueue,
  /// skips already-tracked + conflict-parked rows).
  Future<BackfillReport> enqueueUnsyncedAll({
    int limit = 5000,
    Set<String>? onlyTypes,
  }) async {
    final organizationId = guard.organizationId;
    final uid = guard.uid;
    final deviceId = guard.deviceId;
    if (organizationId.isEmpty || uid.isEmpty) {
      debugPrint('[backfill] skipped: no organization bound');
      return const BackfillReport();
    }

    final db = await dbHelper.database;
    final tracked = <String>{
      for (final r in await db.query(
        'sync_queue',
        columns: const ['entity_type', 'entity_id'],
      ))
        '${r['entity_type']}|${r['entity_id']}',
    };
    var queued = 0;
    var tombstones = 0;
    var skipped = 0;
    var alreadyQueued = 0;

    // Existing outbox entries do not consume the quota for newly queued rows.
    bool budgetLeft() => queued + tombstones + skipped < limit;

    final entities = [
      for (final e in syncEntities)
        if (onlyTypes == null || onlyTypes.contains(e.type)) e,
    ];
    for (final entity in entities) {
      if (entity.permission != null && !guard.allows(entity.permission!)) {
        continue;
      }
      if (!budgetLeft()) break;
      // Skip entities whose table is missing on old installs.
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='${entity.localTable}'",
      ));
      if (tables.isEmpty) continue;
      var lastPk = 0;
      while (budgetLeft()) {
        // Keyset pagination: this query also matches rows this pass has just
        // moved to 'queued', so an unbounded loop used to re-read page 1
        // forever — recounting its own rows against the budget and never
        // reaching the rest of the table. `lastPk` walks the table and every
        // row is visited exactly once.
        final rows = await db.rawQuery(
          "SELECT * FROM ${entity.localTable} "
          "WHERE ${entity.pkColumn} > ? "
          "AND (sync_state IS NULL OR sync_state <> 'synced') "
          "ORDER BY ${entity.pkColumn} ASC LIMIT $pageSize",
          [lastPk],
        );
        if (rows.isEmpty) break;
        final pageStart = lastPk;
        await db.transaction((txn) async {
          for (final raw in rows) {
            if (!budgetLeft()) break;
            final row = Map<String, dynamic>.from(raw);
            final id = (row[entity.pkColumn] as num?)?.toInt();
            if (id != null) lastPk = id;
            if (id == null) {
              skipped++;
              continue;
            }
            String docId;
            try {
              if (row.containsKey('remote_id') &&
                  '${row['remote_id'] ?? ''}'.isEmpty) {
                ensureRemoteId(
                  row,
                  entity.localTable,
                  pkColumn: entity.pkColumn,
                );
                await txn.update(
                  entity.localTable,
                  {'remote_id': row['remote_id']},
                  where: '${entity.pkColumn} = ?',
                  whereArgs: [id],
                );
              }
              docId = entity.docId(row);
            } on Object {
              skipped++;
              continue;
            }
            if (docId.isEmpty) {
              skipped++;
              continue;
            }
            final remoteVersion = (row['remote_version'] as num?)?.toInt() ?? 0;
            final deleted = '${row['deleted_at'] ?? ''}'.isNotEmpty;
            if (tracked.contains('${entity.type}|$docId')) {
              alreadyQueued++;
              continue;
            }

            if (deleted) {
              await txn.update(
                entity.localTable,
                {'sync_state': 'queued', 'updated_at': nowIso()},
                where: '${entity.pkColumn} = ?',
                whereArgs: [id],
              );
              await queue.enqueue(
                txn,
                entityType: entity.type,
                entityId: docId,
                localRef: id,
                operation: 'tombstone',
                payload: const {},
                baseVersion: remoteVersion,
              );
              tombstones++;
            } else {
              await stampSharedParents(txn, entity, row);
              final localVersion = (row['version'] as num?)?.toInt() ?? 1;
              final snapshot = Map<String, dynamic>.from(row)
                ..['sync_state'] = 'queued';
              final ctx = SyncPayloadContext(
                organizationId: organizationId,
                uid: uid,
                deviceId: deviceId,
                version: localVersion,
                versionField: 'version',
              );
              final isFirstPush = remoteVersion == 0;
              await txn.update(
                entity.localTable,
                {'sync_state': 'queued'},
                where: '${entity.pkColumn} = ?',
                whereArgs: [id],
              );
              await queue.enqueue(
                txn,
                entityType: entity.type,
                entityId: docId,
                localRef: id,
                operation: isFirstPush ? 'create' : 'update',
                payload: buildRemotePayload(
                  entity,
                  snapshot,
                  ctx,
                  asCreate: isFirstPush,
                ),
                baseVersion: remoteVersion,
              );
              queued++;
            }
            // A row queued in this pass must not be re-queued by a later page
            // (or call) reading a snapshot of `tracked` taken before it.
            tracked.add('${entity.type}|$docId');
          }
        });

        if (lastPk == pageStart) {
          // No numeric pk advanced (text keys or a page of unparseable ids):
          // keyset cannot progress here, so stop before this turns into a
          // budget-burning spin.
          break;
        }
        if (rows.length < pageSize) break;
      }
    }

    debugPrint(
      '[backfill] done: queued=$queued tombstones=$tombstones skipped=$skipped alreadyQueued=$alreadyQueued',
    );
    return BackfillReport(
      queued: queued,
      tombstones: tombstones,
      skipped: skipped,
      alreadyQueued: alreadyQueued,
    );
  }
}
