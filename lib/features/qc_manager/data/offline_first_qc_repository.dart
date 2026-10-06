import 'package:sqflite/sqflite.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/qc_audit.dart';
import '../domain/qc_enums.dart';
import '../domain/qc_goal.dart';
import '../domain/qc_inspection.dart';
import '../domain/qc_nc_capa.dart';
import '../domain/qc_repositories.dart';
import '../domain/qc_sop.dart';
import '../domain/qc_template.dart';
import 'qc_audit_repo.dart';
import 'qc_repo.dart';

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
/// ## No `sync_queue` rows yet
/// These facades deliberately do not enqueue. QC has no [SyncEntity] registered
/// in `entity_registry.dart` and no remote collection, so a queued row could
/// only ever settle as `conflict` ("Unknown entity type") and sit in the Sync
/// screen's needs-attention list forever. Registering QC entities and their
/// `firestore.rules` is remote work, owned by plan P8; until that lands,
/// enqueueing would turn a working offline write into a visible failure.
///
/// ## Why not the core `AuditLogger` either
/// The P3 row of the phase table says "WriteGuard/AuditLogger integration", but
/// the module's own audit requirement (§14, line 236) scopes High Audit to
/// `qc_audits` + `qc_sop_audits`, never `audit_logs`. `AuditLogger.log` would
/// additionally push to the shared `organizations/{orgId}/auditLogs` collection,
/// moving QC findings, evidence and inspection responses into a wider surface
/// that P8 has not specified. [QcAuditRepo] is therefore the only audit sink
/// here: one chain, one hasher, one set of immutability triggers.
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
  const _QcWrite(this.guard, this.audit, this.dbHelper);

  final WriteGuard guard;
  final QcAuditRepo audit;
  final DatabaseHelper dbHelper;

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
    final db = await dbHelper.database;
    return db.transaction<T>(body);
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
  /// quietly does nothing looks exactly like a save that worked.
  Future<void> requireRow(Map<String, dynamic>? row, String what) async {
    if (row == null) throw NotFoundError(what);
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

  static const String goalCreated = 'GOAL_CREATED';
  static const String goalSaved = 'GOAL_SAVED';
  static const String goalCompleted = 'GOAL_COMPLETED';
  static const String goalDeleted = 'GOAL_DELETED';
  static const String goalAssigned = 'GOAL_ASSIGNED';
  static const String goalUnassigned = 'GOAL_UNASSIGNED';
  static const String goalActionAdded = 'GOAL_ACTION_ADDED';
  static const String goalActionDone = 'GOAL_ACTION_DONE';
  static const String goalKpiSaved = 'GOAL_KPI_SAVED';
  static const String goalKpiDeleted = 'GOAL_KPI_DELETED';
  static const String goalLinked = 'GOAL_LINKED';
  static const String goalUnlinked = 'GOAL_UNLINKED';
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
class OfflineFirstQcSopRepository implements QcSopRepository {
  OfflineFirstQcSopRepository({
    required QcSopRepo local,
    required WriteGuard guard,
    required QcAuditRepo audit,
    required DatabaseHelper dbHelper,
  }) : _w = _QcWrite(guard, audit, dbHelper),
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
      throw const ValidationError('An SOP needs a code before it can be filed');
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
      return id;
    });
  }

  @override
  Future<void> updateSop(QcSop sop) async {
    _w.check(Permission.qcWrite);
    final id = sop.sopId;
    if (id == null) {
      throw const ValidationError('Cannot update an SOP with no id');
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
        editedByName: _w.guard.email,
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
      return readId;
    });
  }

  /// Reads are a query, not a write: no permission check and no audit row.
  @override
  Future<List<QcSopRead>> listSopReads(int sopId) =>
      localRepo.listSopReads(sopId);
}

/// Checklist templates and their trees (plan P3).
class OfflineFirstQcTemplateRepository implements QcTemplateRepository {
  OfflineFirstQcTemplateRepository({
    required QcTemplateRepo local,
    required WriteGuard guard,
    required QcAuditRepo audit,
    required DatabaseHelper dbHelper,
  }) : _w = _QcWrite(guard, audit, dbHelper),
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
      throw const ValidationError('A checklist needs a name');
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
        publishedBy: publishedBy.isEmpty ? _w.guard.email : publishedBy,
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
    });
  }

  @override
  Future<int> duplicateTemplate(
    int templateId,
    String newCode,
    String newName,
  ) async {
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
  }) : _w = _QcWrite(guard, audit, dbHelper),
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
      return id;
    });
  }

  @override
  Future<void> saveInspection(QcInspection inspection) async {
    _w.check(Permission.qcWrite);
    final id = inspection.inspectionId;
    if (id == null) {
      throw const ValidationError('Cannot save an inspection with no id');
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
  }) : _w = _QcWrite(guard, audit, dbHelper),
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
    });
  }
}

