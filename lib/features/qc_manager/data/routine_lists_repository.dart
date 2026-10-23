import 'package:sqflite/sqflite.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_inspection.dart';
import '../domain/qc_template.dart';
import '../domain/routine_repository.dart';
import 'offline_first_qc_repository.dart' show QcAuditAction;
import 'qc_audit_repo.dart';
import 'qc_repo.dart';
import 'qc_sync_writer.dart';

// Re-export the contract and its models so existing importers of this file
// (tests, utilities) keep seeing them under the old path.
export '../domain/routine_repository.dart';

/// Simple daily/monthly routine lists over the existing QC checklist tables.
///
/// What is intentionally gone compared with the old template flow: versions,
/// publish/approve/archive lifecycles, scoring and NC generation. A list is
/// edited in place; opening it resolves this period's sheet (auto-created);
/// checking a box stamps who did it; past periods are immutable history.
///
/// ## The sync seam (plan P8)
/// When a [SyncQueue] is handed in, every write here also queues the touched
/// rows through the same [QcSyncWriter] the QC facades use (checklist
/// templates/items, sheets, checkbox responses and `qc_task_log` entries —
/// the log is append-only remote-side as well). Without a queue the class
/// keeps its old purely-local behavior; the doc comment above about
/// "QC stays offline-local" describes that legacy mode only.
///
/// The domain surface lives in `../domain/routine_repository.dart`
/// ([RoutineListsRepository]); presentation never imports this file.
class RoutineListsRepositoryImpl implements RoutineListsRepository {
  RoutineListsRepositoryImpl({
    required this.dbHelper,
    required this.guard,
    required this.audit,
    required this.templates,
    required this.inspections,
    SyncQueue? queue,
    AuditLogger? syncAudit,
  }) : sync = queue == null
       ? null
       : QcSyncWriter(queue: queue, guard: guard, syncAudit: syncAudit);

  final DatabaseHelper dbHelper;
  final WriteGuard guard;
  final QcAuditRepo audit;
  final QcTemplateRepo templates;
  final QcInspectionRepo inspections;

  /// Optional sync seam (plan P8). Null — or a writer without a bound
  /// account — keeps every write purely local.
  final QcSyncWriter? sync;

  /// Bare `yyyy-MM-dd` of today (local).
  static String todayKey() => todayIso().substring(0, 10);

  /// Bare `yyyy-MM` of this month (local).
  static String monthKey() => todayKey().substring(0, 7);

  void _check() {
    if (guard.allows(Permission.qcWrite.id)) return;
    throw AuthorizationError(AppErrors.notAuthorizedForOperation);
  }

  // ── Sync seam (plan P8) ────────────────────────────────────────────
  // Every helper below is a silent no-op when no queue was handed in (or the
  // account is not bound), so the legacy purely-local callers keep working.

  Future<void> _queueRow(
    DatabaseExecutor txn, {
    required String entityType,
    required String table,
    required String pk,
    Object? id,
  }) async {
    if (sync == null) return;
    await sync!.queueRow(
      txn,
      entityType: entityType,
      table: table,
      pk: pk,
      id: id,
    );
  }

  Future<void> _queueChildRows(
    DatabaseExecutor txn, {
    required String table,
    required String pk,
    required String entityType,
    required String where,
    List<Object?> whereArgs = const [],
  }) async {
    if (sync == null) return;
    await sync!.queueChildRows(
      txn,
      table: table,
      pk: pk,
      entityType: entityType,
      where: where,
      whereArgs: whereArgs,
    );
  }

  /// Tombstones alive children (histories keep pointing at them) and queues
  /// each — matching `_QcWrite.tombstoneChildren` in the QC facades.
  Future<void> _tombstoneChildren(
    DatabaseExecutor txn, {
    required String table,
    required String pk,
    required String entityType,
    required String containerColumn,
    required int containerId,
  }) async {
    if (sync == null) return;
    final stamp = nowIso();
    final alive = await txn.query(
      table,
      columns: [pk],
      where: 'deleted_at IS NULL AND $containerColumn = ?',
      whereArgs: [containerId],
    );
    if (alive.isEmpty) return;
    await txn.update(
      table,
      {'deleted_at': stamp},
      where: 'deleted_at IS NULL AND $containerColumn = ?',
      whereArgs: [containerId],
    );
    for (final r in alive) {
      await _queueRow(
        txn,
        entityType: entityType,
        table: table,
        pk: pk,
        id: (r[pk] as num?)?.toInt(),
      );
    }
  }

  String get _uid => guard.uid;

