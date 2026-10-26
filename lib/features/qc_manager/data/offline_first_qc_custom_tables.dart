import 'dart:convert' as convert;

import 'package:sqflite/sqflite.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/entity_registry.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/sync/sync_write.dart' as sync_write;
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/qc_custom_table.dart';
import '../domain/qc_repositories.dart';
import 'qc_custom_tables_repo.dart';

/// Offline-first facade over [QcCustomTablesRepo] - the seam where the QC
/// settings feature meets the plan §9.4 guards, the plan §6 sync write
/// contract and the shared audit trail, all inside **one transaction per
/// write**.
///
/// ## Why this facade is the first QC surface in the sync scope
/// The other QC facades (`offline_first_qc_repository.dart`) deliberately do
/// not enqueue: until a remote collection and rules existed, a queued row
/// would drag a working offline write into a permanent conflict. The
/// user-authored tables were built sync-first, so this facade registers its
/// three `SyncEntity` members and enqueues under their write contract
/// (`enqueueLocalChange`), with the same guard, in the caller's transaction.
/// The `qc_audits` hash chain stays out on purpose: its schema CHECK
/// enumerates the regulated QC entity kinds only, and rewriting an old
/// install's table definition to add new kinds is not something a live
/// database can do - the shared `audit_logs` outbox (pushed to
/// `auditLogs`) keeps the trail instead.
///
/// ## Validation is policy, not SQL
/// Values are checked against the *live column set* before every record
/// write: unknown keys, wrong types (number/text/date), blank required
/// columns and the re-typing of a column that already holds data are all
/// [ValidationError]s. A record whose validation would be weaker than the
/// screen's would sync fine and lie on every synced device, which is why
/// the fact runs here, where no caller can skip it.
class OfflineFirstQcCustomTablesRepository implements QcCustomTablesRepository {
  OfflineFirstQcCustomTablesRepository({
    required this._local,
    required this._guard,
    required this._dbHelper,
    required this._queue,
    this._syncAudit,
  });

  static SyncEntity _entity(String type) =>
      SyncEntity.byType(type) ??
      (throw StateError('Unknown sync entity: $type'));

  final QcCustomTablesRepo _local;
  final WriteGuard _guard;
  final DatabaseHelper _dbHelper;
  final SyncQueue _queue;
  final AuditLogger? _syncAudit;

  void _check(Permission permission) {
    if (_guard.allows(permission.id)) return;
    throw AuthorizationError(
      permissionRequiresFreshSession(permission) && !_guard.online
          ? AppErrors.privilegedOperationNeedsConnection
          : AppErrors.notAuthorizedForOperation,
    );
  }

  /// The actor label the register's «بواسطة» column shows — the shared
  /// [WriteGuardActor.actorName] rule.
  String get _actorName => _guard.actorName;

  Future<T> _transaction<T>(
    Future<T> Function(DatabaseExecutor txn) body,
  ) async {
    return _dbHelper.businessTransaction<T>(body);
  }

  /// Enqueues one local change **inside [txn]**. On a transient enqueue
  /// failure the row is left flagged `queued` so the backfill picks it up;
  /// the business write is never undone by a hiccup of the outbox.
  Future<void> _enqueue(
    DatabaseExecutor txn, {
    required String entityType,
    required Map<String, dynamic> row,
    required String operation,
    bool withAudit = true,
    String? auditAction,
  }) async {
    await sync_write.enqueueLocalChange(
      executor: txn,
      entity: _entity(entityType),
      row: row,
      operation: operation,
      queue: _queue,
      audit: withAudit && auditAction != null ? _syncAudit : null,
      auditAction: auditAction,
      organizationId: _guard.organizationId,
      uid: _guard.uid,
      deviceId: _guard.deviceId,
    );
  }

  /// Returns the just-inserted row as a writable map with `id` +
  /// `remote_id` (UUID) set, in one step: the enqueue promises a row that
  /// carries its cross-device identity.
  Future<Map<String, dynamic>> _stamped(
    DatabaseExecutor txn,
    String table,
    String idColumn,
    int id,
  ) async {
    final rows = await txn.query(
      table,
      where: '$idColumn = ?',
      whereArgs: [id],
      limit: 1,
    );
    final row = rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
    if (row == null) {
      throw StateError('QC custom table write vanished: $table/$id');
    }
    if ('${row['remote_id'] ?? ''}'.isEmpty) {
      row['remote_id'] = sync_write.newRemoteId();
      try {
        await txn.update(
          table,
          {'remote_id': row['remote_id']},
          where: '$idColumn = ?',
          whereArgs: [id],
        );
      } on Object {
        // Column missing until the open-time guarantee repairs it.
      }
    }
    return row;
  }

