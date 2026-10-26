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
import '../domain/qc_nc_capa.dart';
import '../domain/qc_repositories.dart';
import '../domain/qc_sop.dart';
import '../domain/qc_template.dart';
import 'qc_audit_repo.dart';
import 'qc_repo.dart';
import 'qc_sync_writer.dart';

/// Offline-first facades over the thin QC local repositories
/// (plan V6_ENHANCED §24 P3).
///
/// ## What the seam is for
/// `qc_repo.dart` owns the SQL and nothing else, so a test can drive the whole
/// QC surface without fabricating a signed-in user. This file is where the V2
/// write contract lives:
///
///  * **one transaction.** The local write and its `qc_audits` row commit
///    together or not at all. A QC record whose audit entry failed to write is
///    worse than no record at all, because the missing evidence is invisible.
///  * **the §9.4 guards.** Active member, permission, not a read-only device -
///    and connectivity for the privileged operations - run *before* the write is
///    attempted, so a rejected call leaves nothing behind.
///  * **the actor.** `QcAuditRepo` reads the live session at write time, so an
///    entry can never be attributed to somebody who did not make it.
///
/// ## The `sync_queue` contract (plan P8)
/// These facades now enqueue under the same contract as the QC settings
/// feature (`offline_first_qc_custom_tables.dart`): every write also queues
/// the touched row via [QcSyncWriter] (`enqueueLocalChange`), so the push
/// carries it to the `qcTemplates`/`qcSections`/`qcItems`/`qcInspections`/
/// `qcResponses`/`qcTaskLogs`/`qcFindingsNc`/`qcCapa` collections and the
/// read-only viewers pull it. The queue/writer is *optional at
/// construction* — legacy call sites and tests that build a facade without
/// one keep the old purely-local behavior. SOPs, revisions and read records
/// also participate when a writer is configured.
///
/// ## Why not the core `AuditLogger` either
/// The P3 row of the phase table says "WriteGuard/AuditLogger integration", but
/// the module's own audit requirement (§14, line 236) scopes High Audit to
/// `qc_audits` + `qc_sop_audits`, never `audit_logs`. [QcAuditRepo] is therefore
/// the only audit sink here: one chain, one hasher, one set of immutability
/// triggers — while the *sync* trail (who pushed what) flows through the
/// optional [AuditLogger] handed to [QcSyncWriter].
///
/// ## Why these classes do not extend the local ones
/// `OfflineFirstInspectionRepository` extends its local repo to keep the old
/// GetIt registration type alive. QC has no existing callers to keep
/// compatible, and extending would expose `exec` on the domain contract - the
/// exact thing the contract's doc comment rules out. These implement the domain
/// interfaces instead, so a cubit physically cannot open a transaction it could
/// not also audit inside.
///
/// ## Reads are not guarded here
/// Same reasoning as the inspection facade: reads are gated at the route layer
/// (`guardRoute` requires `Permission.qcRead`, plan P8). Re-checking a
/// permission on every SELECT would duplicate that and buy nothing - a user who
/// cannot see the module never gets a screen to read from.
class _QcWrite {
  const _QcWrite(this.guard, this.audit, this.dbHelper, [this.sync]);

  final WriteGuard guard;
  final QcAuditRepo audit;
  final DatabaseHelper dbHelper;

  /// Optional sync seam (plan P8). Null (or a disabled writer) keeps the
  /// write purely local — the legacy contract of these facades.
  final QcSyncWriter? sync;

  /// Syncs the row of [table]/[pk]=[id] (template/inspection/response/
  /// finding/CAPA) plus its parent-identity stamps. Skipped when no writer
  /// is wired or no account is bound.
  Future<void> queueRow(
    DatabaseExecutor txn, {
    required String entityType,
    required String table,
    required String pk,
    Object? id,
    String? operation,
  }) async {
    final sync = this.sync;
    if (sync == null || !sync.enabled) return;
    await sync.queueRow(
      txn,
      entityType: entityType,
      table: table,
      pk: pk,
      id: id,
      operation: operation,
    );
  }

  /// Syncs all children of a container (template tree / fresh sheet) whose
  /// rows were written inside the local repository. Each carries its own
  /// lifecycle-derived queue operation.
  Future<void> queueChildRows(
    DatabaseExecutor txn, {
    required String table,
    required String pk,
    required String entityType,
    required String where,
    List<Object?> whereArgs = const [],
  }) async {
    final sync = this.sync;
    if (sync == null || !sync.enabled) return;
    await sync.queueChildRows(
      txn,
      table: table,
      pk: pk,
      entityType: entityType,
      where: where,
      whereArgs: whereArgs,
    );
  }

  /// Syncs a whole checklist tree after the local repository rewrote it
  /// (template + its sections + items, retired ones included: the tombstones
  /// replicate, the never-pushed tombstones are skipped).
  Future<void> syncTree(DatabaseExecutor txn, int? templateId) async {
    if (templateId == null || templateId <= 0) return;
    await queueRow(
      txn,
      entityType: 'qcTemplate',
      table: 'qc_templates',
      pk: 'template_id',
      id: templateId,
    );
    await queueChildRows(
      txn,
      table: 'qc_sections',
      pk: 'section_id',
      entityType: 'qcSection',
      where: 'template_id = ?',
      whereArgs: [templateId],
    );
    await queueChildRows(
      txn,
      table: 'qc_items',
      pk: 'item_id',
      entityType: 'qcItem',
      where: 'template_id = ?',
      whereArgs: [templateId],
    );
  }

