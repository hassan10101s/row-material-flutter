import 'package:sqflite/sqflite.dart';

import '../../features/organizations/data/member_write_guard.dart';
import 'entity_registry.dart';
import 'sync_queue.dart';
import 'sync_write.dart';
import '../database/business_transaction.dart';

/// Reuses the business transaction: an outbox failure must roll back the edit
/// so a successful save always means the change can reach the other devices.
Future<void> queueSharedRows(
  DatabaseExecutor txn, {
  required String type,
  required SyncQueue queue,
  required WriteGuard guard,
  String? where,
  List<Object?>? whereArgs,
  bool onlyUnsynced = false,
  bool onlyChangedInOperation = false,
}) async {
  final entity = SyncEntity.byType(type)!;
  if (entity.permission != null && !guard.allows(entity.permission!)) {
    return;
  }
  final rows = await txn.query(
    entity.localTable,
    where: onlyUnsynced
        ? "${where == null ? '' : '($where) AND '}(sync_state IS NULL OR sync_state <> 'synced')"
        : where,
    whereArgs: whereArgs,
  );
  final changed = onlyChangedInOperation
      ? await BusinessAuthoringContext.changedRows(txn, type)
      : null;
  for (final raw in rows) {
    if (changed != null && !changed.contains(raw[entity.pkColumn])) continue;
    final row = Map<String, dynamic>.from(raw);
    if ('${row['remote_id'] ?? ''}'.isEmpty) row['remote_id'] = newRemoteId();
    final first = ((row['remote_version'] as num?)?.toInt() ?? 0) == 0;
    await enqueueLocalChange(
      executor: txn,
      entity: entity,
      row: row,
      operation: row['deleted_at'] != null
          ? 'tombstone'
          : first
          ? 'create'
          : 'update',
      queue: queue,
      organizationId: guard.organizationId,
      uid: guard.uid,
      deviceId: guard.deviceId,
    );
  }
}