  String _displayName() {
    try {
      final actor = audit.actorReader?.call();
      if (actor != null && actor.name.trim().isNotEmpty) {
        return actor.name.trim();
      }
    } on Object {
      // Fall through to the email fallback.
    }
    return guard.email;
  }

  // ── Lists ──────────────────────────────────────────────────────────

  /// Every non-deleted list with its progress in the current period.
  /// Templates on `once`/`weekly` behave as daily (period = day).
  @override
  Future<List<RoutineList>> listRoutineLists() async {
    final db = await dbHelper.database;
    final rows = await db.query(
      'qc_templates',
      where: qcAliveFilter,
      orderBy: 'name COLLATE NOCASE ASC',
    );
    final out = <RoutineList>[];
    for (final r in rows) {
      final template = QcTemplate.fromMap(Map<String, dynamic>.from(r));
      final id = template.templateId!;
      final total = await _itemCount(db, id);
      final sheetId = await _periodSheetId(db, id, template.recurrence);
      var done = 0;
      if (sheetId != null) {
        done = await _doneCount(db, sheetId);
      }
      out.add(
        RoutineList(
          template: template,
          totalItems: total,
          doneCount: done,
          sheetId: sheetId,
        ),
      );
    }
    return out;
  }

  Future<int> _itemCount(DatabaseExecutor txn, int templateId) async {
    final rows = await txn.rawQuery(
      'SELECT COUNT(*) AS n FROM qc_items WHERE ${qcAlive('template_id = ?')}',
      [templateId],
    );
    return ((rows.first['n'] as num?)?.toInt() ?? 0);
  }

  Future<int> _doneCount(DatabaseExecutor txn, int inspectionId) async {
    final rows = await txn.rawQuery(
      'SELECT COUNT(*) AS n FROM qc_responses '
      "WHERE inspection_id = ? AND measured_at IS NOT NULL AND measured_at != ''",
      [inspectionId],
    );
    return ((rows.first['n'] as num?)?.toInt() ?? 0);
  }

