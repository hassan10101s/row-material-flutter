/// The relation gate's view of the local read model (plan §7): server-approved
/// rows as stored by the pull worker, addressed by GLOBAL identity.
///
/// Scope note (§8/§11): today's read model lives in the existing per-entity
/// tables the pull worker maintains (`remote_id` = server document key). This
/// adapter hides exactly that so the command path does not depend on where
/// the copy lives, and the full read-model split (§5 `read_model`) plugs in
/// behind the same interface without touching [CommandService].
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import 'command_service.dart';

/// Local read rows for the relation gate. Pilot: the inspection family
/// (`sample` draft's parent = a *product* inspection header).
class LocalReadModelState implements CommandReadModel {
  const LocalReadModelState(this.dbHelper);

  final DatabaseHelper dbHelper;

  @override
  Future<({Map<String, dynamic> row, bool deleted, int version})?>
  readApprovedEntity({
    required String organizationId,
    required String entityType,
    required String entityId,
  }) async {
    Database? db;
    try {
      db = await dbHelper.database;
      if (dbHelper.boundOrgId != organizationId) return null;
      switch (entityType) {
        case 'sample':
          return await _sample(db, entityId);
      }
      return null;
    } on DatabaseException {
      // The database closed underneath (org switch): the gate answers
      // "not available locally", which parks the draft instead of failing it.
      return null;
    }
  }

  Future<({Map<String, dynamic> row, bool deleted, int version})?> _sample(
    Database db,
    String entityId,
  ) async {
    // Only a unique, acknowledged global identity is eligible. A numeric
    // SQLite id or a local queued edit is not an approved parent.
    final rows = await db.rawQuery(
      "SELECT id, remote_id, entry_code, inspection_kind, deleted_at, remote_version FROM inspections "
      "WHERE (remote_id = ? OR entry_code = ?) AND sync_state = 'synced' AND remote_version > 0 LIMIT 2",
      [entityId, entityId],
    );
    if (rows.length != 1) return null;
    final row = rows.first;
    return (
      row: row,
      deleted: row['deleted_at'] != null,
      version: (row['remote_version'] as num).toInt(),
    );
  }
}