  // ── Reads (unguarded: reads are gated at the route layer) ─────────────

  @override
  Future<List<QcCustomTable>> listTables() => _local.listTables();

  @override
  Future<({QcCustomTable table, List<QcCustomTableField> fields})?>
  getTableBundle(int tableId) => _local.getTableBundle(tableId);

  @override
  Future<List<QcCustomTableRow>> listRows(
    int tableId, {
    int limit = 200,
    int afterRowId = 0,
  }) => _local.listRows(tableId, limit: limit, afterRowId: afterRowId);

  // ── Table definitions ─────────────────────────────────────────────────

  @override
  Future<int> createTable(
    QcCustomTable table,
    List<QcCustomTableField> fields,
  ) async {
    _check(Permission.qcWrite);
    _validateDefinition(table.title, fields);
    return _transaction((txn) async {
      if (await _local.titleTaken(table.title, exec: txn)) {
        throw ValidationError(
          AppText.t(
            'يوجد جدول بنفس الاسم بالفعل',
            'A table with that title already exists',
          ),
        );
      }
      final now = nowIso();
      final aliveCount = await _local.countAliveTables(exec: txn);
      final created = QcCustomTable(
        title: table.title.trim(),
        description: table.description.trim(),
        sortOrder: aliveCount,
        createdAt: now,
        updatedAt: now,
        createdBy: _guard.uid,
        updatedBy: _guard.uid,
      );
      final tableId = await _local.insertTable(created, exec: txn);
      final tableRow = await _stamped(
        txn,
        'qc_custom_tables',
        'table_id',
        tableId,
      );
      await _enqueue(
        txn,
        entityType: 'qcCustomTable',
        row: tableRow,
        operation: 'create',
        auditAction: AuditAction.customTableSaved,
      );
      await _insertFieldsWithFields(
        txn,
        tableId,
        tableRow['remote_id'] as String,
        fields,
      );
      return tableId;
    });
  }

  Future<void> _insertFieldsWithFields(
    DatabaseExecutor txn,
    int tableId,
    String tableRemoteId,
    List<QcCustomTableField> fields, {
    int startOrder = 0,
  }) async {
    final now = nowIso();
    for (var i = 0; i < fields.length; i++) {
      final field = QcCustomTableField(
        tableId: tableId,
        tableRemoteId: tableRemoteId,
        label: fields[i].label.trim(),
        colType: fields[i].colType,
        required: fields[i].required,
        sortOrder: startOrder + i,
        remoteId: sync_write.newRemoteId(),
        createdAt: now,
        updatedAt: now,
        createdBy: _guard.uid,
        updatedBy: _guard.uid,
      );
      final fieldId = await _local.insertField(field, exec: txn);
      final fieldRow = await _stamped(
        txn,
        'qc_custom_table_fields',
        'field_id',
        fieldId,
      );
      await _enqueue(
        txn,
        entityType: 'qcCustomTableField',
        row: fieldRow,
        operation: 'create',
      );
    }
  }

