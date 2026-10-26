import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../utils/app_dates.dart';
import 'audit_logger.dart';
import 'entity_registry.dart';
import 'sync_queue.dart';

const _uuid = Uuid();

/// Generates a cross-device identity for a new row (plan §1).
String newRemoteId() => _uuid.v4();

/// Ensures [row] carries a `remote_id`, writing the backfill form for legacy
/// rows and a UUID for new ones. [pkColumn] is the row's primary key ("id"
/// everywhere except the QC family, whose pks are `template_id`,
/// `inspection_id`, ...). Returns the remote id.
String ensureRemoteId(
  Map<String, dynamic> row,
  String table, {
  String pkColumn = 'id',
}) {
  var remoteId = '${row['remote_id'] ?? ''}';
  if (remoteId.isEmpty) {
    final id = row[pkColumn];
    remoteId = id == null ? newRemoteId() : 'legacy_${table}_$id';
    row['remote_id'] = remoteId;
  }
  return remoteId;
}

/// Next optimistic version for a local edit: 1 on first push, else max+1.
int nextVersion(Map<String, dynamic> row) {
  final version = (row['version'] as num?)?.toInt() ?? 0;
  final remoteVersion = (row['remote_version'] as num?)?.toInt() ?? 0;
  final base = version > remoteVersion ? version : remoteVersion;
  return base <= 0 ? 1 : base + 1;
}

/// The single write contract for every shared table (plan §6):
/// SQLite mutation + version bump + `sync_state='queued'` + `sync_queue` entry
/// + audit record, all inside the caller's transaction.
///
/// [executor] MUST be the business transaction ([txn]). [row] is the fresh
/// local row after the write (must contain `id`). [operation] is one of
/// `create`/`update`/`tombstone`. For append-only ledgers every insert is a
/// `create` with version 1.
Future<Map<String, dynamic>> enqueueLocalChange({
  required DatabaseExecutor executor,
  required SyncEntity entity,
  required Map<String, dynamic> row,
  required String operation,
  required SyncQueue queue,
  AuditLogger? audit,
  String? auditAction,
  String? organizationId,
  String? uid,
  String? deviceId,
}) async {
  await stampSharedParents(executor, entity, row);
  ensureRemoteId(row, entity.localTable, pkColumn: entity.pkColumn);
  final version =
      operation == 'create' && ((row['version'] as num?)?.toInt() ?? 0) <= 1
      ? 1
      : nextVersion(row);
  row['version'] = version;
  row['sync_state'] = 'queued';
  row['remote_synced_at'] = row['remote_synced_at'];
  if (deviceId != null && deviceId.isNotEmpty) {
    try {
      row['device_id'] = deviceId;
    } on Object {
      // Column missing on a legacy file: pull filtering drops it anyway.
    }
  }

  final now = nowIso();
  // Best-effort stamp of the row itself so the queue + row stay coherent.
  // Missing columns on old files are ignored — `_ensureColumn` adds them on
  // the next open, and the pull path filters by `availableColumns`.
  try {
    final localId = (row[entity.pkColumn] as num?)?.toInt();
    if (localId != null) {
      final patch = <String, Object?>{
        'version': version,
        'sync_state': 'queued',
      };
      if (row.containsKey('remote_id')) patch['remote_id'] = row['remote_id'];
      if (deviceId != null) patch['device_id'] = deviceId;
      await executor.update(
        entity.localTable,
        patch,
        where: '${entity.pkColumn} = ?',
        whereArgs: [localId],
      );
    }
  } on Object {
    // Row stamp is a courtesy; the queue entry below is the source of truth.
  }

  final payload = buildRemotePayload(
    entity,
    row,
    SyncPayloadContext(
      organizationId: organizationId ?? '',
      uid: uid ?? '',
      deviceId: deviceId ?? '',
      version: version,
      versionField: 'version',
    ),
    asCreate: operation == 'create',
  );

  await queue.enqueue(
    executor,
    entityType: entity.type,
    entityId: entity.docId(row),
    localRef: (row[entity.pkColumn] as num?)?.toInt(),
    operation: operation,
    payload: payload,
    baseVersion: operation == 'create' ? 0 : version - 1,
  );

  if (audit != null && auditAction != null) {
    try {
      await audit.log(
        executor,
        action: auditAction,
        entityType: entity.type,
        entityId: entity.docId(row),
        details: {
          'localId': row[entity.pkColumn],
          'remoteId': row['remote_id'],
        },
      );
    } on Object {
      // Audit must never fail the business write.
    }
  }

  row['updated_at'] = now;
  return row;
}

/// Sums the unified ledger for one inventory item (plan §4).
/// `current_qty` on `lab_inventory` is a cache; this is the truth.
Future<double> recomputeBalance(
  DatabaseExecutor executor,
  int inventoryId,
) async {
  final rows = await executor.rawQuery(
    'SELECT COALESCE(SUM(quantity_delta),0) AS balance '
    'FROM inventory_transactions WHERE inventory_id = ?',
    [inventoryId],
  );
  if (rows.isEmpty) return 0;
  return ((rows.first['balance'] as num?) ?? 0).toDouble();
}
