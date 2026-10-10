import 'qc_audit.dart';
import 'qc_goal.dart';
import 'qc_inspection.dart';
import 'qc_nc_capa.dart';
import 'qc_sop.dart';
import 'qc_template.dart';

/// Domain contracts for the QC Manager (plan V6_ENHANCED §24 P3).
///
/// The presentation layer talks to these and never to a `data/` implementation
/// (`test/architecture/repository_boundary_test.dart` enforces that), which is
/// why they are declared against the P2 models rather than against
/// `Map<String, dynamic>` the way the older `InspectionRepository` is.
///
/// ## Transactions are the facade's business
/// No method here takes a `DatabaseExecutor`. A caller that needs the local
/// write and its `qc_audits` row to commit together gets that from the
/// `OfflineFirst*` facades, which own the transaction and thread their executor
/// down into the local repository. Exposing `exec` on the contract would invite a
/// cubit to open a transaction it cannot also audit inside.
///
/// ## Soft deletes
/// Every read here is an *alive* read: rows carrying a `deleted_at` are treated
/// as gone. Deletes are tombstones, never `DELETE`, because a QC record that
/// once justified a release has to stay readable years later.
abstract interface class QcSopRepository {
  /// Published and draft SOPs, newest first. Archived SOPs are hidden unless
  /// [includeArchived].
  Future<List<QcSop>> listSops({
    String dept = '',
    String status = '',
    bool includeArchived = false,
  });

  Future<QcSop?> getSop(int sopId);

  Future<QcSop?> getSopByCode(String code);

  /// Creates a draft. [sop.sopId] is ignored; the returned id is local.
  Future<int> createSop(QcSop sop);

  /// Saves an editable field change. Refuses once the SOP is published - a
  /// published SOP is immutable and a change means a new revision.
  Future<void> updateSop(QcSop sop);

  /// Soft delete (`deleted_at`).
  Future<void> deleteSop(int sopId);

  /// Publishes a new revision from the SOP's current body, superseding the
  /// previous one. Returns the new `rev_id`.
  Future<int> publishSopRevision(
    int sopId, {
    required String changeSummary,
    String effectiveFrom = '',
  });

  Future<List<QcSopRevision>> listSopRevisions(int sopId);

  /// Records that a user read/acknowledged a specific revision, and returns the
  /// stored `read_id`.
  Future<int> recordSopRead(QcSopRead read);

  /// Every acknowledgement recorded against this SOP, newest first.
  ///
  /// Recording without ever reading back is how a compliance question ("who has
  /// signed off revision 4?") becomes unanswerable, so the read side is part
  /// of the contract rather than a query bolted onto the screen.
  Future<List<QcSopRead>> listSopReads(int sopId);
}

/// Checklist templates and their ordered sections/items.
abstract interface class QcTemplateRepository {
  Future<List<QcTemplate>> listTemplates({
    String dept = '',
    bool publishedOnly = false,
  });

  Future<QcTemplate?> getTemplate(int templateId);

  /// A template with its sections and items, in display order.
  Future<({QcTemplate template, List<QcSection> sections, List<QcItem> items})?>
  getTemplateTree(int templateId);

  Future<int> createTemplate(QcTemplate template);

  /// Replaces the whole tree in one transaction: the template, its sections and
  /// its items. Partial edits are not representable, because a checklist with
  /// half its items replaced is not a checklist anyone can sign.
  Future<void> saveTemplateTree(
    QcTemplate template,
    List<QcSection> sections,
    List<QcItem> items,
  );

  Future<void> deleteTemplate(int templateId);

  /// Issues a template and freezes it from in-place edits. A checklist with no
  /// sections or no items cannot be published.
  Future<void> publishTemplate(
    int templateId, {
    String publishedBy = '',
    String effectiveDate = '',
  });

  /// Retires a template without deleting it, so historical inspections keep
  /// resolving the checklist they were performed against.
  Future<void> archiveTemplate(int templateId);

  /// Copies a template and its tree under a new code, so a published checklist
  /// can be revised without touching the issued one.
  Future<int> duplicateTemplate(int templateId, String newCode, String newName);
}

/// QC inspections against a template, plus the per-item responses.
abstract interface class QcInspectionRepository {
  Future<List<QcInspection>> listInspections({
    int? templateId,
    String status = '',
    String refType = '',
    String refId = '',
    String lotNo = '',
    String dept = '',
    int limit = 100,
    int offset = 0,
  });

  Future<QcInspection?> getInspection(int inspectionId);