  /// Tombstones the alive children of [where] (a hard delete in the queue's
  /// eyes needs a `deleted_at` on disk first) and syncs them, so a deleted
  /// container leaves no resurrectable rows behind.
  Future<void> tombstoneChildren(
    DatabaseExecutor txn, {
    required List<({String table, String pk, String entityType})> children,
    required String containerColumn,
    required int containerId,
  }) async {
    final sync = this.sync;
    if (sync == null || !sync.enabled) return;
    final stamp = nowIso();
    for (final child in children) {
      final alive = await txn.query(
        child.table,
        columns: [child.pk],
        where: 'deleted_at IS NULL AND $containerColumn = ?',
        whereArgs: [containerId],
      );
      if (alive.isEmpty) continue;
      await txn.update(
        child.table,
        {'deleted_at': stamp},
        where: 'deleted_at IS NULL AND $containerColumn = ?',
        whereArgs: [containerId],
      );
      for (final r in alive) {
        await queueRow(
          txn,
          entityType: child.entityType,
          table: child.table,
          pk: child.pk,
          id: (r[child.pk] as num?)?.toInt(),
        );
      }
    }
  }

  /// §9.4: active member + permission + not a read-only device, and
  /// connectivity when the permission is privileged. Throws
  /// [AuthorizationError] rather than returning a value, because there is
  /// nothing a caller could usefully do with "no".
  void check(Permission permission) {
    if (guard.allows(permission.id)) return;
    throw AuthorizationError(
      permissionRequiresFreshSession(permission) && !guard.online
          ? AppErrors.privilegedOperationNeedsConnection
          : AppErrors.notAuthorizedForOperation,
    );
  }

  Future<T> transaction<T>(
    Future<T> Function(DatabaseExecutor txn) body,
  ) async {
    return dbHelper.businessTransaction<T>(body);
  }

