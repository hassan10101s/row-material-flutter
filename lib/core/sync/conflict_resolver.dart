import 'dart:convert';

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
        final db = await queue.dbHelper.database;
        // `sync_conflicts` has no `local_ref` column (plan §6.4), so the local
        // row is located from the parked payload: its `localId` first, then the
        // natural key of the table.
        final localRef = await findLocalRef(
          db,
          entity,
          '${conflict['entity_id']}',
          localPayload,
        );
        final columns = await availableColumns(db, entity.localTable);
        await db.transaction((txn) async {
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
              where: 'id = ?',
              whereArgs: [localRef],
            );
          }
        });
      },
    );
  }

  /// Replace the local row with the remote document.
  Future<void> keepRemote(
    int conflictId, {
    required String organizationId,
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
        await db.transaction((txn) async {
          final localId = document['localId'];
          if (localId is num) {
            final row = remoteToLocalRow(entity, document, organizationId: organizationId)
              ..['sync_state'] = 'synced'
              ..['remote_version'] = document['version'];
            await txn.update(
              entity.localTable,
              {
                for (final entry in row.entries)
                  if (entry.key != 'id' && columns.contains(entry.key)) entry.key: entry.value,
              },
              where: 'id = ?',
              whereArgs: [localId.toInt()],
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