  @override
  Future<void> saveTable(
    QcCustomTable table,
    List<QcCustomTableField> fields,
  ) async {
    _check(Permission.qcWrite);
    final id = table.tableId;
    if (id == null) {
      throw ValidationError(
        AppText.t(
          'لا يمكن حفظ جدول بلا معرّف',
          'Cannot save a table with no id',
        ),
      );
    }
    _validateDefinition(table.title, fields);

    await _transaction((txn) async {
      final existing = await _local.getTableBundle(id, exec: txn);
      if (existing == null) {
        throw NotFoundError(
          AppText.t(
            'الجدول غير موجود ($id)',
            'Record not found (No QC custom table with id $id)',
          ),
        );
      }

      final remaining = table.title.trim().toLowerCase();
      final clash = await _local.titleTaken(
        remaining,
        exceptTableId: id,
        exec: txn,
      );
      if (clash) {
        throw ValidationError(
          AppText.t(
            'يوجد جدول بنفس الاسم بالفعل',
            'A table with that title already exists',
          ),
        );
      }

      final byId = {
        for (final f in existing.fields)
          if (f.fieldId != null) f.fieldId!: f,
      };
      final keptIds = <int>{};
      final now = nowIso();
      for (var i = 0; i < fields.length; i++) {
        final incoming = fields[i];
        final match = incoming.fieldId == null ? null : byId[incoming.fieldId];
        if (match == null) continue;
        keptIds.add(match.fieldId!);
        if (incoming.colType != match.colType) {
          // A re-type over existing data is how a "number" becomes garbage
          // on every synced device at once. Values are keyed by the field's
          // stable remote id, so refusing the re-type preserves them.
          final hasValues = await _local.hasValuesForField(
            id,
            match.remoteId,
            exec: txn,
          );
          if (hasValues) {
            throw ValidationError(
              AppText.t(
                'لا يمكن تغيير نوع العمود "${match.label}" لاحتوائه بيانات',
                'Column "${match.label}" already holds values, '
                    'its type cannot change',
              ),
            );
          }
        }
      }

      await _local.updateTable(
        QcCustomTable(
          tableId: id,
          remoteId: existing.table.remoteId,
          title: table.title.trim(),
          description: table.description.trim(),
          sortOrder: existing.table.sortOrder,
          createdAt: existing.table.createdAt,
          updatedAt: now,
          createdBy: existing.table.createdBy,
          updatedBy: _guard.uid,
          version: existing.table.version,
        ),
        exec: txn,
      );
      final tableRow = await _stamped(txn, 'qc_custom_tables', 'table_id', id);
      await _enqueue(
        txn,
        entityType: 'qcCustomTable',
        row: tableRow,
        operation: 'update',
      );

      for (var i = 0; i < fields.length; i++) {
        final incoming = fields[i];
        final match = incoming.fieldId == null ? null : byId[incoming.fieldId];
        // A keep writes FIRST, then re-reads, then enqueues: the queued
        // payload must carry what was just written, never the pre-edit row.
        if (match != null) {
          final field = QcCustomTableField(
            fieldId: match.fieldId,
            tableId: id,
            tableRemoteId: match.tableRemoteId,
            remoteId: match.remoteId,
            label: incoming.label.trim(),
            colType: incoming.colType,
            required: incoming.required,
            sortOrder: i,
            createdAt: match.createdAt,
            updatedAt: now,
            createdBy: match.createdBy,
            updatedBy: _guard.uid,
            version: match.version,
          );
          await _local.updateField(field, exec: txn);
          final fieldRow = await _stamped(
            txn,
            'qc_custom_table_fields',
            'field_id',
            field.fieldId!,
          );
          await _enqueue(
            txn,
            entityType: 'qcCustomTableField',
            row: fieldRow,
            operation: 'update',
          );
        } else {
          await _insertFieldsWithFields(txn, id, existing.table.remoteId, [
            incoming,
          ], startOrder: i);
        }
      }
      for (final match in byId.values) {
        if (keptIds.contains(match.fieldId)) continue;
        // Tombstoned, not deleted: the values that referenced it keep their
        // keys, so a later re-add of a similar column cannot be confused
        // with history.
        await _local.tombstoneField(match.fieldId!, now, exec: txn);
        await _enqueue(
          txn,
          entityType: 'qcCustomTableField',
          row: {...match.toMap(), 'deleted_at': now, 'updated_at': now},
          operation: 'tombstone',
        );
      }
    });
  }

  @override
  Future<void> deleteTable(int tableId) async {
    _check(Permission.qcWrite);
    await _transaction((txn) async {
      final bundle = await _local.getTableBundle(tableId, exec: txn);
      if (bundle == null) {
        throw NotFoundError(
          AppText.t(
            'الجدول غير موجود ($tableId)',
            'Record not found (No QC custom table with id $tableId)',
          ),
        );
      }
      final rows = await _local.listRows(tableId, limit: 50000, exec: txn);
      final now = nowIso();
      await _local.tombstoneAll(tableId, now, exec: txn);
      // Every child is tombstoned with its own version bump so the pull on
      // another device converges on the same shape: an orphaned record of a
      // dead table must not resurrect as a chip there.
      for (final field in bundle.fields) {
        await _enqueue(
          txn,
          entityType: 'qcCustomTableField',
          row: {...field.toMap(), 'deleted_at': now, 'updated_at': now},
          operation: 'tombstone',
        );
      }
      for (final row in rows) {
        await _enqueue(
          txn,
          entityType: 'qcCustomTableRow',
          row: {...row.toMap(), 'deleted_at': now, 'updated_at': now},
          operation: 'tombstone',
        );
      }
      await _enqueue(
        txn,
        entityType: 'qcCustomTable',
        row: {...bundle.table.toMap(), 'deleted_at': now, 'updated_at': now},
        operation: 'tombstone',
        auditAction: AuditAction.customTableDeleted,
      );
    });
  }