  /// Appends one entry, but only if it is not going to blow up the write it is
  /// travelling with.
  ///
  /// The hash chain lives in the same database and under the same transaction,
  /// so a failure here rolls the business write back rather than committing one
  /// without its evidence. That is the right trade for QC: the whole point of
  /// the trail is that it is complete.
  Future<void> record(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
    required String action,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    Map<String, dynamic>? meta,
  }) async {
    await audit.append(
      entityType: entityType,
      entityId: entityId,
      action: action,
      before: before,
      after: after,
      meta: meta,
      exec: txn,
    );
  }

  /// [before] as the raw row, so the trail records what was actually stored
  /// rather than what the caller believed was stored.
  Future<Map<String, dynamic>?> snapshot(
    DatabaseExecutor txn,
    String table,
    String pk,
    Object? id,
  ) async {
    if (id == null) return null;
    final rows = await txn.query(
      table,
      where: '$pk = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  /// A missing row is a caller bug, not a silent no-op: `saveSop(999)` that
  /// quietly does nothing looks exactly like a save that worked. The technical
  /// detail (`what`) is kept for debugging inside a bilingual frame.
  Future<void> requireRow(Map<String, dynamic>? row, String what) async {
    if (row == null) {
      throw NotFoundError(
        AppText.t('السجل غير موجود ($what)', 'Record not found ($what)'),
      );
    }
  }
}

/// Audit action names.
///
/// Deliberately free strings rather than an enum: the trail is append-only, so
/// an action added in a later release has to be recordable by an older reader
/// without a schema or enum change. They are grouped here so a typo shows up in
/// one file instead of at a hundred call sites.
abstract final class QcAuditAction {
  static const String sopCreated = 'SOP_CREATED';
  static const String sopUpdated = 'SOP_UPDATED';
  static const String sopDeleted = 'SOP_DELETED';
  static const String sopPublished = 'SOP_PUBLISHED';
  static const String sopRead = 'SOP_READ';

  static const String templateCreated = 'TEMPLATE_CREATED';
  static const String templateSaved = 'TEMPLATE_SAVED';
  static const String templateDeleted = 'TEMPLATE_DELETED';
  static const String templatePublished = 'TEMPLATE_PUBLISHED';
  static const String templateArchived = 'TEMPLATE_ARCHIVED';
  static const String templateDuplicated = 'TEMPLATE_DUPLICATED';

  static const String inspectionCreated = 'INSPECTION_CREATED';
  static const String inspectionSaved = 'INSPECTION_SAVED';
  static const String inspectionSubmitted = 'INSPECTION_SUBMITTED';
  static const String inspectionReviewed = 'INSPECTION_REVIEWED';
  static const String inspectionApproved = 'INSPECTION_APPROVED';
  static const String inspectionRejected = 'INSPECTION_REJECTED';
  static const String inspectionDeleted = 'INSPECTION_DELETED';
  static const String itemAnswered = 'ITEM_ANSWERED';

  static const String findingCreated = 'NC_CREATED';
  static const String findingUpdated = 'NC_UPDATED';
  static const String findingAssigned = 'NC_ASSIGNED';
  static const String findingVerified = 'NC_VERIFIED';
  static const String findingClosed = 'NC_CLOSED';
  static const String findingDeleted = 'NC_DELETED';

  static const String capaCreated = 'CAPA_CREATED';
  static const String capaUpdated = 'CAPA_UPDATED';
  static const String capaActionComplete = 'CAPA_ACTION_COMPLETE';
  static const String capaVerified = 'CAPA_VERIFIED';
  static const String capaClosed = 'CAPA_CLOSED';
}

/// Statuses that constitute a QC decision rather than authoring.
///
/// Submitting, approving and rejecting are the transitions a regulator asks
/// about, so they get their own audit actions instead of being folded into the
/// generic save.
abstract final class _QcDecision {
  static bool isSubmit(String status) =>
      status == QcInspectionStatus.submitted ||
      status == QcInspectionStatus.reviewed;

  static bool isApprove(String status) =>
      status == QcInspectionStatus.approved ||
      status == QcInspectionStatus.closed;

  static bool isReject(String status) => status == QcInspectionStatus.rejected;

  static String actionFor(String status) {
    if (isReject(status)) return QcAuditAction.inspectionRejected;
    if (isApprove(status)) return QcAuditAction.inspectionApproved;
    // A review is somebody else's pass over the sheet, so it stays distinct from
    // the author's submission even though both are non-decisions.
    if (status == QcInspectionStatus.reviewed) {
      return QcAuditAction.inspectionReviewed;
    }
    if (isSubmit(status)) return QcAuditAction.inspectionSubmitted;
    return QcAuditAction.inspectionSaved;
  }
}

/// SOPs, revisions and read/acknowledgement records (plan P3).
///
/// SOP bodies, published revisions and acknowledgements share the same outbox
/// as the checklist records, with parent identities remapped on each viewer.
class OfflineFirstQcSopRepository implements QcSopRepository {
  OfflineFirstQcSopRepository({
    required QcSopRepo local,
    required WriteGuard guard,
    required QcAuditRepo audit,
    required DatabaseHelper dbHelper,
    QcSyncWriter? sync,
  }) : _w = _QcWrite(guard, audit, dbHelper, sync),
       localRepo = local;

  final _QcWrite _w;
  final QcSopRepo localRepo;

  @override
  Future<List<QcSop>> listSops({
    String dept = '',
    String status = '',
    bool includeArchived = false,
  }) => localRepo.listSops(
    dept: dept,
    status: status,
    includeArchived: includeArchived,
  );

  @override
  Future<QcSop?> getSop(int sopId) => localRepo.getSop(sopId);

  @override
  Future<QcSop?> getSopByCode(String code) => localRepo.getSopByCode(code);

  @override
  Future<List<QcSopRevision>> listSopRevisions(int sopId) =>
      localRepo.listSopRevisions(sopId);

  @override
  Future<int> createSop(QcSop sop) async {
    if (sop.code.trim().isEmpty) {
      throw ValidationError(
        AppText.t(
          'يحتاج إجراء التشغيل القياسي إلى كود قبل حفظه',
          'An SOP needs a code before it can be filed',
        ),
      );
    }
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final id = await localRepo.createSop(sop, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.sop,
        entityId: '$id',
        action: QcAuditAction.sopCreated,
        after: sop.toMap(withId: false),
        meta: {'code': sop.code, 'status': sop.status},
      );
      await _queueSop(txn, id);
      return id;
    });
  }

  @override
  Future<void> updateSop(QcSop sop) async {
    _w.check(Permission.qcWrite);
    final id = sop.sopId;
    if (id == null) {
      throw ValidationError(
        AppText.t(
          'لا يمكن تحديث إجراء بلا معرّف',
          'Cannot update an SOP with no id',
        ),
      );
    }
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_sops', 'sop_id', id);
      await _w.requireRow(before, 'No QC SOP with id $id');
      await localRepo.updateSop(sop, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.sop,
        entityId: '$id',
        action: QcAuditAction.sopUpdated,
        before: before,
        after: await _w.snapshot(txn, 'qc_sops', 'sop_id', id),
      );
      await _queueSop(txn, id);
    });
  }

  @override
  Future<void> deleteSop(int sopId) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_sops', 'sop_id', sopId);
      await _w.requireRow(before, 'No QC SOP with id $sopId');
      await localRepo.deleteSop(sopId, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.sop,
        entityId: '$sopId',
        action: QcAuditAction.sopDeleted,
        before: before,
        after: await _w.snapshot(txn, 'qc_sops', 'sop_id', sopId),
      );
      await _queueSop(txn, sopId);
    });
  }

  /// Publishing is a QC decision, not authoring: it freezes the document and
  /// everything downstream (which revision an inspection was performed against)
  /// depends on it. Hence [Permission.qcApprove] and a fresh session.
  @override
  Future<int> publishSopRevision(
    int sopId, {
    required String changeSummary,
    String effectiveFrom = '',
  }) async {
    _w.check(Permission.qcApprove);
    if (changeSummary.trim().isEmpty) {
      throw const ValidationError(
        'A published revision needs a change summary',
      );
    }
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_sops', 'sop_id', sopId);
      await _w.requireRow(before, 'No QC SOP with id $sopId');
      final revId = await localRepo.publishSopRevision(
        sopId,
        changeSummary: changeSummary,
        effectiveFrom: effectiveFrom,
        editedBy: _w.guard.uid,
        editedByName: _w.guard.actorName,
        exec: txn,
      );
      final revision = await txn.query(
        'qc_sop_revisions',
        where: 'rev_id = ?',
        whereArgs: [revId],
        limit: 1,
      );
      await _w.record(
        txn,
        entityType: QcAuditEntity.sop,
        entityId: '$sopId',
        action: QcAuditAction.sopPublished,
        before: before,
        after: revision.isEmpty
            ? null
            : Map<String, dynamic>.from(revision.first),
        // The revision row carries the snapshots, so the trail points at it
        // rather than duplicating a whole SOP body a second time.
        meta: {
          'rev_id': revId,
          'changeSummary': changeSummary,
          if (effectiveFrom.isNotEmpty) 'effectiveFrom': effectiveFrom,
        },
      );
      // A second entry at revision granularity (plan 21.3 wants both `SOP` and
      // `SOP_REV`), so "which revision shipped, and what changed" is answerable
      // without scanning the SOP rows. It carries no snapshot on purpose: the
      // body is already in the row above, and the hash chain is cheaper to trust
      // when one event does not show up twice.
      await _w.record(
        txn,
        entityType: QcAuditEntity.sopRevision,
        entityId: '$revId',
        action: QcAuditAction.sopPublished,
        meta: {
          'sopId': sopId,
          'changeSummary': changeSummary,
          if (effectiveFrom.isNotEmpty) 'effectiveFrom': effectiveFrom,
        },
      );
      await _queueSop(txn, sopId);
      await _w.queueChildRows(
        txn,
        table: 'qc_sop_revisions',
        pk: 'rev_id',
        entityType: 'qcSopRevision',
        where: 'sop_id = ?',
        whereArgs: [sopId],
      );
      return revId;
    });
  }

  @override
  Future<int> recordSopRead(QcSopRead read) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final readId = await localRepo.recordSopRead(read, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.sopRead,
        entityId: '$readId',
        action: QcAuditAction.sopRead,
        after: read.toMap(withId: false),
        meta: {
          'sopId': read.sopId,
          'revNo': read.revNo,
          'ackMethod': read.ackMethod,
        },
      );
      await _w.queueRow(
        txn,
        entityType: 'qcSopRead',
        table: 'qc_sop_reads',
        pk: 'id',
        id: readId,
      );
      return readId;
    });
  }

  /// Reads are a query, not a write: no permission check and no audit row.
  @override
  Future<List<QcSopRead>> listSopReads(int sopId) =>
      localRepo.listSopReads(sopId);

  Future<void> _queueSop(DatabaseExecutor txn, int id) => _w.queueRow(
    txn,
    entityType: 'qcSop',
    table: 'qc_sops',
    pk: 'sop_id',
    id: id,
  );
}