/// Goals, their people, actions, KPIs and links (plan P3).
class OfflineFirstQcGoalRepository implements QcGoalRepository {
  OfflineFirstQcGoalRepository({
    required QcGoalRepo local,
    required WriteGuard guard,
    required QcAuditRepo audit,
    required DatabaseHelper dbHelper,
  }) : _w = _QcWrite(guard, audit, dbHelper),
       localRepo = local;

  final _QcWrite _w;
  final QcGoalRepo localRepo;

  @override
  Future<List<QcGoal>> listGoals({
    String status = '',
    String dept = '',
    String ownerId = '',
    bool overdueOnly = false,
    int limit = 100,
    int offset = 0,
  }) => localRepo.listGoals(
    status: status,
    dept: dept,
    ownerId: ownerId,
    overdueOnly: overdueOnly,
    limit: limit,
    offset: offset,
  );

  @override
  Future<QcGoal?> getGoal(int goalId) => localRepo.getGoal(goalId);

  @override
  Future<QcGoalBundle?> getGoalBundle(int goalId) =>
      localRepo.getGoalBundle(goalId);

  @override
  Future<List<QcGoalAssignment>> listAssignments(int goalId) =>
      localRepo.listAssignments(goalId);

  @override
  Future<List<QcGoalAction>> listActions(int goalId) =>
      localRepo.listActions(goalId);

  @override
  Future<List<QcGoalKpi>> listKpis(int goalId) => localRepo.listKpis(goalId);

  @override
  Future<int> createGoal(QcGoal goal) async {
    _w.check(Permission.qcWrite);
    if (goal.title.trim().isEmpty) {
      throw const ValidationError('A goal needs a title');
    }
    return _w.transaction((txn) async {
      final id = await localRepo.createGoal(goal, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goal,
        entityId: '$id',
        action: QcAuditAction.goalCreated,
        after: await _w.snapshot(txn, 'qc_goals', 'goal_id', id),
      );
      return id;
    });
  }