  // ── Records ────────────────────────────────────────────────────────────

  @override
  Future<int> addRow(QcCustomTableRow row) async {
    _check(Permission.qcWrite);
    final tableId = row.tableId;
    if (tableId == null) {
      throw ValidationError(
        AppText.t('سجل بلا جدول', 'A record needs its table'),
      );
    }
    return _transaction((txn) async {
      final bundle = await _local.getTableBundle(tableId, exec: txn);
      if (bundle == null) {
        throw NotFoundError(
          AppText.t(
            'الجدول غير موجود ($tableId)',
            'Record not found (No QC custom table with id $tableId)',
          ),
        );
      }
      final values = _validateValues(bundle.fields, row.values);
      final now = nowIso();
      final fresh = QcCustomTableRow(
        tableId: tableId,
        tableRemoteId: bundle.table.remoteId,
        valuesJson: convert.jsonEncode(values),
        note: row.note.trim(),
        recordedAt: row.recordedAt.isNotEmpty ? row.recordedAt : now,
        recordedBy: _guard.uid,
        recordedByName: _actorName,
        createdAt: now,
        updatedAt: now,
        createdBy: _guard.uid,
        updatedBy: _guard.uid,
      );
      final rowId = await _local.insertRow(fresh, exec: txn);
      final freshRow = await _stamped(
        txn,
        'qc_custom_table_rows',
        'row_id',
        rowId,
      );
      await _enqueue(
        txn,
        entityType: 'qcCustomTableRow',
        row: freshRow,
        operation: 'create',
        auditAction: AuditAction.customRowRecorded,
      );
      return rowId;
    });
  }

  @override
  Future<void> saveRow(QcCustomTableRow row) async {
    _check(Permission.qcWrite);
    final rowId = row.rowId;
    if (rowId == null) {
      throw ValidationError(
        AppText.t(
          'لا يمكن حفظ سجل بلا معرّف',
          'Cannot save a record with no id',
        ),
      );
    }
    await _transaction((txn) async {
      final existing = await _local.getRow(rowId, exec: txn);
      if (existing == null) {
        throw NotFoundError(
          AppText.t(
            'السجل غير موجود ($rowId)',
            'Record not found (No QC custom table record with id $rowId)',
          ),
        );
      }
      final bundle = await _local.getTableBundle(existing.tableId!, exec: txn);
      if (bundle == null) {
        throw NotFoundError(
          AppText.t(
            'الجدول غير موجود (${existing.tableId})',
            'Record not found (No QC custom table with id ${existing.tableId})',
          ),
        );
      }
      // Values are merged over the existing ones so a partial update never
      // blanks what the caller did not intend to touch; then re-validated
      // against the live columns as a whole.
      final merged = {...existing.values, ...row.values}
        ..removeWhere((_, v) => v == null);
      _pruneForeignValues(merged, bundle.fields);
      final values = _validateValues(bundle.fields, merged);
      final now = nowIso();
      final fresh = QcCustomTableRow(
        rowId: rowId,
        tableId: existing.tableId,
        tableRemoteId: existing.tableRemoteId,
        valuesJson: convert.jsonEncode(values),
        // The edit form submits the complete record (all fields pre-filled
        // from the row), so the submitted note replaces the stored one —
        // clearing the note through the form must clear it for real.
        note: row.note,
        recordedAt: existing.recordedAt,
        // The «بواسطة» name follows the last editor: it only moves when a
        // record is edited, so the column always names who touched it last.
        recordedBy: _guard.uid,
        recordedByName: _actorName,
        createdAt: existing.createdAt,
        updatedAt: now,
        createdBy: existing.createdBy,
        updatedBy: _guard.uid,
        version: existing.version,
      );
      await _local.updateRow(fresh, exec: txn);
      final freshRow = await _stamped(
        txn,
        'qc_custom_table_rows',
        'row_id',
        rowId,
      );
      await _enqueue(
        txn,
        entityType: 'qcCustomTableRow',
        row: freshRow,
        operation: 'update',
        auditAction: AuditAction.customRowRecorded,
      );
    });
  }