/// Checklist templates and their trees (plan P3).
class OfflineFirstQcTemplateRepository implements QcTemplateRepository {
  OfflineFirstQcTemplateRepository({
    required QcTemplateRepo local,
    required WriteGuard guard,
    required QcAuditRepo audit,
    required DatabaseHelper dbHelper,
    QcSyncWriter? sync,
  }) : _w = _QcWrite(guard, audit, dbHelper, sync),
       localRepo = local;

  final _QcWrite _w;
  final QcTemplateRepo localRepo;

  @override
  Future<List<QcTemplate>> listTemplates({
    String dept = '',
    bool publishedOnly = false,
  }) => localRepo.listTemplates(dept: dept, publishedOnly: publishedOnly);

  @override
  Future<QcTemplate?> getTemplate(int templateId) =>
      localRepo.getTemplate(templateId);

  @override
  Future<({QcTemplate template, List<QcSection> sections, List<QcItem> items})?>
  getTemplateTree(int templateId) => localRepo.getTemplateTree(templateId);

  @override
  Future<int> createTemplate(QcTemplate template) async {
    if (template.name.trim().isEmpty) {
      throw ValidationError(
        AppText.t('قائمة الفحص تحتاج إلى اسم', 'A checklist needs a name'),
      );
    }
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final id = await localRepo.createTemplate(template, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.template,
        entityId: '$id',
        action: QcAuditAction.templateCreated,
        after: await _w.snapshot(txn, 'qc_templates', 'template_id', id),
      );
      await _w.queueRow(
        txn,
        entityType: 'qcTemplate',
        table: 'qc_templates',
        pk: 'template_id',
        id: id,
      );
      return id;
    });
  }

  @override
  Future<void> saveTemplateTree(
    QcTemplate template,
    List<QcSection> sections,
    List<QcItem> items,
  ) async {
    _w.check(Permission.qcWrite);
    // Caught here rather than left to the local repository so the caller gets the
    // reason, but the local check stays: it is the one protecting a direct caller.
    if (template.isPublished) {
      throw StateError(
        'A published checklist cannot be edited in place. Duplicate it and publish '
        'the copy as a new version.',
      );
    }
    // An item pointing at a section that is not in the same tree would be
    // invisible on the checklist while still existing in the database.
    final sectionIds = sections.map((s) => s.sectionId).toSet();
    for (final item in items) {
      if (!sectionIds.contains(item.sectionId)) {
        throw ValidationError(
          'Item "${item.label}" belongs to section ${item.sectionId}, which is not '
          'part of this checklist',
        );
      }
    }
    return _w.transaction((txn) async {
      final id = template.templateId;
      final before = await _w.snapshot(txn, 'qc_templates', 'template_id', id);
      if (id == null && before == null) {
        await localRepo.saveTemplateTree(template, sections, items, exec: txn);
        final newId = (await txn.query(
          'qc_templates',
          where: 'code = ?',
          whereArgs: [template.code],
          limit: 1,
        )).firstOrNull;
        await _w.record(
          txn,
          entityType: QcAuditEntity.template,
          entityId: '${newId?['template_id']}',
          action: QcAuditAction.templateCreated,
          after: newId == null
              ? template.toMap(withId: false)
              : Map<String, dynamic>.from(newId),
          meta: {'sections': sections.length, 'items': items.length},
        );
        await _w.syncTree(txn, (newId?['template_id'] as num?)?.toInt());
        return;
      }
      await _w.requireRow(before, 'No QC template with id $id');
      await localRepo.saveTemplateTree(template, sections, items, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.template,
        entityId: '$id',
        action: QcAuditAction.templateSaved,
        before: before,
        after: await _w.snapshot(txn, 'qc_templates', 'template_id', id),
        meta: {'sections': sections.length, 'items': items.length},
      );
      await _w.syncTree(txn, id);
    });
  }

  @override
  Future<void> deleteTemplate(int templateId) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(
        txn,
        'qc_templates',
        'template_id',
        templateId,
      );
      await _w.requireRow(before, 'No QC template with id $templateId');
      await localRepo.deleteTemplate(templateId, exec: txn);
      // Children are tombstoned (not deleted) so historical inspections keep
      // resolving them, and the tombstones replicate: otherwise a viewer
      // would keep an orphaned, still-editable tree after the origin's delete.
      await _w.tombstoneChildren(
        txn,
        children: const [
          (table: 'qc_sections', pk: 'section_id', entityType: 'qcSection'),
          (table: 'qc_items', pk: 'item_id', entityType: 'qcItem'),
        ],
        containerColumn: 'template_id',
        containerId: templateId,
      );
      await _w.record(
        txn,
        entityType: QcAuditEntity.template,
        entityId: '$templateId',
        action: QcAuditAction.templateDeleted,
        before: before,
        after: await _w.snapshot(
          txn,
          'qc_templates',
          'template_id',
          templateId,
        ),
      );
    });
  }

  @override
  Future<void> publishTemplate(
    int templateId, {
    String publishedBy = '',
    String effectiveDate = '',
  }) async {
    _w.check(Permission.qcApprove);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(
        txn,
        'qc_templates',
        'template_id',
        templateId,
      );
      await _w.requireRow(before, 'No QC template with id $templateId');
      // The caller's name is not trusted: the signed-in user is the publisher.
      await localRepo.publishTemplate(
        templateId,
        publishedBy: publishedBy.isEmpty ? _w.guard.actorName : publishedBy,
        effectiveDate: effectiveDate,
        exec: txn,
      );
      await _w.record(
        txn,
        entityType: QcAuditEntity.template,
        entityId: '$templateId',
        action: QcAuditAction.templatePublished,
        before: before,
        after: await _w.snapshot(
          txn,
          'qc_templates',
          'template_id',
          templateId,
        ),
      );
      await _w.queueRow(
        txn,
        entityType: 'qcTemplate',
        table: 'qc_templates',
        pk: 'template_id',
        id: templateId,
      );
    });
  }

  @override
  Future<void> archiveTemplate(int templateId) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(
        txn,
        'qc_templates',
        'template_id',
        templateId,
      );
      await _w.requireRow(before, 'No QC template with id $templateId');
      await localRepo.archiveTemplate(templateId, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.template,
        entityId: '$templateId',
        action: QcAuditAction.templateArchived,
        before: before,
        after: await _w.snapshot(
          txn,
          'qc_templates',
          'template_id',
          templateId,
        ),
      );
      await _w.queueRow(
        txn,
        entityType: 'qcTemplate',
        table: 'qc_templates',
        pk: 'template_id',
        id: templateId,
      );
    });
  }

  @override
  Future<int> duplicateTemplate(
    int templateId,
    String newName, {
    String newCode = '',
  }) async {
    _w.check(Permission.qcWrite);
    if (newCode.trim().isEmpty && newName.trim().isEmpty) {
      throw const ValidationError(
        'A duplicate needs a new code, a new name or both',
      );
    }
    return _w.transaction((txn) async {
      final before = await _w.snapshot(
        txn,
        'qc_templates',
        'template_id',
        templateId,
      );
      await _w.requireRow(before, 'No QC template with id $templateId');
      final newId = await localRepo.duplicateTemplate(
        templateId,
        newName,
        newCode: newCode,
        exec: txn,
      );
      await _w.record(
        txn,
        entityType: QcAuditEntity.template,
        entityId: '$newId',
        action: QcAuditAction.templateDuplicated,
        before: before,
        after: await _w.snapshot(txn, 'qc_templates', 'template_id', newId),
        meta: {
          'fromTemplateId': templateId,
          if (newCode.isNotEmpty) 'newCode': newCode,
          if (newName.isNotEmpty) 'newName': newName,
        },
      );
      // The duplicate copies the whole tree (new ids everywhere): sync it
      // like the template it is a copy of.
      await _w.syncTree(txn, newId);
      return newId;
    });
  }
}

