import 'package:flutter/foundation.dart';

import '../../features/organizations/data/member_write_guard.dart';
import '../database/database_helper.dart';
import '../utils/app_dates.dart';
import 'entity_registry.dart';
import 'sync_queue.dart';

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
  /// re-queued — only samples were). Walks each [SyncEntity] and re-queues
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

    bool budgetLeft() => queued + tombstones + skipped + alreadyQueued < limit;

    final entities = [
      for (final e in syncEntities)
        if (onlyTypes == null || onlyTypes.contains(e.type)) e,
    ];
    for (final entity in entities) {
      if (!budgetLeft()) break;
      // Skip entities whose table is missing on old installs.
      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='${entity.localTable}'",
      ));
      if (tables.isEmpty) continue;
      while (budgetLeft()) {
        final rows = await db.query(
          entity.localTable,
          where: "sync_state IS NULL OR sync_state <> 'synced'",
          orderBy: 'id ASC',
          limit: pageSize,
        );
        if (rows.isEmpty) break;

        await db.transaction((txn) async {
          for (final raw in rows) {
            if (!budgetLeft()) break;
            final row = Map<String, dynamic>.from(raw);
            final id = (row['id'] as num?)?.toInt();
            if (id == null) {
              skipped++;
              continue;
            }
            String docId;
            try {
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
                where: 'id = ?',
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
              continue;
            }

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
              where: 'id = ?',
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
        });

        if (rows.length < pageSize) break;
      }
    }

    debugPrint('[backfill] done: queued=$queued tombstones=$tombstones skipped=$skipped alreadyQueued=$alreadyQueued');
    return BackfillReport(
      queued: queued,
      tombstones: tombstones,
      skipped: skipped,
      alreadyQueued: alreadyQueued,
    );
  }
}
