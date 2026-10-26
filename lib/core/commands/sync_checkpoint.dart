/// Per-organization sync checkpoint (plan §5 `sync_checkpoint`): the highest
/// change-sequence of server change-events applied to the local read model.
///
/// Advanced only after the event application transaction commits — the
/// checkpoint can never run past an unapplied event (§8: "لا تتقدم النقطة فوق
/// حدث لم يطبق"). The first-fire `SET` inside that same transaction.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import '../database/db_trace.dart';

class SyncCheckpoints {
  SyncCheckpoints(this.dbHelper) {
    dbHelper.onDatabaseClosed(() => _resolved = null);
  }

  final DatabaseHelper dbHelper;

  Database? _resolved;

  Future<Database> get _db async => _resolved ??= await dbHelper.database;

  Future<int> appliedSequence({required String organizationId}) async {
    try {
      final db = (await _db);
      final rows = await db.query(
        'sync_checkpoint',
        columns: const ['applied_sequence'],
        where: 'organization_id = ?',
        whereArgs: [organizationId],
        limit: 1,
      );
      return rows.isEmpty ? 0 : (rows.first['applied_sequence'] as num).toInt();
    } on DatabaseException catch (e) {
      if (!e.isDatabaseClosedError()) rethrow;
      _resolved = null;
      final rows = await (await _db).query(
        'sync_checkpoint',
        columns: const ['applied_sequence'],
        where: 'organization_id = ?',
        whereArgs: [organizationId],
        limit: 1,
      );
      return rows.isEmpty ? 0 : (rows.first['applied_sequence'] as num).toInt();
    }
  }

  /// Advance the checkpoint, guarded against regression: a smaller (or equal)
  /// sequence — e.g. a duplicated or reordered event — never moves it back.
  /// Returns the new checkpoint value.
  ///
  /// [txn] lets the caller advance the checkpoint inside the SAME transaction
  /// that applied the events it belongs to.
  Future<int> advance(
    DatabaseExecutor txn, {
    required String organizationId,
    required int to,
  }) => DbTrace.run('checkpoint.advance', () async {
    if (to < 0 || organizationId.isEmpty) {
      throw ArgumentError('Invalid checkpoint');
    }
    final updated = await txn.rawUpdate(
      'UPDATE sync_checkpoint SET applied_sequence = ?, updated_at = '
      "datetime('now') "
      'WHERE organization_id = ? AND applied_sequence < ?',
      <Object?>[to, organizationId, to],
    );
    if (updated == 0) {
      // Either the row is missing (first advance) or it already sits at a
      // higher sequence (duplicate/older event). `OR IGNORE` keeps a finite
      // checkpoint above the incoming `to` — never a regression.
      await txn.insert('sync_checkpoint', {
        'organization_id': organizationId,
        'applied_sequence': to,
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    final rows = await txn.query(
      'sync_checkpoint',
      columns: ['applied_sequence'],
      where: 'organization_id = ?',
      whereArgs: [organizationId],
    );
    return (rows.single['applied_sequence'] as num).toInt();
  });
}