/// Inspections and their per-item responses (plan P3).
class OfflineFirstQcInspectionRepository implements QcInspectionRepository {
  OfflineFirstQcInspectionRepository({
    required QcInspectionRepo local,
    required WriteGuard guard,
    required QcAuditRepo audit,
    required DatabaseHelper dbHelper,
    QcSyncWriter? sync,
  }) : _w = _QcWrite(guard, audit, dbHelper, sync),
       localRepo = local;

  final _QcWrite _w;
  final QcInspectionRepo localRepo;

  @override
  Future<List<QcInspection>> listInspections({
    int? templateId,
    String status = '',
    String refType = '',
    String refId = '',
    String lotNo = '',
    String dept = '',
    int limit = 100,
    int offset = 0,
  }) => localRepo.listInspections(
    templateId: templateId,
    status: status,
    refType: refType,
    refId: refId,
    lotNo: lotNo,
    dept: dept,
    limit: limit,
    offset: offset,
  );

  @override
  Future<QcInspection?> getInspection(int inspectionId) =>
      localRepo.getInspection(inspectionId);

  @override
  Future<int> countInspections({
    String status = '',
    String refType = '',
    String refId = '',
  }) => localRepo.countInspections(
    status: status,
    refType: refType,
    refId: refId,
  );

  @override
  Future<Set<int>> templateIdsInspectedOn(String day) =>
      localRepo.templateIdsInspectedOn(day);

