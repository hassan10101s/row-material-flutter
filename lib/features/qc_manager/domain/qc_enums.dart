/// Status/type vocabularies for the QC Manager (plan V6 §6).
///
/// These are `String` constants rather than Dart `enum`s for two reasons, both
/// of them already settled elsewhere in this codebase:
///
/// * the values are persisted verbatim in `qc_*` columns that carry `CHECK`
///   constraints, so the storage form and the Dart form must not drift; and
/// * `AppRoles` / `MemberStatus` (core/auth/permissions.dart) set the precedent.
///
/// Each group follows the same shape: one constant per value, an `all` list for
/// populating filter dropdowns, an `isValid` guard for the form layer, and
/// `normalize*` which degrades an unknown value to a safe default rather than
/// throwing - a corrupt row must never unlock a write path.
library;

/// Today as `yyyy-MM-dd`, matching the `nowIso()` column format.
///
/// Every `isExpired`/`isOverdue` check compares this against a stored date's
/// first 10 characters, which is a chronological compare because both sides are
/// zero-padded ISO local dates. Resolved through a single cached function so the
/// models do not each carry their own copy of the padding logic.
String qcToday() => _today ??= _computeToday();

String? _today;

String _computeToday() {
  final n = DateTime.now();
  String p(int v) => v.toString().padLeft(2, '0');
  return '${n.year}-${p(n.month)}-${p(n.day)}';
}

/// Whole-day difference between two `yyyy-MM-dd...` local timestamps, rounded
/// towards zero. Returns 0 when either side is unparseable, so a blank
/// timestamp can never inflate an aging bucket.
int qcDaysBetween(String from, String to) {
  final a = DateTime.tryParse(from.replaceFirst(' ', 'T'));
  final b = DateTime.tryParse(to.replaceFirst(' ', 'T'));
  if (a == null || b == null) return 0;
  return b.difference(a).inHours ~/ 24;
}

/// True when [due] (a `yyyy-MM-dd...` column) is before today. A blank date is
/// never overdue - an NC with no due date is not late, it is unplanned.
///
/// Dart has no `<` on [String], so the chronological test is `compareTo`. That
/// is only valid because both sides are zero-padded ISO local dates, which sort
/// lexicographically in date order.
bool qcIsPastDue(String due) =>
    due.length >= 10 && due.substring(0, 10).compareTo(qcToday()) < 0;

/// True when [from] (a `yyyy-MM-dd...` column) is today or later. An empty date
/// means "no constraint", so it counts as effective.
bool qcIsEffectiveFrom(String from) =>
    from.isEmpty || from.substring(0, 10).compareTo(qcToday()) <= 0;

// ── SOP ───────────────────────────────────────────────────────────────────

/// Lifecycle of a SOP. A SOP moves Draft → Pending → Approved → Published, and
/// from Published either forward to Obsolete (superseded by a new revision) or
/// sideways to Archived.
abstract final class SopStatus {
  static const String draft = 'Draft';
  static const String pending = 'Pending';
  static const String approved = 'Approved';
  static const String published = 'Published';
  static const String obsolete = 'Obsolete';
  static const String archived = 'Archived';

  static const List<String> all = [
    draft,
    pending,
    approved,
    published,
    obsolete,
    archived,
  ];

  static bool isValid(String? v) => v != null && all.contains(v);

  /// Unknown or blank becomes [draft] - the only state that cannot grant
  /// anyone read access to a published procedure.
  static String normalize(String? v) => isValid(v) ? v as String : draft;

  /// Legal forward transitions. A published SOP is never edited in place; it
  /// gains a revision, so `published` only leads to `obsolete`/`archived`.
  static const Map<String, List<String>> transitions = {
    draft: [pending, archived],
    pending: [approved, draft, archived],
    approved: [published, draft, archived],
    published: [obsolete, archived],
    obsolete: [archived],
    archived: [],
  };

  static bool canTransition(String from, String to) =>
      (transitions[normalize(from)] ?? const []).contains(normalize(to));
}

/// SOP body is either inline rich text or an attached file (PDF/Word).
abstract final class SopContentType {
  static const String text = 'text';
  static const String file = 'file';