  @override
  Future<void> saveGoal(QcGoal goal) async {
    final id = goal.goalId;
    if (id == null) {
      throw const ValidationError('Cannot save a goal with no id');
    }
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_goals', 'goal_id', id);
      await _w.requireRow(before, 'No QC goal with id $id');
      // Completing a goal is the accountability statement the plan asks for
      // ("who/when"), so it is a decision rather than an edit.
      final completing = goal.status == QcGoalStatus.completed;
      _w.check(completing ? Permission.qcApprove : Permission.qcWrite);
      if (completing) {
        final blocker = goal.completionBlocker;
        if (blocker.isNotEmpty) throw ValidationError(blocker);

        final currentBundle = await localRepo.getGoalBundle(id, exec: txn);
        if (currentBundle == null) {
          throw NotFoundError('No QC goal with id $id');
        }
        final completionBundle = QcGoalBundle(
          goal: goal,
          assignments: currentBundle.assignments,
          actions: currentBundle.actions,
          kpis: currentBundle.kpis,
          links: currentBundle.links,
        );
        final childBlocker = completionBundle.completionBlocker;
        if (childBlocker.isNotEmpty) throw ValidationError(childBlocker);
      }
      await localRepo.saveGoal(goal, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goal,
        entityId: '$id',
        action: completing
            ? QcAuditAction.goalCompleted
            : QcAuditAction.goalSaved,
        before: before,
        after: await _w.snapshot(txn, 'qc_goals', 'goal_id', id),
        meta: {
          'status': goal.status,
          if (completing) 'completedBy': goal.completedBy,
        },
      );
    });
  }

  @override
  Future<void> deleteGoal(int goalId) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_goals', 'goal_id', goalId);
      await _w.requireRow(before, 'No QC goal with id $goalId');
      await localRepo.deleteGoal(goalId, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goal,
        entityId: '$goalId',
        action: QcAuditAction.goalDeleted,
        before: before,
        after: await _w.snapshot(txn, 'qc_goals', 'goal_id', goalId),
      );
    });
  }

  @override
  Future<void> assignGoal(QcGoalAssignment assignment) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      await localRepo.assignGoal(assignment, exec: txn);
      final row = await txn.query(
        'qc_goal_assignments',
        where: 'goal_id = ? AND assignee_id = ?',
        whereArgs: [assignment.goalId, assignment.assigneeId],
        limit: 1,
      );
      await _w.record(
        txn,
        entityType: QcAuditEntity.goalAssignment,
        entityId: '${row.isEmpty ? '' : row.first['assign_id']}',
        action: QcAuditAction.goalAssigned,
        after: row.isEmpty
            ? assignment.toMap(withId: false)
            : Map<String, dynamic>.from(row.first),
        meta: {'goalId': assignment.goalId, 'role': assignment.role},
      );
    });
  }

  @override
  Future<void> updateAssignment(QcGoalAssignment assignment) async {
    _w.check(Permission.qcWrite);
    final id = assignment.assignId;
    if (id == null) {
      throw const ValidationError('Cannot update an assignment with no id');
    }
    return _w.transaction((txn) async {
      final before = await _w.snapshot(
        txn,
        'qc_goal_assignments',
        'assign_id',
        id,
      );
      await _w.requireRow(before, 'No QC goal assignment with id $id');
      await localRepo.updateAssignment(assignment, exec: txn);
      final after = await _w.snapshot(
        txn,
        'qc_goal_assignments',
        'assign_id',
        id,
      );
      // "This action item is done" is the single most asked-for fact in goal
      // tracking, so it gets a named action instead of hiding in a status diff.
      final wasDone =
          '${before?['status']}' == QcGoalAssignmentStatus.completed;
      final isDone = '${after?['status']}' == QcGoalAssignmentStatus.completed;
      await _w.record(
        txn,
        entityType: QcAuditEntity.goalAssignment,
        entityId: '$id',
        action: !wasDone && isDone
            ? QcAuditAction.goalActionDone
            : QcAuditAction.goalAssigned,
        before: before,
        after: after,
        meta: {'goalId': assignment.goalId, 'status': after?['status']},
      );
    });
  }

  @override
  Future<void> removeAssignment(int assignId) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(
        txn,
        'qc_goal_assignments',
        'assign_id',
        assignId,
      );
      await _w.requireRow(before, 'No QC goal assignment with id $assignId');
      await localRepo.removeAssignment(assignId, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goalAssignment,
        entityId: '$assignId',
        action: QcAuditAction.goalUnassigned,
        before: before,
        after: await _w.snapshot(
          txn,
          'qc_goal_assignments',
          'assign_id',
          assignId,
        ),
        meta: {'goalId': before?['goal_id']},
      );
    });
  }

  @override
  Future<int> addAction(QcGoalAction action) async {
    _w.check(Permission.qcWrite);
    if (action.actionText.trim().isEmpty) {
      throw const ValidationError('A goal action needs a title');
    }
    return _w.transaction((txn) async {
      final id = await localRepo.addAction(action, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goalAction,
        entityId: '$id',
        action: QcAuditAction.goalActionAdded,
        after: await _w.snapshot(txn, 'qc_goal_actions', 'action_id', id),
        meta: {'goalId': action.goalId},
      );
      return id;
    });
  }

  @override
  Future<void> saveAction(QcGoalAction action) async {
    _w.check(Permission.qcWrite);
    final id = action.actionId;
    if (id == null) {
      throw const ValidationError('Cannot save an action with no id');
    }
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_goal_actions', 'action_id', id);
      await _w.requireRow(before, 'No QC goal action with id $id');
      await localRepo.saveAction(action, exec: txn);
      final after = await _w.snapshot(txn, 'qc_goal_actions', 'action_id', id);
      final wasDone = '${before?['status']}' == QcGoalActionStatus.done;
      final isDone = '${after?['status']}' == QcGoalActionStatus.done;
      await _w.record(
        txn,
        entityType: QcAuditEntity.goalAction,
        entityId: '$id',
        action: !wasDone && isDone
            ? QcAuditAction.goalActionDone
            : QcAuditAction.goalActionAdded,
        before: before,
        after: after,
        meta: {'goalId': action.goalId, 'status': action.status},
      );
    });
  }

  @override
  Future<int> addKpi(QcGoalKpi kpi) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final id = await localRepo.addKpi(kpi, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goal,
        entityId: '${kpi.goalId}',
        action: QcAuditAction.goalKpiSaved,
        after: await _w.snapshot(txn, 'qc_goal_kpis', 'kpi_id', id),
        meta: {'kpiId': id, 'goalId': kpi.goalId},
      );
      return id;
    });
  }

  @override
  Future<void> saveKpi(QcGoalKpi kpi) async {
    _w.check(Permission.qcWrite);
    final id = kpi.kpiId;
    if (id == null) throw const ValidationError('Cannot save a KPI with no id');
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_goal_kpis', 'kpi_id', id);
      await _w.requireRow(before, 'No QC goal KPI with id $id');
      await localRepo.saveKpi(kpi, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goal,
        entityId: '${kpi.goalId}',
        action: QcAuditAction.goalKpiSaved,
        before: before,
        after: await _w.snapshot(txn, 'qc_goal_kpis', 'kpi_id', id),
        meta: {'kpiId': id, 'goalId': kpi.goalId},
      );
    });
  }

  @override
  Future<void> deleteKpi(int kpiId) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_goal_kpis', 'kpi_id', kpiId);
      await _w.requireRow(before, 'No QC goal KPI with id $kpiId');
      await localRepo.deleteKpi(kpiId, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goal,
        entityId: '${before?['goal_id']}',
        action: QcAuditAction.goalKpiDeleted,
        before: before,
        after: await _w.snapshot(txn, 'qc_goal_kpis', 'kpi_id', kpiId),
      );
    });
  }

  @override
  Future<int> addLink(QcGoalLink link) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final id = await localRepo.addLink(link, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goal,
        entityId: '${link.goalId}',
        action: QcAuditAction.goalLinked,
        after: link.toMap(withId: false),
        meta: {
          'linkId': id,
          'goalId': link.goalId,
          'entityType': link.linkType,
          'entityId': link.refId,
        },
      );
      return id;
    });
  }

  @override
  Future<void> deleteLink(int linkId) async {
    _w.check(Permission.qcWrite);
    return _w.transaction((txn) async {
      final before = await _w.snapshot(txn, 'qc_goal_links', 'link_id', linkId);
      await _w.requireRow(before, 'No QC goal link with id $linkId');
      await localRepo.deleteLink(linkId, exec: txn);
      await _w.record(
        txn,
        entityType: QcAuditEntity.goal,
        entityId: '${before?['goal_id']}',
        action: QcAuditAction.goalUnlinked,
        before: before,
        meta: {'linkId': linkId, 'goalId': before?['goal_id']},
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
    required this.goals,
    required this.audit,
  });

  final QcSopRepository sops;
  final QcTemplateRepository templates;
  final QcInspectionRepository inspections;
  final QcNcCapaRepository ncCapa;
  final QcGoalRepository goals;
  final QcAuditRepository audit;

  /// Registers a ready-made QC stack over [dbHelper]. [actorReader] is handed to
  /// the audit repository so it can attribute entries from the live session.
  static QcRepositories offlineFirst({
    required DatabaseHelper dbHelper,
    required WriteGuard guard,
    QcActor Function()? actorReader,
  }) {
    final audit = QcAuditRepo(dbHelper: dbHelper, actorReader: actorReader);
    return QcRepositories(
      sops: OfflineFirstQcSopRepository(
        local: QcSopRepo(dbHelper),
        guard: guard,
        audit: audit,
        dbHelper: dbHelper,
      ),
      templates: OfflineFirstQcTemplateRepository(
        local: QcTemplateRepo(dbHelper),
        guard: guard,
        audit: audit,
        dbHelper: dbHelper,
      ),
      inspections: OfflineFirstQcInspectionRepository(
        local: QcInspectionRepo(dbHelper),
        guard: guard,
        audit: audit,
        dbHelper: dbHelper,
      ),
      ncCapa: OfflineFirstQcNcCapaRepository(
        local: QcNcCapaRepo(dbHelper),
        guard: guard,
        audit: audit,
        dbHelper: dbHelper,
      ),
      goals: OfflineFirstQcGoalRepository(
        local: QcGoalRepo(dbHelper),
        guard: guard,
        audit: audit,
        dbHelper: dbHelper,
      ),
      audit: audit,
    );
  }
}