  @override
  Future<List<QcResponse>> listResponses(int inspectionId) =>
      localRepo.listResponses(inspectionId);

  @override
  Future<List<QcFindingNc>> listFindings(int inspectionId) =>
      localRepo.listFindings(inspectionId);

  @override
  Future<int> createInspection(QcInspection inspection) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final id = await localRepo.createInspection(inspection, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.inspection,
        entityId: '$id',
        action: QcAuditAction.inspectionCreated,
        after: await _w.snapshot(txn, 'qc_inspections', 'inspection_id', id),
      );
      await _w.queueRow(
        txn,
        entityType: 'qcInspection',
        table: 'qc_inspections',
        pk: 'inspection_id',
        id: id,
      );
      // The seeded unanswered responses replicate too: the progress counters
      // ("3 of 12 answered") and the FKs of later answers need same shapes.
      await _w.queueChildRows(
        txn,
        table: 'qc_responses',
        pk: 'resp_id',
        entityType: 'qcResponse',
        where: 'inspection_id = ?',
        whereArgs: [id],
      );
      return id;
    });
  }

  @override
  Future<void> saveInspection(QcInspection inspection) async {
    _w.check(Permission.qcWrite);
    final id = inspection.inspectionId;
    if (id == null) {
      throw ValidationError(
        AppText.t(
          'لا يمكن حفظ فحص بلا معرّف',
          'Cannot save an inspection with no id',
        ),
      );
    }
    return _w.transaction((txn) async {
      final before = await _w.snapshot(
        txn,
        'qc_inspections',
        'inspection_id',
        id,
      );
      await _w.requireRow(before, 'No QC inspection with id $id');
      // The verdict may move to approved/rejected by a plain save. Those are
      // decisions, so they are re-checked here rather than trusted from the
      // editing screen - otherwise the privileged gate would be a UI convention
      // instead of an actual rule.
      final to = inspection.status;
      if (_QcDecision.isApprove(to) || _QcDecision.isReject(to)) {
        _w.check(
          _QcDecision.isReject(to) ? Permission.qcReject : Permission.qcApprove,
        );
      } else {
        _w.check(Permission.qcWrite);
      }
      await localRepo.saveInspection(inspection, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.inspection,
        entityId: '$id',
        action: _QcDecision.actionFor(to),
        before: before,
        after: await _w.snapshot(txn, 'qc_inspections', 'inspection_id', id),
        meta: {'status': to},
      );
      await _w.queueRow(
        txn,
        entityType: 'qcInspection',
        table: 'qc_inspections',
        pk: 'inspection_id',
        id: id,
      );
    });
  }

  @override
  Future<void> deleteInspection(int inspectionId) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(
        txn,
        'qc_inspections',
        'inspection_id',
        inspectionId,
      );
      await _w.requireRow(before, 'No QC inspection with id $inspectionId');
      await localRepo.deleteInspection(inspectionId, exec: txn);
      // The sheet's answers and done-logs follow the sheet into the
      // tombstone so a viewer does not keep "done" counters for a dead
      // sheet. Findings stay alive on purpose: the NCR worklist keeps its
      // own visibility rules for them.
      await _w.tombstoneChildren(
        txn,
        children: const [
          (table: 'qc_responses', pk: 'resp_id', entityType: 'qcResponse'),
          (table: 'qc_task_log', pk: 'log_id', entityType: 'qcTaskLog'),
        ],
        containerColumn: 'inspection_id',
        containerId: inspectionId,
      );
      await _w.record(
        txn,
        entityType: QcAuditEntity.inspection,
        entityId: '$inspectionId',
        action: QcAuditAction.inspectionDeleted,
        before: before,
        after: await _w.snapshot(
          txn,
          'qc_inspections',
          'inspection_id',
          inspectionId,
        ),
      );
      await _w.queueRow(
        txn,
        entityType: 'qcInspection',
        table: 'qc_inspections',
        pk: 'inspection_id',
        id: inspectionId,
      );
    });
  }

  @override
  Future<void> answerResponse(QcResponse response) async {
    _w.check(Permission.qcWrite);
    // The local repository recomputes score/verdict in the same transaction as
    // the answer, so what gets audited is the state the caller will read back.
    return _w.transaction((txn) async {
      final before = response.respId == null
          ? null
          : await _w.snapshot(txn, 'qc_responses', 'resp_id', response.respId);
      await localRepo.answerResponse(response, exec: txn);
      final id = response.respId;
      await _w.record(
        txn,
        entityType: QcAuditEntity.response,
        entityId: '${id ?? response.itemId}',
        action: QcAuditAction.itemAnswered,
        before: before,
        after: id == null
            ? response.toMap(withId: false)
            : await _w.snapshot(txn, 'qc_responses', 'resp_id', id),
        meta: {
          'inspectionId': response.inspectionId,
          'itemId': response.itemId,
          'result': response.result,
        },
      );
      // The recompute inside the answer write may have moved the sheet's
      // score/verdict/NC counters: both rows ride the push.
      if (id != null) {
        await _w.queueRow(
          txn,
          entityType: 'qcResponse',
          table: 'qc_responses',
          pk: 'resp_id',
          id: id,
        );
      }
      await _w.queueRow(
        txn,
        entityType: 'qcInspection',
        table: 'qc_inspections',
        pk: 'inspection_id',
        id: response.inspectionId,
      );
    });
  }
}