  static const List<String> all = [text, file];

  static String normalize(String? v) => v == file ? file : text;
}

/// How a reader acknowledged a SOP revision.
abstract final class SopAckMethod {
  static const String manual = 'manual';
  static const String signature = 'signature';
  static const String biometric = 'biometric';

  static const List<String> all = [manual, signature, biometric];

  static String normalize(String? v) => all.contains(v) ? v as String : manual;
}

/// Entity kinds recorded in `qc_sop_audits.entity`.
abstract final class SopAuditEntity {
  static const String sop = 'SOP';
  static const String revision = 'SOP_REV';
  static const String read = 'SOP_READ';
  static const String approval = 'APPROVAL';

  static const List<String> all = [sop, revision, read, approval];
}

// ── Checklist templates ───────────────────────────────────────────────────

/// What stage of the material flow a template inspects.
abstract final class QcTemplateType {
  static const String incoming = 'Incoming';
  static const String inProcess = 'InProcess';
  static const String finalCheck = 'Final';
  static const String packing = 'Packing';
  static const String process = 'Process';
  static const String rawMaterial = 'RawMaterial';
  static const String finishedGoods = 'FinishedGoods';
  static const String calibration = 'Calibration';
  static const String other = 'Other';

  static const List<String> all = [
    incoming,
    inProcess,
    finalCheck,
    packing,
    process,
    rawMaterial,
    finishedGoods,
    calibration,
    other,
  ];

  static String normalize(String? v) => all.contains(v) ? v as String : other;
}

/// The input control a checklist item renders, which in turn decides how a
/// response is validated and scored.
///
/// The member is `boolean`, not `bool`: a `bool` constant inside this class
/// would shadow the `bool` type for every signature declared in the class body.
abstract final class QcItemType {
  static const String boolean = 'bool';
  static const String passFail = 'passfail';
  static const String na = 'na';
  static const String text = 'text';
  static const String number = 'number';
  static const String date = 'date';
  static const String dropdown = 'dropdown';
  static const String multiSelect = 'multiselect';
  static const String photo = 'photo';
  static const String signature = 'signature';

  static const List<String> all = [
    boolean,
    passFail,
    na,
    text,
    number,
    date,
    dropdown,
    multiSelect,
    photo,
    signature,
  ];

  static String normalize(String? v) =>
      all.contains(v) ? v as String : passFail;

  /// Item types whose response is a measured number and therefore subject to
  /// `min_value`/`max_value`/`tolerance` evaluation.
  static bool isNumeric(String? v) => normalize(v) == number;

  /// Item types that carry their own evidence and so satisfy an
  /// `require_evidence_if_fail` obligation on their own.
  static bool isEvidence(String? v) {
    final t = normalize(v);
    return t == photo || t == signature;
  }
}

// ── Inspection execution ──────────────────────────────────────────────────

/// What a QC inspection is being raised against.
abstract final class QcRefType {
  static const String job = 'Job';
  static const String batch = 'Batch';
  static const String lot = 'Lot';
  static const String po = 'PO';
  static const String grn = 'GRN';
  static const String material = 'Material';
  static const String wip = 'WIP';
  static const String finishedGoods = 'FG';
  static const String order = 'Order';
  static const String other = 'Other';

  static const List<String> all = [
    job,
    batch,
    lot,
    po,
    grn,
    material,
    wip,
    finishedGoods,
    order,
    other,
  ];

  static String normalize(String? v) => all.contains(v) ? v as String : other;
}

/// Inspection workflow state. `Closed` is terminal and only reachable through
/// a reviewed/approved inspection with every CAPA verified effective.
abstract final class QcInspectionStatus {
  static const String inProgress = 'InProgress';
  static const String submitted = 'Submitted';
  static const String reviewed = 'Reviewed';
  static const String approved = 'Approved';
  static const String rejected = 'Rejected';
  static const String closed = 'Closed';

  static const List<String> all = [
    inProgress,
    submitted,
    reviewed,
    approved,
    rejected,
    closed,
  ];

  static String normalize(String? v) =>
      all.contains(v) ? v as String : inProgress;

