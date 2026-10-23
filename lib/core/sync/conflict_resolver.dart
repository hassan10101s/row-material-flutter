import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/db_trace.dart';
import 'entity_registry.dart';
import 'remote/remote_data_source.dart';
import 'sync_queue.dart';

/// Manual conflict resolution from the Sync screen (plan §9.6).
///
/// No silent last-write-wins: every conflict is either replayed on top of the
/// remote version (`keep_local`) or replaced by the remote document
/// (`keep_remote`), and both paths are audited.
class ConflictResolver {
  ConflictResolver({required this.queue, required this.remote});

  final SyncQueue queue;
  final RemoteDataSource remote;

  static const String keepLocalResolution = 'keep_local';
  static const String keepRemoteResolution = 'keep_remote';

  /// Re-push the local payload with `remoteVersion + 1`.
  Future<void> keepLocal(
    int conflictId, {
    required String organizationId,
    required AppSessionLike session,
  }) async {
    await queue.resolveConflict(
      conflictId,
      resolution: keepLocalResolution,
      onKeepLocal: (conflict) async {
        final entity = SyncEntity.byType('${conflict['entity_type']}');
        if (entity == null) return;
        final localPayload = _decode('${conflict['local_payload']}');
        final remoteVersion = await _remoteVersion(
          organizationId,
          entity,
          '${conflict['entity_id']}',
        );
        localPayload['version'] = remoteVersion + 1;
        localPayload['updatedBy'] = session.uid;
        localPayload['deviceId'] = session.deviceId;
        // Parked before the derived-artifact exclusion: strip the stored HTML
        // or a legitimately large row re-trips the oversized guard forever.
        localPayload.remove('reportHtml');
        final db = await queue.dbHelper.database;
        // `sync_conflicts` has no `local_ref` column (plan §6.4), so the local
        // row is located from the parked payload: its `localId` first, then the
        // natural key of the table.
        final localRef = await findLocalRef(
          db,
          entity,
          '${conflict['entity_id']}',
          localPayload,
          localDeviceId: session.deviceId,
        );
        final columns = await availableColumns(db, entity.localTable);
        await tracedTransaction(db, 'conflicts.keepLocal', (txn) async {
          await queue.enqueue(
            txn,
            entityType: entity.type,
            entityId: '${conflict['entity_id']}',
            localRef: localRef,
            operation: localPayload['deletedAt'] == null ? 'update' : 'tombstone',
            payload: localPayload,
            baseVersion: remoteVersion,
          );
          if (localRef != null) {
            await txn.update(
              entity.localTable,
              {
                'sync_state': 'queued',
                'remote_version': remoteVersion,
                if (columns.contains('version')) 'version': remoteVersion + 1,
              },
              where: '${entity.pkColumn} = ?',
              whereArgs: [localRef],
            );
          }
        });
      },
    );
  }

  /// Replace the local row with the remote document.
  ///
  /// The row is located by natural key (never by the document's `localId`,
  /// which is the origin device's row id), and the remote foreign keys are
  /// remapped to this device before writing — the old code updated
  /// `id = localId` with raw ids and died on FK (`created_by: 'local_1'`,
  /// unknown `material_id`) or overwrote an unrelated local row.
  Future<void> keepRemote(
    int conflictId, {
    required String organizationId,
    required AppSessionLike session,
  }) async {
    await queue.resolveConflict(
      conflictId,
      resolution: keepRemoteResolution,
      onKeepLocal: (_) async {},
      onKeepRemote: (conflict, remoteJson) async {
        final entity = SyncEntity.byType('${conflict['entity_type']}');
        if (entity == null) return;
        // A payload we cannot decode would close the conflict without applying
        // anything, so it has to fail loudly and stay resolvable.
        final document = _decode(remoteJson);
        if (document.isEmpty) {
          throw StateError('unreadable remote payload for ${entity.type}');
        }
        final db = await queue.dbHelper.database;
        final columns = await availableColumns(db, entity.localTable);
        await tracedTransaction(db, 'conflicts.keepRemote', (txn) async {
          final localRef = await findLocalRef(
            txn,
            entity,
            '${conflict['entity_id']}',
            document,
            localDeviceId: session.deviceId,
          );
          final row = remoteToLocalRow(entity, document, organizationId: organizationId)
            ..['sync_state'] = 'synced'
            ..['remote_version'] = document['version'];
          await resolveRemoteRowRefs(
            txn,
            entity,
            row,
            document,
            ensureProductSentinel:
                (exec) => queue.dbHelper.ensureProductSentinelMaterialId(exec),
          );
          if (localRef == null) {
            // No local row (deleted locally, or never pulled): insert instead
            // of updating nothing. Fresh id for natural-key tables so the
            // origin id cannot replace an unrelated row.
            if (entity.naturalKeyIdentity) row.remove(entity.pkColumn);
            await txn.insert(
              entity.localTable,
              {
                for (final entry in row.entries)
                  if (columns.contains(entry.key)) entry.key: entry.value,
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          } else {
            await txn.update(
              entity.localTable,
              {
                for (final entry in row.entries)
                  if (entry.key != entity.pkColumn && columns.contains(entry.key))
                    entry.key: entry.value,
              },
              where: '${entity.pkColumn} = ?',
              whereArgs: [localRef],
            );
          }
          await txn.delete(
            'sync_queue',
            where: "entity_type = ? AND entity_id = ?",
            whereArgs: [entity.type, '${conflict['entity_id']}'],
          );
        });
      },
    );
  }

  Future<int> _remoteVersion(String organizationId, SyncEntity entity, String entityId) async {
    final document = await remote.getDocument(
      organizationId: organizationId,
      collection: entity.collection,
      documentId: entityId,
    );
    return document.exists ? document.version : 0;
  }

  static Map<String, dynamic> _decode(String raw) {
    if (raw.isEmpty || raw == 'null') return <String, dynamic>{};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } on Object {
      return <String, dynamic>{};
    }
  }
}

/// Minimal session surface the resolver needs (avoids a core↔auth import cycle
/// in tests).
abstract class AppSessionLike {
  String get uid;
  String get deviceId;
}