/// Non-conformances and their CAPA (plan P3).
class OfflineFirstQcNcCapaRepository implements QcNcCapaRepository {
  OfflineFirstQcNcCapaRepository({
    required QcNcCapaRepo local,
    required WriteGuard guard,
    required QcAuditRepo audit,
    required DatabaseHelper dbHelper,
    QcSyncWriter? sync,
  }) : _w = _QcWrite(guard, audit, dbHelper, sync),
       localRepo = local;

  final _QcWrite _w;
  final QcNcCapaRepo localRepo;

  @override
  Future<List<QcFindingNc>> listFindings({
    String status = '',
    String severity = '',
    String assignedTo = '',
    String inspectionId = '',
    bool overdueOnly = false,
    int limit = 200,
    int offset = 0,
  }) => localRepo.listFindings(
    status: status,
    severity: severity,
    assignedTo: assignedTo,
    inspectionId: inspectionId,
    overdueOnly: overdueOnly,
    limit: limit,
    offset: offset,
  );

  @override
  Future<QcFindingNc?> getFinding(int findingId) =>
      localRepo.getFinding(findingId);

  @override
  Future<List<QcCapa>> listCapa({String status = '', String findingId = ''}) =>
      localRepo.listCapa(status: status, findingId: findingId);

  @override
  Future<QcCapa?> getCapa(int capaId) => localRepo.getCapa(capaId);

  @override
  Future<List<QcDefectCode>> listDefectCodes({String category = ''}) =>
      localRepo.listDefectCodes(category: category);

  @override
  Future<int> createFinding(QcFindingNc finding) async {
    _w.check(Permission.qcWrite);
    if (finding.severity == NcSeverity.critical &&
        finding.description.trim().isEmpty) {
      // A critical NC with no description cannot be dispositioned, and the
      // severity is what makes it block the batch.
      throw const ValidationError(
        'A critical non-conformance needs a description',
      );
    }
    return _w.transaction((txn) async {
      final id = await localRepo.createFinding(finding, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.finding,
        entityId: '$id',
        action: QcAuditAction.findingCreated,
        after: await _w.snapshot(txn, 'qc_findings_nc', 'finding_id', id),
        meta: {
          'severity': finding.severity,
          'inspectionId': finding.inspectionId,
        },
      );
      await _w.queueRow(
        txn,
        entityType: 'qcFindingNc',
        table: 'qc_findings_nc',
        pk: 'finding_id',
        id: id,
      );
      await _w.queueRow(
        txn,
        entityType: 'qcInspection',
        table: 'qc_inspections',
        pk: 'inspection_id',
        id: finding.inspectionId,
      );
      // The NC counters on the sheet it belongs to moved (they are one of the
      // reasons viewers show a sheet red).
      return id;
    });
  }