  /// States a reviewer may still move the inspection *out of*. A rejected or
  /// closed inspection is final.
  static bool isOpen(String? v) {
    final s = normalize(v);
    return s == inProgress || s == submitted || s == reviewed || s == approved;
  }

  /// True once the inspector has committed the sheet and reviewers own it.
  static bool isFinal(String? v) {
    final s = normalize(v);
    return s == rejected || s == closed;
  }
}

/// Rolled-up verdict for the whole sheet.
abstract final class QcOverallResult {
  static const String pass = 'Pass';
  static const String conditional = 'Conditional';
  static const String fail = 'Fail';
  static const String pending = 'Pending';

  static const List<String> all = [pass, conditional, fail, pending];

  static String normalize(String? v) => all.contains(v) ? v as String : pending;

  /// Only a critical failure fails the sheet outright; a major failure makes it
  /// conditional. `has_nc` alone must not decide this.
  static String fromCounts({
    required bool hasCriticalFailure,
    required int criticalCount,
    required int majorCount,
  }) {
    if (hasCriticalFailure || criticalCount > 0) return fail;
    if (majorCount > 0) return conditional;
    return pass;
  }
}

/// Per-item verdict. `NA` is only ever stored when the template's `allow_na`
/// (and the item's own `allow_na`) permit it.
abstract final class QcResponseResult {
  static const String pass = 'Pass';
  static const String fail = 'Fail';
  static const String na = 'NA';

  static const List<String> all = [pass, fail, na];

  static String normalize(String? v) =>
      v == fail ? fail : (v == na ? na : pass);

  static bool isPass(String? v) => normalize(v) == pass;
  static bool isFail(String? v) => normalize(v) == fail;
  static bool isNa(String? v) => normalize(v) == na;
}

// ── Non-conformance ───────────────────────────────────────────────────────

/// NC severity. Drives both the CAPA requirement and the review matrix: a
/// Critical NC cannot be closed without a second pair of eyes.
abstract final class NcSeverity {
  static const String minor = 'Minor';
  static const String major = 'Major';
  static const String critical = 'Critical';

  static const List<String> all = [minor, major, critical];

  static String normalize(String? v) => all.contains(v) ? v as String : minor;

  /// Sort weight for "worst first" listings.
  static int weight(String? v) => switch (normalize(v)) {
    critical => 3,
    major => 2,
    _ => 1,
  };
}

/// NC workflow state.
abstract final class NcStatus {
  static const String open = 'Open';
  static const String assigned = 'Assigned';
  static const String inProgress = 'InProgress';
  static const String verified = 'Verified';
  static const String closed = 'Closed';
  static const String rejected = 'Rejected';

  static const List<String> all = [
    open,
    assigned,
    inProgress,
    verified,
    closed,
    rejected,
  ];

  static String normalize(String? v) => all.contains(v) ? v as String : open;

  /// Closed and rejected are the two states the NCR report excludes from its
  /// open/overdue counts.
  static bool isOpenState(String? v) {
    final s = normalize(v);
    return s != closed && s != rejected;
  }

  static bool isOverdue(Map<String, dynamic> row) {
    if (!isOpenState('${row['status']}')) return false;
    return qcIsPastDue('${row['due_date'] ?? ''}');
  }
}

/// Whether a finding blocks the material, is informational, or records a
/// sanctioned departure from procedure.
abstract final class NcType {
  static const String nonConformance = 'NonConformance';
  static const String observation = 'Observation';
  static const String deviation = 'Deviation';

  static const List<String> all = [nonConformance, observation, deviation];

  static String normalize(String? v) =>
      all.contains(v) ? v as String : nonConformance;
}

/// Material disposition decided during NC review.
abstract final class NcDisposition {
  static const String rework = 'Rework';
  static const String scrap = 'Scrap';
  static const String useAsIs = 'UseAsIs';
  static const String returnToSupplier = 'Return';
  static const String concession = 'Concession';
  static const String pending = 'Pending';

  static const List<String> all = [
    rework,
    scrap,
    useAsIs,
    returnToSupplier,
    concession,
    pending,
  ];

  static String normalize(String? v) => all.contains(v) ? v as String : pending;
}

// ── CAPA ──────────────────────────────────────────────────────────────────