  Future<int> countInspections({
    String status = '',
    String refType = '',
    String refId = '',
  });

  /// Distinct template ids with a live inspection on [day] (`yyyy-MM-dd`,
  /// matched against the date part of the inspection date). Backs the
  /// dashboard's daily-tasks card through the contract, so presentation
  /// never needs raw SQL for it.
  Future<Set<int>> templateIdsInspectedOn(String day);

  /// Creates an inspection and stamps every item of [templateId] into
  /// `qc_responses` as unanswered, so scoring and progress never have to special
  /// case "no row yet".
  Future<int> createInspection(QcInspection inspection);

  Future<void> saveInspection(QcInspection inspection);

  Future<void> deleteInspection(int inspectionId);

  Future<List<QcResponse>> listResponses(int inspectionId);

  /// Answers one item and recomputes the inspection's counts, score and overall
  /// result in the same transaction.
  Future<void> answerResponse(QcResponse response);

  Future<List<QcFindingNc>> listFindings(int inspectionId);
}

/// Non-conformances and their CAPA.
abstract interface class QcNcCapaRepository {
  Future<List<QcFindingNc>> listFindings({
    String status = '',
    String severity = '',
    String assignedTo = '',
    String inspectionId = '',
    bool overdueOnly = false,
    int limit = 200,
    int offset = 0,
  });

  Future<QcFindingNc?> getFinding(int findingId);

  Future<int> createFinding(QcFindingNc finding);

  Future<void> saveFinding(QcFindingNc finding);

  Future<void> deleteFinding(int findingId);

  Future<List<QcCapa>> listCapa({String status = '', String findingId = ''});

  Future<QcCapa?> getCapa(int capaId);

  Future<int> createCapa(QcCapa capa);

  Future<void> saveCapa(QcCapa capa);

  Future<List<QcDefectCode>> listDefectCodes({String category = ''});
}

/// Goals, with the people assigned to them and the actions they owe.
abstract interface class QcGoalRepository {
  Future<List<QcGoal>> listGoals({
    String status = '',
    String dept = '',
    String ownerId = '',
    bool overdueOnly = false,
    int limit = 100,
    int offset = 0,
  });

  Future<QcGoal?> getGoal(int goalId);

  Future<int> createGoal(QcGoal goal);

  Future<void> saveGoal(QcGoal goal);

  Future<void> deleteGoal(int goalId);

  Future<List<QcGoalAssignment>> listAssignments(int goalId);

  Future<void> assignGoal(QcGoalAssignment assignment);

  Future<void> updateAssignment(QcGoalAssignment assignment);

  Future<void> removeAssignment(int assignId);

  Future<List<QcGoalAction>> listActions(int goalId);

  Future<int> addAction(QcGoalAction action);

  Future<void> saveAction(QcGoalAction action);

  Future<int> addKpi(QcGoalKpi kpi);

  Future<void> saveKpi(QcGoalKpi kpi);

  Future<void> deleteKpi(int kpiId);

  Future<List<QcGoalKpi>> listKpis(int goalId);

  /// Ties a goal to the SOP, NC, inspection or template it exists to serve.
  Future<int> addLink(QcGoalLink link);

  Future<void> deleteLink(int linkId);

  /// A goal plus everything hanging off it, for the goal detail screen.
  Future<QcGoalBundle?> getGoalBundle(int goalId);
}

/// Read-only access to the tamper-evident trail (plan V6_ENHANCED §21, P4).
///
/// There is deliberately no `update`, no `delete` and no `save`. The chain is
/// only meaningful if rows cannot be rewritten after the fact, so the trail is
/// append-only at three independent layers: this interface has no mutator, the
/// repository refuses them, and SQLite triggers reject the statement outright.
abstract interface class QcAuditRepository {
  /// Appends one entry, hashing it onto the end of the chain.
  ///
  /// The actor is read from the live session, never from a caller-supplied
  /// name, so a signed-out user cannot be recorded as the author of an edit.
  Future<int> append({
    required String entityType,
    required String entityId,
    required String action,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    Map<String, dynamic>? meta,
  });

  Future<QcAudit?> get(int id);

  Future<List<QcAudit>> list({
    String entityType = '',
    String entityId = '',
    String action = '',
    int limit = 200,
    int offset = 0,
  });

  Future<int> count({String entityType = '', String entityId = ''});

  /// Re-derives every hash in `qc_audits` and reports where the chain first
  /// breaks. See `AuditHasher.verifyChain`.
  Future<QcChainVerification> verifyChain({int? limit});
}