  @override
  Future<void> deleteRow(int rowId) async {
    _check(Permission.qcWrite);
    await _transaction((txn) async {
      final existing = await _local.getRow(rowId, exec: txn);
      if (existing == null) {
        throw NotFoundError(
          AppText.t(
            'السجل غير موجود ($rowId)',
            'Record not found (No QC custom table record with id $rowId)',
          ),
        );
      }
      final now = nowIso();
      await _local.tombstoneRow(rowId, now, exec: txn);
      await _enqueue(
        txn,
        entityType: 'qcCustomTableRow',
        row: {...existing.toMap(), 'deleted_at': now, 'updated_at': now},
        operation: 'tombstone',
        auditAction: AuditAction.customRowDeleted,
      );
    });
  }

  // ── Validation ─────────────────────────────────────────────────────────

  void _validateDefinition(String title, List<QcCustomTableField> fields) {
    if (title.trim().isEmpty) {
      throw ValidationError(
        AppText.t('الجدول يحتاج إلى اسم', 'A table needs a title'),
      );
    }
    if (fields.isEmpty) {
      throw ValidationError(
        AppText.t(
          'أضف عموداً واحداً على الأقل',
          'Add at least one column before saving',
        ),
      );
    }
    final seen = <String>{};
    for (final field in fields) {
      final label = field.label.trim();
      if (label.isEmpty) {
        throw ValidationError(
          AppText.t('كل عمود يحتاج إلى اسم', 'Every column needs a name'),
        );
      }
      if (!seen.add(label.toLowerCase())) {
        throw ValidationError(
          AppText.t(
            'اسم العمود مكرر: $label',
            'Duplicated column name: $label',
          ),
        );
      }
      if (!QcCustomColType.all.contains(field.colType)) {
        throw ValidationError(
          AppText.t(
            'نوع العمود غير مدعوم: ${field.colType}',
            'Unsupported column type: ${field.colType}',
          ),
        );
      }
    }
  }

  /// Drops values pointing at columns this table no longer (or never did)
  /// have. Called before validating a partial update so a stale caller
  /// cannot smuggle data in under a retired key.
  void _pruneForeignValues(
    Map<String, dynamic> values,
    List<QcCustomTableField> fields,
  ) {
    final aliveKeys = {
      for (final f in fields)
        if (f.remoteId.isNotEmpty) f.remoteId,
    };
    values.removeWhere((key, _) => !aliveKeys.contains(key));
  }

  Map<String, dynamic> _validateValues(
    List<QcCustomTableField> fields,
    Map<String, dynamic> values,
  ) {
    final byKey = {
      for (final f in fields)
        if (f.remoteId.isNotEmpty) f.remoteId: f,
    };
    final out = <String, dynamic>{};
    for (final entry in values.entries) {
      final field = byKey[entry.key];
      if (field == null) {
        throw ValidationError(
          AppText.t(
            'قيمة بلا عمود حالي في هذا الجدول',
            'A value belongs to no current column of this table',
          ),
        );
      }
      final value = entry.value;
      if (value == null || (value is String && value.trim().isEmpty)) {
        if (field.required) {
          throw ValidationError(
            AppText.t('"${field.label}" مطلوب', '"${field.label}" is required'),
          );
        }
        continue; // An optional blank stays absent rather than "empty".
      }
      if (field.colType == QcCustomColType.number) {
        // bool is not num in Dart, so a mislabelled checkbox cannot sneak in.
        if (value is! num) {
          throw ValidationError(
            AppText.t(
              '"${field.label}" يحتاج رقماً',
              '"${field.label}" needs a number',
            ),
          );
        }
        out[entry.key] = value;
      } else if (field.colType == QcCustomColType.date) {
        final text = '$value';
        // 'YYYY-MM-DD' is the shortest legal form; `tryParse` keeps strict
        // calendar validation (no 30 February), nothing shorter is a date.
        if (text.length < 10 || DateTime.tryParse(text) == null) {
          throw ValidationError(
            AppText.t(
              '"${field.label}" يحتاج تاريخاً صحيحاً',
              '"${field.label}" needs a valid date',
            ),
          );
        }
        out[entry.key] = text;
      } else {
        if (value is! String) {
          throw ValidationError(
            AppText.t(
              '"${field.label}" يحتاج نصاً',
              '"${field.label}" needs text',
            ),
          );
        }
        out[entry.key] = value;
      }
    }
    // Required check also fires for completely absent columns.
    for (final field in fields) {
      if (!field.required) continue;
      final value = out[field.remoteId];
      if (value == null || (value is String && value.trim().isEmpty)) {
        throw ValidationError(
          AppText.t('"${field.label}" مطلوب', '"${field.label}" is required'),
        );
      }
    }
    return out;
  }
}