abstract final class CapaType {
  static const String corrective = 'Corrective';
  static const String preventive = 'Preventive';
  static const String correctivePreventive = 'CorrectivePreventive';

  static const List<String> all = [
    corrective,
    preventive,
    correctivePreventive,
  ];

  static String normalize(String? v) =>
      all.contains(v) ? v as String : corrective;
}

/// CAPA closure is deliberately two-step: `actionComplete` is a claim by the
/// assignee, `verifiedEffective` is a finding by an independent verifier, and
/// only `closed` ends the loop. A CAPA cannot jump from `open` to `closed`.
abstract final class CapaStatus {
  static const String open = 'Open';
  static const String inProgress = 'InProgress';
  static const String actionComplete = 'ActionComplete';
  static const String verificationPending = 'VerificationPending';
  static const String verifiedEffective = 'VerifiedEffective';
  static const String verifiedIneffective = 'VerifiedIneffective';
  static const String closed = 'Closed';
  static const String rejected = 'Rejected';

  static const List<String> all = [
    open,
    inProgress,
    actionComplete,
    verificationPending,
    verifiedEffective,
    verifiedIneffective,
    closed,
    rejected,
  ];

  static String normalize(String? v) => all.contains(v) ? v as String : open;

  /// Legal forward transitions, encoding the two-step rule above.
  static const Map<String, List<String>> transitions = {
    open: [inProgress, rejected],
    inProgress: [actionComplete, rejected],
    actionComplete: [verificationPending, rejected],
    verificationPending: [verifiedEffective, verifiedIneffective],
    verifiedIneffective: [actionComplete, rejected],
    verifiedEffective: [closed, inProgress],
    closed: [],
    rejected: [],
  };

  static bool canTransition(String from, String to) =>
      (transitions[normalize(from)] ?? const []).contains(normalize(to));

  /// Action done, effectiveness not yet judged.
  static bool awaitsVerification(String? v) {
    final s = normalize(v);
    return s == actionComplete || s == verificationPending;
  }

  static bool isOverdue(Map<String, dynamic> row) {
    final s = normalize('${row['status']}');
    if (s == closed || s == rejected || s == verifiedEffective) return false;
    return qcIsPastDue('${row['due_at'] ?? ''}');
  }
}

/// Root-cause analysis method recorded against a CAPA.
abstract final class RootCauseMethod {
  static const String fiveWhy = '5Why';
  static const String fishbone = 'Fishbone';
  static const String ishikawa = 'Ishikawa';
  static const String other = 'Other';

  static const List<String> all = [fiveWhy, fishbone, ishikawa, other];

  static String normalize(String? v) => all.contains(v) ? v as String : other;
}

// ── Shared vocabularies ───────────────────────────────────────────────────

/// Severity/criticality ladder shared by SOPs, goals and CAPA.
abstract final class QcPriority {
  static const String low = 'Low';
  static const String medium = 'Medium';
  static const String high = 'High';
  static const String critical = 'Critical';

  static const List<String> all = [low, medium, high, critical];

  static String normalize(String? v) => all.contains(v) ? v as String : medium;

  static int weight(String? v) => switch (normalize(v)) {
    critical => 4,
    high => 3,
    medium => 2,
    _ => 1,
  };
}

/// Entity kinds recorded in `qc_audits.entity_type`.
abstract final class QcAuditEntity {
  static const String sop = 'SOP';
  static const String sopRevision = 'SOP_REV';
  static const String sopRead = 'SOP_READ';
  static const String template = 'TEMPLATE';
  static const String section = 'SECTION';
  static const String item = 'ITEM';
  static const String inspection = 'INSPECTION';
  static const String response = 'RESPONSE';
  static const String finding = 'FINDING';
  static const String capa = 'CAPA';
  static const String goal = 'GOAL';
  static const String goalAssignment = 'GOAL_ASSIGNMENT';
  static const String goalAction = 'GOAL_ACTION';
  static const String ncr = 'NCR';
  static const String approval = 'APPROVAL';

  static const List<String> all = [
    sop,
    sopRevision,
    sopRead,
    template,
    section,
    item,
    inspection,
    response,
    finding,
    capa,
    goal,
    goalAssignment,
    goalAction,
    ncr,
    approval,
  ];
}