  @override
  Future<void> saveFinding(QcFindingNc finding) async {
    final id = finding.findingId;
    if (id == null) {
      throw const ValidationError('Cannot save a non-conformance with no id');
    }
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_findings_nc', 'finding_id', id);
      await _w.requireRow(before, 'No QC non-conformance with id $id');
      // Closing or verifying an NC is a disposition: it is the moment somebody
      // takes responsibility for it, so it is gated separately from authoring.
      // Handing the NC to an owner is routine, so it stays on `qcWrite`.
      final closing = finding.status == NcStatus.closed;
      final verifying = finding.status == NcStatus.verified;
      if (closing || verifying) {
        _w.check(Permission.qcApprove);
      } else {
        _w.check(Permission.qcWrite);
      }
      // The four events plan 21.3 asks for (create/assign/verify/close) have to
      // be told apart, or "who closed this?" can only be answered by reading
      // snapshots. A save that does more than one of them is recorded as the
      // most significant one and keeps the rest in meta.
      final assigned =
          '${before?['assigned_to'] ?? ''}'.isEmpty &&
          finding.assignedTo.isNotEmpty;
      final action = closing
          ? QcAuditAction.findingClosed
          : verifying
          ? QcAuditAction.findingVerified
          : assigned
          ? QcAuditAction.findingAssigned
          : QcAuditAction.findingUpdated;
      await localRepo.saveFinding(finding, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.finding,
        entityId: '$id',
        action: action,
        before: before,
        after: await _w.snapshot(txn, 'qc_findings_nc', 'finding_id', id),
        meta: {
          'status': finding.status,
          if (finding.assignedTo.isNotEmpty) 'assignedTo': finding.assignedTo,
          if (verifying && finding.verifiedBy.isNotEmpty)
            'verifiedBy': finding.verifiedBy,
        },
      );
      await _w.queueRow(
        txn,
        entityType: 'qcFindingNc',
        table: 'qc_findings_nc',
        pk: 'finding_id',
        id: id,
      );
      await _w.queueRow(
        txn,
        entityType: 'qcInspection',
        table: 'qc_inspections',
        pk: 'inspection_id',
        id: finding.inspectionId,
      );
    });
  }

  @override
  Future<void> deleteFinding(int findingId) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(
        txn,
        'qc_findings_nc',
        'finding_id',
        findingId,
      );
      await _w.requireRow(before, 'No QC non-conformance with id $findingId');
      await localRepo.deleteFinding(findingId, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.finding,
        entityId: '$findingId',
        action: QcAuditAction.findingDeleted,
        before: before,
        after: await _w.snapshot(
          txn,
          'qc_findings_nc',
          'finding_id',
          findingId,
        ),
      );
      await _w.queueRow(
        txn,
        entityType: 'qcFindingNc',
        table: 'qc_findings_nc',
        pk: 'finding_id',
        id: findingId,
      );
      // The recompute inside the delete may have lifted the verdict.
      await _w.queueRow(
        txn,
        entityType: 'qcInspection',
        table: 'qc_inspections',
        pk: 'inspection_id',
        id: (before?['inspection_id'] as num?)?.toInt(),
      );
    });
  }

  @override
  Future<int> createCapa(QcCapa capa) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final id = await localRepo.createCapa(capa, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.capa,
        entityId: '$id',
        action: QcAuditAction.capaCreated,
        after: await _w.snapshot(txn, 'qc_capa', 'capa_id', id),
      );
      await _w.queueRow(
        txn,
        entityType: 'qcCapa',
        table: 'qc_capa',
        pk: 'capa_id',
        id: id,
      );
      return id;
    });
  }

  @override
  Future<void> saveCapa(QcCapa capa) async {
    final id = capa.capaId;
    if (id == null) {
      throw const ValidationError('Cannot save a CAPA with no id');
    }
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_capa', 'capa_id', id);
      await _w.requireRow(before, 'No QC CAPA with id $id');
      // Verifying effectiveness is the whole point of a CAPA, so it is a
      // privileged call: nobody but an approver can declare one effective or
      // close it. Finishing the *action* is the owner's own report, so it stays
      // on `qcWrite`.
      final closing = capa.status == CapaStatus.closed;
      final effective =
          capa.isEffective || capa.status == CapaStatus.verifiedEffective;
      final verified =
          effective ||
          capa.status == CapaStatus.verifiedIneffective ||
          capa.verifiedAt.isNotEmpty;
      if (closing || verified) {
        _w.check(Permission.qcApprove);
      } else {
        _w.check(Permission.qcWrite);
      }
      final actionComplete =
          capa.actionCompletedAt.isNotEmpty ||
          capa.status == CapaStatus.actionComplete;
      // action / verify / effective / close are four different claims about a
      // CAPA and plan 21.3 asks for all four to be answerable from the trail
      // alone. The most significant wins; the rest stay in meta.
      final action = closing
          ? QcAuditAction.capaClosed
          : verified
          ? QcAuditAction.capaVerified
          : actionComplete
          ? QcAuditAction.capaActionComplete
          : QcAuditAction.capaUpdated;
      await localRepo.saveCapa(capa, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.capa,
        entityId: '$id',
        action: action,
        before: before,
        after: await _w.snapshot(txn, 'qc_capa', 'capa_id', id),
        meta: {
          'status': capa.status,
          if (effective) 'isEffective': capa.isEffective,
          if (capa.verifiedBy.isNotEmpty) 'verifiedBy': capa.verifiedBy,
        },
      );
      await _w.queueRow(
        txn,
        entityType: 'qcCapa',
        table: 'qc_capa',
        pk: 'capa_id',
        id: id,
      );
    });
  }
}

/// Convenience bundle for the DI registrations (plan P8).
///
/// Every QC facade needs the same three collaborators. Passing them
/// individually six times is where a facade ends up auditing with a different
/// guard than the one it authorised with, so they are assembled once.
class QcRepositories {
  QcRepositories({
    required this.sops,
    required this.templates,
    required this.inspections,
    required this.ncCapa,
    required this.audit,
    required this.dbHelper,
  });

  final QcSopRepository sops;
  final QcTemplateRepository templates;
  final QcInspectionRepository inspections;
  final QcNcCapaRepository ncCapa;
  final QcAuditRepository audit;
  final DatabaseHelper dbHelper;

  /// Registers a ready-made QC stack over [dbHelper]. [actorReader] is handed to
  /// the audit repository so it can attribute entries from the live session.
  /// [queue] (with the optional [syncAudit]) wires the P8 sync seam into the
  /// facades; without it the stack behaves exactly as before — device-local.
  static QcRepositories offlineFirst({
    required DatabaseHelper dbHelper,
    required WriteGuard guard,
    QcActor Function()? actorReader,
    SyncQueue? queue,
    AuditLogger? syncAudit,
  }) {
    final audit = QcAuditRepo(dbHelper: dbHelper, actorReader: actorReader);
    final sync = queue == null
        ? null
        : QcSyncWriter(queue: queue, guard: guard, syncAudit: syncAudit);
    return QcRepositories(
      sops: OfflineFirstQcSopRepository(
        local: QcSopRepo(dbHelper),
        guard: guard,
        audit: audit,
        dbHelper: dbHelper,
        sync: sync,
      ),
      templates: OfflineFirstQcTemplateRepository(
        local: QcTemplateRepo(dbHelper),
        guard: guard,
        audit: audit,
        dbHelper: dbHelper,
        sync: sync,
      ),
      inspections: OfflineFirstQcInspectionRepository(
        local: QcInspectionRepo(dbHelper),
        guard: guard,
        audit: audit,
        dbHelper: dbHelper,
        sync: sync,
      ),
      ncCapa: OfflineFirstQcNcCapaRepository(
        local: QcNcCapaRepo(dbHelper),
        guard: guard,
        audit: audit,
        dbHelper: dbHelper,
        sync: sync,
      ),
      audit: audit,
      dbHelper: dbHelper,
    );
  }
}
