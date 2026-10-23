import 'package:sqflite/sqflite.dart';

import '../../../core/utils/app_dates.dart';
import '../domain/qc_custom_table.dart';
import 'qc_repo.dart';

/// The local SQL layer for user-authored tables (QC settings feature).
///
/// Thin by house rule: SQL only — no session, no permission check, no queue,
/// no audit. Those live in `offline_first_qc_custom_tables.dart`, which threads
/// its transaction into every method here through [exec]. Reconciliation
/// (which fields a save updates / tombstones) is written down in one place,
/// the facade, because it is a policy, not a query.
class QcCustomTablesRepo extends QcLocalRepo {
  QcCustomTablesRepo(super.dbHelper);

  // ── Table definitions ─────────────────────────────────────────────────

  /// Every alive definition, in chip order. A tombstoned definition is gone
  /// from the hub but keeps its rows on disk for the audit.
  Future<List<QcCustomTable>> listTables({DatabaseExecutor? exec}) async {
    final rows = await use(exec, await db).query(
      'qc_custom_tables',
      where: qcAliveFilter,
      orderBy: 'sort_order ASC, table_id ASC',
    );
    return qcDecode(rows, QcCustomTable.fromMap);
  }

  Future<int> countAliveTables({DatabaseExecutor? exec}) async {
    final rows = await use(exec, await db).query(
      'qc_custom_tables',
      columns: const ['COUNT(*) AS c'],
      where: qcAliveFilter,
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  /// Duplicate title guard among *alive* definitions. A tombstoned register
  /// must not block a future one with the same name, which is exactly why
  /// this is a repository check rather than a UNIQUE schema index.
  Future<bool> titleTaken(
    String title, {
    int? exceptTableId,
    DatabaseExecutor? exec,
  }) async {
    final clauses = <String>[qcAliveFilter, 'LOWER(TRIM(title)) = ?'];
    final values = <Object?>[title.toLowerCase().trim()];
    if (exceptTableId != null) {
      clauses.add('table_id <> ?');
      values.add(exceptTableId);
    }
    final rows = await use(exec, await db).query(
      'qc_custom_tables',
      where: qcWhere(clauses),
      whereArgs: qcArgs(values),
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<QcCustomTable?> getTable(int tableId, {DatabaseExecutor? exec}) async {
    final rows = await use(exec, await db).query(
      'qc_custom_tables',
      where: qcAlive('table_id = ?'),
      whereArgs: [tableId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : QcCustomTable.fromMap(Map<String, dynamic>.from(rows.first));
  }

  /// The definition plus its alive columns, in display order - the shape the
  /// editor and the records screen both open against.
  Future<({QcCustomTable table, List<QcCustomTableField> fields})?>
  getTableBundle(int tableId, {DatabaseExecutor? exec}) async {
    final table = await getTable(tableId, exec: exec);
    if (table == null) return null;
    return (table: table, fields: await listFields(tableId, exec: exec));
  }

  Future<int> insertTable(QcCustomTable table, {DatabaseExecutor? exec}) async {
    return use(exec, await db).insert(
      'qc_custom_tables',
      qcInsertable(table.toMap(withId: false), 'table_id'),
    );
  }

  Future<void> updateTable(
    QcCustomTable table, {
    DatabaseExecutor? exec,
  }) async {
    final txn = use(exec, await db);
    final patched = Map<String, dynamic>.from(table.toMap())
      ..['updated_at'] = nowIso();
    await txn.update(
      'qc_custom_tables',
      qcUpdatable(patched, 'table_id', alsoImmutable: {'remote_id'}),
      where: 'table_id = ?',
      whereArgs: [table.tableId],
    );
  }

  /// Soft-deletes a definition together with its columns and records. The
  /// rows are tombstoned, never deleted: the queue pushes their tombstones
  /// and history stays readable.
  Future<void> tombstoneAll(
    int tableId,
    String at, {
    DatabaseExecutor? exec,
  }) async {
    final txn = use(exec, await db);
    final stamp = {'deleted_at': at, 'updated_at': at};
    await txn.update(
      'qc_custom_tables',
      stamp,
      where: 'table_id = ?',
      whereArgs: [tableId],
    );
    await txn.update(
      'qc_custom_table_fields',
      stamp,
      where: 'table_id = ?',
      whereArgs: [tableId],
    );
    await txn.update(
      'qc_custom_table_rows',
      stamp,
      where: 'table_id = ?',
      whereArgs: [tableId],
    );
  }

  // ── Columns (typed fields) ─────────────────────────────────────────────

  Future<List<QcCustomTableField>> listFields(
    int tableId, {
    DatabaseExecutor? exec,
  }) async {
    final rows = await use(exec, await db).query(
      'qc_custom_table_fields',
      where: qcAlive('table_id = ?'),
      whereArgs: [tableId],
      orderBy: 'sort_order ASC, field_id ASC',
    );
    return qcDecode(rows, QcCustomTableField.fromMap);
  }

  Future<int> insertField(
    QcCustomTableField field, {
    DatabaseExecutor? exec,
  }) async {
    return use(exec, await db).insert(
      'qc_custom_table_fields',
      qcInsertable(field.toMap(withId: false), 'field_id'),
    );
  }

  Future<void> updateField(
    QcCustomTableField field, {
    DatabaseExecutor? exec,
  }) async {
    final txn = use(exec, await db);
    final patched = Map<String, dynamic>.from(field.toMap())
      ..['updated_at'] = nowIso();
    await txn.update(
      'qc_custom_table_fields',
      qcUpdatable(
        patched,
        'field_id',
        alsoImmutable: {
          'remote_id',
          'table_id',
          'table_remote_id',
          'created_at',
        },
      ),
      where: 'field_id = ?',
      whereArgs: [field.fieldId],
    );
  }

  Future<void> tombstoneField(
    int fieldId,
    String at, {
    DatabaseExecutor? exec,
  }) async {
    await use(exec, await db).update(
      'qc_custom_table_fields',
      {'deleted_at': at, 'updated_at': at},
      where: 'field_id = ?',
      whereArgs: [fieldId],
    );
  }

  Future<int> countAliveFields(int tableId, {DatabaseExecutor? exec}) async {
    final rows = await use(exec, await db).query(
      'qc_custom_table_fields',
      columns: const ['COUNT(*) AS c'],
      where: qcAlive('table_id = ?'),
      whereArgs: [tableId],
    );
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }

  // ── Records ────────────────────────────────────────────────────────────

  /// Newest first, keyset over `row_id` so a page never skips or repeats a
  /// record while a sibling device appends between cycles.
  Future<List<QcCustomTableRow>> listRows(
    int tableId, {
    int limit = 200,
    int afterRowId = 0,
    DatabaseExecutor? exec,
  }) async {
    final clauses = <String>[qcAliveFilter, 'table_id = ?'];
    final values = <Object?>[tableId];
    if (afterRowId > 0) {
      clauses.add('row_id < ?');
      values.add(afterRowId);
    }
    final rows = await use(exec, await db).query(
      'qc_custom_table_rows',
      where: qcWhere(clauses),
      whereArgs: qcArgs(values),
      orderBy: 'row_id DESC',
      limit: limit,
    );
    return qcDecode(rows, QcCustomTableRow.fromMap);
  }

  Future<QcCustomTableRow?> getRow(int rowId, {DatabaseExecutor? exec}) async {
    final rows = await use(exec, await db).query(
      'qc_custom_table_rows',
      where: qcAlive('row_id = ?'),
      whereArgs: [rowId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : QcCustomTableRow.fromMap(Map<String, dynamic>.from(rows.first));
  }

  Future<int> insertRow(QcCustomTableRow row, {DatabaseExecutor? exec}) async {
    return use(exec, await db).insert(
      'qc_custom_table_rows',
      qcInsertable(row.toMap(withId: false), 'row_id'),
    );
  }

  Future<void> updateRow(QcCustomTableRow row, {DatabaseExecutor? exec}) async {
    final txn = use(exec, await db);
    final patched = Map<String, dynamic>.from(row.toMap())
      ..['updated_at'] = nowIso();
    await txn.update(
      'qc_custom_table_rows',
      qcUpdatable(
        patched,
        'row_id',
        alsoImmutable: {
          'remote_id',
          'table_id',
          'table_remote_id',
          'recorded_at',
          'created_at',
        },
      ),
      where: 'row_id = ?',
      whereArgs: [row.rowId],
    );
  }

  Future<void> tombstoneRow(
    int rowId,
    String at, {
    DatabaseExecutor? exec,
  }) async {
    await use(exec, await db).update(
      'qc_custom_table_rows',
      {'deleted_at': at, 'updated_at': at},
      where: 'row_id = ?',
      whereArgs: [rowId],
    );
  }

  // ── Guards ─────────────────────────────────────────────────────────────

  /// Whether any record of [tableId] stores a (decoded) value under [fieldRemoteId].
  ///
  /// Guarding the column `col_type` change: once a record carries a value of
  /// one shape, re-typing the column can silently break what the screen shows,
  /// and a LIKE-scan damage-fix is not available. The quoted pattern matches
  /// the key position (`"<remote_id>":`) only when nothing happens to encode
  /// the same string as a value; a false positive just conservatively blocks
  /// the re-type.
  Future<bool> hasValuesForField(
    int tableId,
    String fieldRemoteId, {
    DatabaseExecutor? exec,
  }) async {
    if (fieldRemoteId.isEmpty) return false;
    final rows = await use(exec, await db).query(
      'qc_custom_table_rows',
      columns: const ['COUNT(*) AS c'],
      where: qcAlive('table_id = ? AND instr(values_json, ?) > 0'),
      whereArgs: [tableId, '"$fieldRemoteId"'],
    );
    return ((rows.first['c'] as num?)?.toInt() ?? 0) > 0;
  }

  /// Column keys that survived lookups for the records screen: alive fields
  /// keyed by their `remote_id`, in display order.
  Future<Map<String, QcCustomTableField>> fieldsByRemoteId(
    int tableId, {
    DatabaseExecutor? exec,
  }) async {
    final out = <String, QcCustomTableField>{};
    for (final field in await listFields(tableId, exec: exec)) {
      if (field.remoteId.isNotEmpty) out[field.remoteId] = field;
    }
    return out;
  }
}