// ── Goal tracking ─────────────────────────────────────────────────────────

/// Goal lifecycle. A goal is `Completed` only with a recorded finisher
/// (`completed_by` + `completed_at`); see `QcGoal.completedBy`.
abstract final class QcGoalStatus {
  static const String draft = 'Draft';
  static const String active = 'Active';
  static const String onHold = 'OnHold';
  static const String completed = 'Completed';
  static const String cancelled = 'Cancelled';
  static const String archived = 'Archived';

  static const List<String> all = [
    draft,
    active,
    onHold,
    completed,
    cancelled,
    archived,
  ];

  static String normalize(String? v) => all.contains(v) ? v as String : draft;

  static bool isOpenState(String? v) {
    final s = normalize(v);
    return s == draft || s == active || s == onHold;
  }

  static const Map<String, List<String>> transitions = {
    draft: [active, cancelled, archived],
    active: [onHold, completed, cancelled, archived],
    onHold: [active, cancelled, archived],
    completed: [archived],
    cancelled: [archived],
    archived: [],
  };

  static bool canTransition(String from, String to) =>
      (transitions[normalize(from)] ?? const []).contains(normalize(to));
}

/// What kind of quality objective a goal represents.
abstract final class QcGoalType {
  static const String sop = 'SOP';
  static const String training = 'Training';
  static const String nc = 'NC';
  static const String capa = 'CAPA';
  static const String audit = 'Audit';
  static const String kpi = 'KPI';
  static const String compliance = 'Compliance';
  static const String other = 'Other';

  static const List<String> all = [
    sop,
    training,
    nc,
    capa,
    audit,
    kpi,
    compliance,
    other,
  ];

  static String normalize(String? v) => all.contains(v) ? v as String : other;
}

/// A person's accountability for a goal.
abstract final class QcGoalRole {
  static const String owner = 'Owner';
  static const String lead = 'Lead';
  static const String member = 'Member';
  static const String reviewer = 'Reviewer';

  static const List<String> all = [owner, lead, member, reviewer];

  static String normalize(String? v) => all.contains(v) ? v as String : member;
}

/// Per-assignment state. `completed_by`/`completed_by_name` record who finished
/// *this person's share*.
abstract final class QcGoalAssignmentStatus {
  static const String pending = 'Pending';
  static const String inProgress = 'InProgress';
  static const String completed = 'Completed';
  static const String rejected = 'Rejected';
  static const String cancelled = 'Cancelled';

  static const List<String> all = [
    pending,
    inProgress,
    completed,
    rejected,
    cancelled,
  ];

  static String normalize(String? v) => all.contains(v) ? v as String : pending;

  static bool isOpenState(String? v) {
    final s = normalize(v);
    return s == pending || s == inProgress;
  }
}

abstract final class QcGoalActionStatus {
  static const String todo = 'Todo';
  static const String inProgress = 'InProgress';
  static const String done = 'Done';
  static const String blocked = 'Blocked';
  static const String cancelled = 'Cancelled';

  static const List<String> all = [todo, inProgress, done, blocked, cancelled];

  static String normalize(String? v) => all.contains(v) ? v as String : todo;

  static bool isDone(String? v) => normalize(v) == done;
}

/// What a goal is evidenced against, so closing it can point at the records
/// that prove it.
abstract final class QcGoalLinkType {
  static const String sop = 'SOP';
  static const String inspection = 'INSPECTION';
  static const String finding = 'FINDING';
  static const String capa = 'CAPA';
  static const String template = 'TEMPLATE';
  static const String audit = 'AUDIT';
  static const String other = 'OTHER';

  static const List<String> all = [
    sop,
    inspection,
    finding,
    capa,
    template,
    audit,
    other,
  ];

  static String normalize(String? v) => all.contains(v) ? v as String : other;

  /// Table the `ref_id` points into, for the drilldown link.
  static String refTable(String? v) => switch (normalize(v)) {
    sop => 'qc_sops',
    inspection => 'qc_inspections',
    finding => 'qc_findings_nc',
    capa => 'qc_capa',
    template => 'qc_templates',
    _ => '',
  };
}