  /// Creates a list (published from birth: no draft/publish lifecycle) or
  /// edits one in place (name/dept/recurrence/items). Items are a flat
  /// ordered label list; they live under one implicit section.
  @override
  Future<int> saveRoutineList({
    int? templateId,
    required String name,
    String dept = '',
    String recurrence = QcRecurrence.daily,
    List<String> items = const [],
  }) async {
    _check();
    final cleanName = name.trim();
    if (cleanName.isEmpty) {
      throw ValidationError(
        AppText.t('القائمة تحتاج إلى اسم', 'A list needs a name'),
      );
    }
    final cleanRecurrence =
        recurrence == QcRecurrence.monthly ? QcRecurrence.monthly : QcRecurrence.daily;
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final stamp = nowIso();
      int id;
      if (templateId == null) {
        id = await txn.insert('qc_templates', {
          'name': cleanName,
          'dept': dept.trim(),
          'recurrence': cleanRecurrence,
          'version': 1,
          'is_published': 1,
          'is_archived': 0,
          'created_at': stamp,
          'updated_at': stamp,
          'created_by': _uid,
          'updated_by': _uid,
        });
        await audit.append(
          entityType: QcAuditEntity.template,
          entityId: '$id',
          action: QcAuditAction.templateCreated,
          after: {'name': cleanName, 'recurrence': cleanRecurrence},
          meta: {'routine': true},
          exec: txn,
        );
      } else {
        final existing = await txn.query(
          'qc_templates',
          where: qcAlive('template_id = ?'),
          whereArgs: [templateId],
          limit: 1,
        );
        if (existing.isEmpty) {
          throw NotFoundError(
            AppText.t('السجل غير موجود', 'Record not found'),
          );
        }
        id = templateId;
        await txn.update(
          'qc_templates',
          {
            'name': cleanName,
            'dept': dept.trim(),
            'recurrence': cleanRecurrence,
            'updated_at': stamp,
            'updated_by': _uid,
          },
          where: 'template_id = ?',
          whereArgs: [id],
        );
        await audit.append(
          entityType: QcAuditEntity.template,
          entityId: '$id',
          action: QcAuditAction.templateSaved,
          before: Map<String, dynamic>.from(existing.first),
          after: (await txn.query(
            'qc_templates',
            where: 'template_id = ?',
            whereArgs: [id],
            limit: 1,
          ))
              .first,
          meta: {'routine': true},
          exec: txn,
        );
      }
      await _reconcileItems(txn, id, items, stamp);
      await _queueRow(
        txn,
        entityType: 'qcTemplate',
        table: 'qc_templates',
        pk: 'template_id',
        id: id,
      );
      // The implicit section (created lazily by _reconcileItems) and every
      // item row — created / retitled / retired — replicate as their own
      // create/update/tombstone queue entries.
      await _queueChildRows(
        txn,
        table: 'qc_sections',
        pk: 'section_id',
        entityType: 'qcSection',
        where: 'template_id = ?',
        whereArgs: [id],
      );
      await _queueChildRows(
        txn,
        table: 'qc_items',
        pk: 'item_id',
        entityType: 'qcItem',
        where: 'template_id = ?',
        whereArgs: [id],
      );
      return id;
    });
  }

  /// One implicit section per list, created lazily and hidden from the UI.
  Future<int> _sectionId(DatabaseExecutor txn, int templateId) async {
    final rows = await txn.query(
      'qc_sections',
      columns: ['section_id'],
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
      orderBy: 'order_index ASC',
      limit: 1,
    );
    if (rows.isNotEmpty) return (rows.first['section_id'] as num).toInt();
    return txn.insert('qc_sections', {
      'template_id': templateId,
      'title': AppText.t('العناصر', 'Items'),
      'order_index': 0,
      'is_collapsible': 1,
      'required_all': 0,
      'conditional_rule_json': '',
    });
  }

  /// Labels in list order become the items: matching rows are updated,
  /// missing ones are retired (soft delete, history keeps pointing at
  /// them), new ones are appended.
  Future<void> _reconcileItems(
    DatabaseExecutor txn,
    int templateId,
    List<String> labels,
    String stamp,
  ) async {
    final sectionId = await _sectionId(txn, templateId);
    final existing = await txn.query(
      'qc_items',
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
      orderBy: 'order_index ASC',
    );
    final clean = [
      for (final l in labels)
        if (l.trim().isNotEmpty) l.trim(),
    ];
    final seen = <int>{};
    for (var i = 0; i < clean.length; i++) {
      if (i < existing.length) {
        final id = (existing[i]['item_id'] as num).toInt();
        seen.add(id);
        await txn.update(
          'qc_items',
          {'label': clean[i], 'order_index': i},
          where: 'item_id = ?',
          whereArgs: [id],
        );
      } else {
        await txn.insert('qc_items', {
          'section_id': sectionId,
          'template_id': templateId,
          'label': clean[i],
          'item_type': QcItemType.passFail,
          'order_index': i,
          'required': 1,
          'allow_na': 1,
          'is_critical': 0,
          'require_evidence_if_fail': 0,
          'require_evidence_if_value': 0,
          'default_value': '',
          'options_json': '',
          'unit': '',
          'tolerance_type': 'abs',
          'validation_rule_json': '',
          'conditional_show_json': '',
          'fail_trigger_json': '',
          'help_text': '',
          'defect_code': '',
        });
      }
    }
    for (var i = clean.length; i < existing.length; i++) {
      final id = (existing[i]['item_id'] as num).toInt();
      await txn.update(
        'qc_items',
        {'deleted_at': stamp},
        where: 'item_id = ?',
        whereArgs: [id],
      );
    }
  }

  /// Labels of a list's live items, display order. Used by the editor so
  /// opening it never creates a sheet as a side effect.
  @override
  Future<List<String>> listItemLabels(int templateId) async {
    final db = await dbHelper.database;
    final rows = await db.query(
      'qc_items',
      columns: ['label'],
      where: qcAlive('template_id = ?'),
      whereArgs: [templateId],
      orderBy: 'order_index ASC',
    );
    return [for (final r in rows) '${r['label'] ?? ''}'];
  }

  @override
  Future<void> deleteRoutineList(int templateId) async {
    _check();
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final existing = await txn.query(
        'qc_templates',
        where: qcAlive('template_id = ?'),
        whereArgs: [templateId],
        limit: 1,
      );
      if (existing.isEmpty) {
        throw NotFoundError(AppText.t('السجل غير موجود', 'Record not found'));
      }
      await templates.deleteTemplate(templateId, exec: txn);
      await _tombstoneChildren(
        txn,
        table: 'qc_sections',
        pk: 'section_id',
        entityType: 'qcSection',
        containerColumn: 'template_id',
        containerId: templateId,
      );
      await _tombstoneChildren(
        txn,
        table: 'qc_items',
        pk: 'item_id',
        entityType: 'qcItem',
        containerColumn: 'template_id',
        containerId: templateId,
      );
      await audit.append(
        entityType: QcAuditEntity.template,
        entityId: '$templateId',
        action: QcAuditAction.templateDeleted,
        before: Map<String, dynamic>.from(existing.first),
        meta: {'routine': true},
        exec: txn,
      );
      await _queueRow(
        txn,
        entityType: 'qcTemplate',
        table: 'qc_templates',
        pk: 'template_id',
        id: templateId,
      );
    });
  }

  // ── Period sheets ──────────────────────────────────────────────────

  /// This period's sheet id for [templateId], or null when unopened.
  Future<int?> _periodSheetId(
    DatabaseExecutor txn,
    int templateId,
    String recurrence,
  ) async {
    if (recurrence == QcRecurrence.monthly) {
      final rows = await txn.rawQuery(
        'SELECT inspection_id AS id FROM qc_inspections '
        'WHERE ${qcAlive('template_id = ?')} '
        "AND substr(COALESCE(inspection_date,created_at,''),1,7) = ? "
        'ORDER BY inspection_date DESC, inspection_id DESC LIMIT 1',
        [templateId, monthKey()],
      );
      if (rows.isEmpty) return null;
      return (rows.first['id'] as num).toInt();
    }
    final rows = await txn.rawQuery(
      'SELECT inspection_id AS id FROM qc_inspections '
      'WHERE ${qcAlive('template_id = ?')} '
      "AND substr(COALESCE(inspection_date,created_at,''),1,10) = ? "
      'ORDER BY inspection_id DESC LIMIT 1',
      [templateId, todayKey()],
    );
    if (rows.isEmpty) return null;
    return (rows.first['id'] as num).toInt();
  }

  /// Opens this period's sheet, creating it (with blank rows) on first use.
  /// Tomorrow — or next month — a fresh sheet is created instead, so the
  /// list "resets" by itself and the old sheet becomes history.
  @override
  Future<RoutineSheet> openPeriodSheet(int templateId) async {
    _check();
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final tplRows = await txn.query(
        'qc_templates',
        where: qcAlive('template_id = ?'),
        whereArgs: [templateId],
        limit: 1,
      );
      if (tplRows.isEmpty) {
        throw NotFoundError(AppText.t('السجل غير موجود', 'Record not found'));
      }
      final template = QcTemplate.fromMap(
        Map<String, dynamic>.from(tplRows.first),
      );
      var sheetId = await _periodSheetId(txn, templateId, template.recurrence);
      if (sheetId == null) {
        final stamp = nowIso();
        final inspection = QcInspection(
          templateId: templateId,
          inspectionDate: todayKey(),
          createdAt: stamp,
          updatedAt: stamp,
          createdBy: _uid,
          inspectorId: _uid,
          inspectorName: _displayName(),
        );
        sheetId = await inspections.createInspection(inspection, exec: txn);
        await audit.append(
          entityType: QcAuditEntity.inspection,
          entityId: '$sheetId',
          action: QcAuditAction.inspectionCreated,
          meta: {'routine': true, 'templateId': templateId},
          exec: txn,
        );
        await _queueRow(
          txn,
          entityType: 'qcInspection',
          table: 'qc_inspections',
          pk: 'inspection_id',
          id: sheetId,
        );
        await _queueChildRows(
          txn,
          table: 'qc_responses',
          pk: 'resp_id',
          entityType: 'qcResponse',
          where: 'inspection_id = ?',
          whereArgs: [sheetId],
        );
      }
      return _loadSheet(txn, sheetId);
    });
  }

  @override
  Future<RoutineSheet> loadSheet(int inspectionId) async {
    final db = await dbHelper.database;
    return _loadSheet(db, inspectionId);
  }

  Future<RoutineSheet> _loadSheet(
    DatabaseExecutor txn,
    int inspectionId,
  ) async {
    final inspRows = await txn.query(
      'qc_inspections',
      where: qcAlive('inspection_id = ?'),
      whereArgs: [inspectionId],
      limit: 1,
    );
    if (inspRows.isEmpty) {
      throw NotFoundError(AppText.t('السجل غير موجود', 'Record not found'));
    }
    final inspection = QcInspection.fromMap(
      Map<String, dynamic>.from(inspRows.first),
    );
    final tplRows = await txn.query(
      'qc_templates',
      where: 'template_id = ?',
      whereArgs: [inspection.templateId],
      limit: 1,
    );
    final template = tplRows.isEmpty
        ? QcTemplate(
            templateId: inspection.templateId,
            name: '-',
            createdAt: '',
            updatedAt: '',
          )
        : QcTemplate.fromMap(Map<String, dynamic>.from(tplRows.first));
    final rows = await txn.rawQuery(
      '''
      SELECT i.*, r.resp_id, r.inspection_id AS r_inspection_id,
             r.result, r.notes, r.measured_at, r.answered_by,
             r.answered_by_name, r.created_at AS r_created_at,
             r.updated_at AS r_updated_at,
             (SELECT COUNT(*) FROM qc_task_log lg
               WHERE lg.inspection_id = ? AND lg.item_id = i.item_id) AS task_log_count,
             (SELECT lg.logged_at FROM qc_task_log lg
               WHERE lg.inspection_id = ? AND lg.item_id = i.item_id
               ORDER BY lg.log_id DESC LIMIT 1) AS last_task_log_at,
             (SELECT lg.logged_by_name FROM qc_task_log lg
               WHERE lg.inspection_id = ? AND lg.item_id = i.item_id
               ORDER BY lg.log_id DESC LIMIT 1) AS last_task_log_by_name
      FROM qc_items i LEFT JOIN qc_responses r
        ON r.item_id = i.item_id AND r.inspection_id = ?
      WHERE (i.deleted_at IS NULL) AND (i.template_id = ?)
      ORDER BY i.order_index ASC, i.item_id ASC
      ''',
      [inspectionId, inspectionId, inspectionId, inspectionId, inspection.templateId],
    );
    final out = <RoutineRow>[];
    for (final r in rows) {
      final item = QcItem.fromMap(Map<String, dynamic>.from(r));
      final QcResponse response;
      if (r['resp_id'] == null) {
        response = QcResponse(
          inspectionId: inspectionId,
          itemId: item.itemId!,
          result: QcResponseResult.na,
          createdAt: '',
          updatedAt: '',
        );
      } else {
        response = QcResponse(
          respId: (r['resp_id'] as num).toInt(),
          inspectionId: inspectionId,
          itemId: item.itemId!,
          result: QcResponseResult.normalize('${r['result'] ?? ''}'),
          notes: '${r['notes'] ?? ''}',
          measuredAt: '${r['measured_at'] ?? ''}',
          answeredBy: '${r['answered_by'] ?? ''}',
          answeredByName: '${r['answered_by_name'] ?? ''}',
          createdAt: '${r['r_created_at'] ?? ''}',
          updatedAt: '${r['r_updated_at'] ?? ''}',
        );
      }
        out.add(
          RoutineRow(
            item: item,
            response: response,
            taskLogCount: ((r['task_log_count'] as num?)?.toInt() ?? 0),
            lastTaskLogAt: '${r['last_task_log_at'] ?? ''}',
            lastTaskLogByName: '${r['last_task_log_by_name'] ?? ''}',
          ),
        );
    }
    final day = inspection.inspectionDate.length >= 10
        ? inspection.inspectionDate.substring(0, 10)
        : inspection.inspectionDate;
    final current = template.recurrence == QcRecurrence.monthly
        ? day.length >= 7 && day.substring(0, 7) == monthKey()
        : day == todayKey();
    return RoutineSheet(
      inspection: inspection,
      template: template,
      rows: out,
      current: current,
    );
  }

  // ── Checks ─────────────────────────────────────────────────────────

  /// Taps a checkbox: an unchecked row records Pass + who/when (and an
  /// optional note); a checked row in the *current* period unchecks back to
  /// blank. Past periods throw: history is immutable.
  @override
  Future<RoutineSheet> toggleCheck({
    required int inspectionId,
    required int itemId,
    String note = '',
  }) async {
    _check();
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final sheet = await _loadSheet(txn, inspectionId);
      if (!sheet.current) {
        throw ValidationError(
          AppText.t(
            'الفترة انتهت — لا يمكن تعديل سجل سابق',
            'Period is over — past sheets cannot be edited',
          ),
        );
      }
      final row = sheet.rows.where((r) => r.item.itemId == itemId).toList();
      if (row.isEmpty) {
        throw NotFoundError(AppText.t('السجل غير موجود', 'Record not found'));
      }
      final current = row.first;
      final stamp = nowIso();
      if (current.recorded) {
        if (current.response.respId == null) {
          throw StateError('Routine row without a response row');
        }
        await txn.update(
          'qc_responses',
          {
            'result': QcResponseResult.na,
            'notes': '',
            'measured_at': '',
            'answered_by': '',
            'answered_by_name': '',
            'updated_at': stamp,
          },
          where: 'resp_id = ?',
          whereArgs: [current.response.respId],
        );
        await audit.append(
          entityType: QcAuditEntity.response,
          entityId: '${current.response.respId}',
          action: QcAuditAction.itemAnswered,
          before: current.response.toMap(),
          meta: {
            'routine': true,
            'inspectionId': inspectionId,
            'itemId': itemId,
            'unchecked': true,
          },
          exec: txn,
        );
        await _queueRow(
          txn,
          entityType: 'qcResponse',
          table: 'qc_responses',
          pk: 'resp_id',
          id: current.response.respId,
        );
      } else {
        final actorName = _displayName();
        if (current.response.respId == null) {
          final respId = await txn.insert('qc_responses', {
            'inspection_id': inspectionId,
            'item_id': itemId,
            'section_id': current.item.sectionId,
            'result': QcResponseResult.pass,
            'notes': note.trim(),
            'measured_at': stamp,
            'answered_by': _uid,
            'answered_by_name': actorName,
            'created_at': stamp,
            'updated_at': stamp,
          });
          await audit.append(
            entityType: QcAuditEntity.response,
            entityId: '$respId',
            action: QcAuditAction.itemAnswered,
            after: {'result': QcResponseResult.pass, 'itemId': itemId},
            meta: {'routine': true, 'inspectionId': inspectionId},
            exec: txn,
          );
          await _queueRow(
            txn,
            entityType: 'qcResponse',
            table: 'qc_responses',
            pk: 'resp_id',
            id: respId,
          );
        } else {
          await txn.update(
            'qc_responses',
            {
              'result': QcResponseResult.pass,
              'notes': note.trim(),
              'measured_at': stamp,
              'answered_by': _uid,
              'answered_by_name': actorName,
              'updated_at': stamp,
            },
            where: 'resp_id = ?',
            whereArgs: [current.response.respId],
          );
          await audit.append(
            entityType: QcAuditEntity.response,
            entityId: '${current.response.respId}',
            action: QcAuditAction.itemAnswered,
            before: current.response.toMap(),
            meta: {'routine': true, 'inspectionId': inspectionId},
            exec: txn,
          );
          await _queueRow(
            txn,
            entityType: 'qcResponse',
            table: 'qc_responses',
            pk: 'resp_id',
            id: current.response.respId,
          );
        }
      }
      return _loadSheet(txn, inspectionId);
    });
  }

  /// Presses the per-task "done" button: appends one `qc_task_log` entry
  /// (this moment + who) and — for scorecard consistency — also marks the
  /// checkbox row done for this period with the same stamp. Every press is
  /// a NEW log line, so a task handled three times today shows three
  /// entries (hour + user each); the checkbox alone yields only the last.
  /// Past periods throw: history is immutable, same as [toggleCheck].
  @override
  Future<RoutineSheet> recordDone({
    required int inspectionId,
    required int itemId,
    String note = '',
  }) async {
    _check();
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final sheet = await _loadSheet(txn, inspectionId);
      if (!sheet.current) {
        throw ValidationError(
          AppText.t(
            'الفترة انتهت — لا يمكن تعديل سجل سابق',
            'Period is over — past sheets cannot be edited',
          ),
        );
      }
      final row = sheet.rows.where((r) => r.item.itemId == itemId).toList();
      if (row.isEmpty) {
        throw NotFoundError(AppText.t('السجل غير موجود', 'Record not found'));
      }
      final current = row.first;
      final stamp = nowIso();
      final actorName = _displayName();

      // Keep the period scorecard in sync: the row reads as done with the
      // newest stamp. The EXISTING notes win when the press carries none.
      final mergedNote = note.trim().isNotEmpty ? note.trim() : current.response.notes;
      if (current.response.respId == null) {
        final respId = await txn.insert('qc_responses', {
          'inspection_id': inspectionId,
          'item_id': itemId,
          'section_id': current.item.sectionId,
          'result': QcResponseResult.pass,
          'notes': mergedNote,
          'measured_at': stamp,
          'answered_by': _uid,
          'answered_by_name': actorName,
          'created_at': stamp,
          'updated_at': stamp,
        });
        await audit.append(
          entityType: QcAuditEntity.response,
          entityId: '$respId',
          action: QcAuditAction.itemAnswered,
          after: {'result': QcResponseResult.pass, 'itemId': itemId},
          meta: {
            'routine': true,
            'inspectionId': inspectionId,
            'taskLog': true,
          },
          exec: txn,
        );
        await _queueRow(
          txn,
          entityType: 'qcResponse',
          table: 'qc_responses',
          pk: 'resp_id',
          id: respId,
        );
      } else {
        final respId = current.response.respId!;
        await txn.update(
          'qc_responses',
          {
            'result': QcResponseResult.pass,
            'notes': mergedNote,
            'measured_at': stamp,
            'answered_by': _uid,
            'answered_by_name': actorName,
            'updated_at': stamp,
          },
          where: 'resp_id = ?',
          whereArgs: [respId],
        );
        await audit.append(
          entityType: QcAuditEntity.response,
          entityId: '$respId',
          action: QcAuditAction.itemAnswered,
          before: current.response.toMap(),
          meta: {
            'routine': true,
            'inspectionId': inspectionId,
            'taskLog': true,
          },
          exec: txn,
        );
        await _queueRow(
          txn,
          entityType: 'qcResponse',
          table: 'qc_responses',
          pk: 'resp_id',
          id: respId,
        );
      }

      final logId = await txn.insert('qc_task_log', {
        'inspection_id': inspectionId,
        'template_id': sheet.inspection.templateId,
        'item_id': itemId,
        'note': note.trim(),
        'logged_by': _uid,
        'logged_by_name': actorName,
        'logged_at': stamp,
      });
      await _queueRow(
        txn,
        entityType: 'qcTaskLog',
        table: 'qc_task_log',
        pk: 'log_id',
        id: logId,
      );
      return _loadSheet(txn, inspectionId);
    });
  }

  /// Every logged completion of [itemId] (all items when null) on the sheet,
  /// newest first — what the log dialog shows.
  @override
  Future<List<QcTaskLog>> taskLogs(int inspectionId, {int? itemId}) async {
    final db = await dbHelper.database;
    final rows = await db.query(
      'qc_task_log',
      where: itemId == null ? 'inspection_id = ?' : 'inspection_id = ? AND item_id = ?',
      whereArgs: itemId == null ? [inspectionId] : [inspectionId, itemId],
      orderBy: 'log_id DESC',
    );
    return [
      for (final r in rows) QcTaskLog.fromMap(Map<String, dynamic>.from(r)),
    ];
  }

  // ── History ────────────────────────────────────────────────────────

  /// Past and current sheets with scorecards, newest first.
  @override
  Future<List<RoutineHistoryEntry>> sheetHistory([
    RoutineHistoryFilters filters = const RoutineHistoryFilters(),
  ]) async {
    final db = await dbHelper.database;
    final clauses = <String>['i.deleted_at IS NULL'];
    final values = <Object?>[];
    if (filters.templateId != null) {
      clauses.add('i.template_id = ?');
      values.add(filters.templateId);
    }
    if (filters.from != null && filters.from!.trim().isNotEmpty) {
      clauses.add('substr(COALESCE(i.inspection_date,i.created_at,\'\'),1,10) >= ?');
      values.add(filters.from!.trim());
    }
    if (filters.to != null && filters.to!.trim().isNotEmpty) {
      clauses.add('substr(COALESCE(i.inspection_date,i.created_at,\'\'),1,10) <= ?');
      values.add(filters.to!.trim());
    }
    final person = filters.person.trim();
    if (person.isNotEmpty) {
      clauses.add(
        'EXISTS (SELECT 1 FROM qc_responses r WHERE r.inspection_id = i.inspection_id '
        "AND (r.answered_by = ? OR r.answered_by_name LIKE '%' || ? || '%'))",
      );
      values.add(person);
      values.add(person);
    }
    final query = filters.itemQuery.trim();
    if (query.isNotEmpty) {
      clauses.add(
        'EXISTS (SELECT 1 FROM qc_responses r JOIN qc_items it ON it.item_id = r.item_id '
        "WHERE r.inspection_id = i.inspection_id AND it.label LIKE '%' || ? || '%')",
      );
      values.add(query);
    }
    if (filters.completion == 'complete') {
      clauses.add(
        '(SELECT COUNT(*) FROM qc_responses r WHERE r.inspection_id = i.inspection_id) > 0 '
        'AND (SELECT COUNT(*) FROM qc_responses r WHERE r.inspection_id = i.inspection_id '
        "AND (r.measured_at IS NULL OR r.measured_at = '')) = 0",
      );
    } else if (filters.completion == 'incomplete') {
      clauses.add(
        '(SELECT COUNT(*) FROM qc_responses r WHERE r.inspection_id = i.inspection_id '
        "AND (r.measured_at IS NULL OR r.measured_at = '')) > 0",
      );
    }
    final rows = await db.rawQuery(
      '''
      SELECT i.*, t.name AS template_name, t.recurrence AS recurrence,
        (SELECT COUNT(*) FROM qc_responses r
          WHERE r.inspection_id = i.inspection_id) AS total_count,
        (SELECT COUNT(*) FROM qc_responses r
          WHERE r.inspection_id = i.inspection_id
          AND r.measured_at IS NOT NULL AND r.measured_at != '') AS done_count
      FROM qc_inspections i
      LEFT JOIN qc_templates t ON t.template_id = i.template_id
      WHERE ${clauses.join(' AND ')}
      ORDER BY COALESCE(i.inspection_date,i.created_at,'') DESC,
               i.inspection_id DESC
      LIMIT ? OFFSET ?
      ''',
      [...values, filters.limit, filters.offset],
    );
    // One grouped query for the whole page's members instead of one DISTINCT
    // people query per row (classic N+1 up to the page limit).
    final pageIds = <int>[
      for (final r in rows) (r['inspection_id'] as num).toInt(),
    ];
    final peopleBySheet = <int, List<String>>{};
    if (pageIds.isNotEmpty) {
      final placeholders = List.filled(pageIds.length, '?').join(',');
      final peopleRows = await db.rawQuery(
        'SELECT inspection_id, '
        'GROUP_CONCAT(DISTINCT answered_by_name) AS names '
        'FROM qc_responses '
        "WHERE inspection_id IN ($placeholders) "
        "AND answered_by_name IS NOT NULL AND answered_by_name != '' "
        'GROUP BY inspection_id',
        pageIds,
      );
      for (final p in peopleRows) {
        final names = ('${p['names'] ?? ''}')
            .split(',')
            .where((n) => n.trim().isNotEmpty)
            .toList()
          ..sort();
        peopleBySheet[(p['inspection_id'] as num).toInt()] = names;
      }
    }
    final out = <RoutineHistoryEntry>[];
    for (final r in rows) {
      final id = (r['inspection_id'] as num).toInt();
      out.add(
        RoutineHistoryEntry(
          inspection: QcInspection.fromMap(Map<String, dynamic>.from(r)),
          templateName: '${r['template_name'] ?? '-'}',
          recurrence: QcRecurrence.normalize('${r['recurrence'] ?? ''}'),
          totalCount: ((r['total_count'] as num?)?.toInt() ?? 0),
          doneCount: ((r['done_count'] as num?)?.toInt() ?? 0),
          people: peopleBySheet[id] ?? const [],
        ),
      );
    }
    return out;
  }

  /// One flat row per recorded item response, newest first: the complete
  /// "everything done" trail. The routine sheets only ever record rows via
  /// [toggleCheck]/[recordDone] with `result = pass` and a stamp, so a row
  /// with a stamp IS a completion; joining the sheet/list/item names turns
  /// the trail readable without opening each sheet.
  @override
  Future<List<RoutineDoneLog>> doneLog([
    RoutineHistoryFilters filters = const RoutineHistoryFilters(),
  ]) async {
    final db = await dbHelper.database;
    final clauses = <String>[
      'r.measured_at IS NOT NULL',
      "r.measured_at != ''",
      'i.deleted_at IS NULL',
    ];
    final values = <Object?>[];
    if (filters.templateId != null) {
      clauses.add('i.template_id = ?');
      values.add(filters.templateId);
    }
    final stampDate = 'substr(r.measured_at,1,10)';
    if (filters.from != null && filters.from!.trim().isNotEmpty) {
      clauses.add('$stampDate >= ?');
      values.add(filters.from!.trim());
    }
    if (filters.to != null && filters.to!.trim().isNotEmpty) {
      clauses.add('$stampDate <= ?');
      values.add(filters.to!.trim());
    }
    final person = filters.person.trim();
    if (person.isNotEmpty) {
      clauses.add(
        "(r.answered_by = ? OR r.answered_by_name LIKE '%' || ? || '%')",
      );
      values.add(person);
      values.add(person);
    }
    final query = filters.itemQuery.trim();
    if (query.isNotEmpty) {
      clauses.add("it.label LIKE '%' || ? || '%'");
      values.add(query);
    }
    final rows = await db.rawQuery(
      '''
      SELECT r.measured_at AS at,
        i.template_id AS template_id, i.inspection_id,
        t.name AS template_name,
        it.label AS item_label,
        COALESCE(r.answered_by_name, r.answered_by, '') AS by_name,
        COALESCE(r.notes, '') AS note
      FROM qc_responses r
      JOIN qc_inspections i ON i.inspection_id = r.inspection_id
      LEFT JOIN qc_templates t ON t.template_id = i.template_id
      LEFT JOIN qc_items it ON it.item_id = r.item_id
      WHERE ${clauses.join(' AND ')}
      ORDER BY r.measured_at DESC, r.resp_id DESC
      LIMIT ? OFFSET ?
      ''',
      [...values, filters.limit, filters.offset],
    );
    return [
      for (final r in rows)
        RoutineDoneLog.fromMap(Map<String, dynamic>.from(r)),
    ];
  }
}
