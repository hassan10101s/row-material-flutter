import 'package:equatable/equatable.dart';

/// One row of the central NCR report (plan V6_ENHANCED §22.2).
///
/// A projection, not an entity: it is derived by joining `qc_findings_nc` to its
/// inspection and its CAPA, and nothing is ever written back. Every field comes
/// from a column that actually exists - the plan's sample SQL referenced
/// `qc_inspections.is_deleted`, but both QC tables soft-delete through
/// `deleted_at`, so a row whose inspection was deleted is *not* joined.
///
/// The finding's own columns keep their names (`status`, `dueDate`, ...). The
/// inspection's are prefixed `inspection` and the CAPA's `capa`, because
/// otherwise `status` and `due_date` would silently collide - the finding is
/// open while its CAPA may already be closed, and a report that cannot tell them
/// apart is worse than no report.
class NcrReportRow extends Equatable {
  const NcrReportRow({
    required this.findingId,
    required this.inspectionId,
    this.itemId,
    this.respId,
    this.code = '',
    required this.severity,
    this.category = '',
    required this.description,
    required this.status,
    this.type = '',
    this.dueDate = '',
    this.assignedTo = '',
    this.assignedToName = '',
    this.assignedAt = '',
    this.rootCause = '',
    this.actionPlan = '',
    this.disposition = '',
    this.qtyAffected,
    this.qtyUnit = '',
    this.verifiedBy = '',
    this.verifiedByName = '',
    this.verifiedAt = '',
    this.closedAt = '',
    this.rejectedAt = '',
    this.evidenceJson = '',
    this.capaId,
    this.createdAt = '',
    this.updatedAt = '',
    this.createdBy = '',
    // Inspection context
    this.inspectionRefType = '',
    this.inspectionRefId = '',
    this.lotNo = '',
    this.batchNo = '',
    this.poNo = '',
    this.grnNo = '',
    this.dept = '',
    this.site = '',
    this.location = '',
    this.line = '',
    this.workCenter = '',
    this.inspectorId = '',
    this.inspectorName = '',
    this.inspectionDate = '',
    this.inspectionStatus = '',
    // CAPA context
    this.capaNo = '',
    this.capaType = '',
    this.capaStatus = '',
    this.capaPriority = '',
    this.capaDueAt = '',
    this.capaTargetCompletionAt = '',
    this.capaActionCompletedAt = '',
    this.capaVerifiedAt = '',
    this.capaIsEffective = false,
    this.capaClosedAt = '',
    this.capaAssignedTo = '',
    this.capaAssignedToName = '',
  });

  final int findingId;
  final int inspectionId;
  final int? itemId;
  final int? respId;
  final String code;
  final String severity;
  final String category;
  final String description;
  final String status;
  final String type;
  final String dueDate;
  final String assignedTo;
  final String assignedToName;
  final String assignedAt;
  final String rootCause;
  final String actionPlan;
  final String disposition;
  final double? qtyAffected;
  final String qtyUnit;
  final String verifiedBy;
  final String verifiedByName;
  final String verifiedAt;
  final String closedAt;
  final String rejectedAt;
  final String evidenceJson;
  final int? capaId;
  final String createdAt;
  final String updatedAt;
  final String createdBy;

  final String inspectionRefType;
  final String inspectionRefId;
  final String lotNo;
  final String batchNo;
  final String poNo;
  final String grnNo;
  final String dept;
  final String site;
  final String location;
  final String line;
  final String workCenter;
  final String inspectorId;
  final String inspectorName;
  final String inspectionDate;
  final String inspectionStatus;

  final String capaNo;
  final String capaType;
  final String capaStatus;
  final String capaPriority;
  final String capaDueAt;
  final String capaTargetCompletionAt;
  final String capaActionCompletedAt;
  final String capaVerifiedAt;
  final bool capaIsEffective;
  final String capaClosedAt;
  final String capaAssignedTo;
  final String capaAssignedToName;

  /// True while the finding still needs somebody to act on it.
  ///
  /// `Verified` counts as open: a finding nobody has closed is unresolved no
  /// matter how many signatures it has collected.
  bool get isOpen => status != 'Closed' && status != 'Rejected';

  /// A CAPA exists and has not been thrown away.
  bool get hasCapa =>
      capaId != null && capaStatus.isNotEmpty && capaStatus != 'Rejected';

  /// The plan's on-time rule (§22.3): closed on or before the due date. A
  /// finding with no due date is *not* counted as on time - it had no
  /// commitment to meet, so scoring it as a win would inflate the KPI.
  bool get closedOnTime {
    if (status != 'Closed') return false;
    if (dueDate.isEmpty || closedAt.isEmpty) return false;
    return _dateOnly(closedAt).compareTo(_dateOnly(dueDate)) <= 0;
  }

  /// Days between creation and the terminal event, used for aging and MTTC.
  ///
  /// Null when the finding has not reached a terminal state, because an open
  /// finding's age is "so far", not a duration - that belongs in the aging
  /// buckets, where the number is labelled.
  int? get ageDays {
    final end = status == 'Closed'
        ? closedAt
        : status == 'Verified'
        ? verifiedAt
        : '';
    if (end.isEmpty || createdAt.isEmpty) return null;
    return _daysBetween(createdAt, end);
  }

  /// Days since creation for a finding that is still open.
  int? get openDays => isOpen && createdAt.isNotEmpty
      ? _daysBetween(createdAt, nowStamp())
      : null;

  bool get isOverdue {
    if (!isOpen || dueDate.isEmpty) return false;
    return _dateOnly(dueDate).compareTo(_dateOnly(nowStamp())) < 0;
  }

  /// Whether the linked CAPA is past its own due date and not finished.
  ///
  /// Separate from [isOverdue] because they answer different questions: the
  /// finding can be closed while its corrective action is still running, and
  /// collapsing the two would hide a late CAPA behind a closed NCR.
  bool get capaIsOverdueToday {
    if (capaId == null || capaDueAt.isEmpty) return false;
    if (capaStatus == 'Closed' ||
        capaStatus == 'Rejected' ||
        capaStatus == 'VerifiedEffective') {
      return false;
    }
    return _dateOnly(capaDueAt).compareTo(_dateOnly(nowStamp())) < 0;
  }

  /// The label a screen shows: the code when there is one, else the id.
  String get reference => code.isNotEmpty ? code : 'NC-$findingId';

  factory NcrReportRow.fromMap(Map<String, dynamic> map) => NcrReportRow(
    findingId: _int(map['finding_id']) ?? 0,
    inspectionId: _int(map['inspection_id']) ?? 0,
    itemId: _int(map['item_id']),
    respId: _int(map['resp_id']),
    code: _str(map['code']),
    severity: _str(map['severity']),
    category: _str(map['category']),
    description: _str(map['description']),
    status: _str(map['status']),
    type: _str(map['type']),
    dueDate: _str(map['due_date']),
    assignedTo: _str(map['assigned_to']),
    assignedToName: _str(map['assigned_to_name']),
    assignedAt: _str(map['assigned_at']),
    rootCause: _str(map['root_cause']),
    actionPlan: _str(map['action_plan']),
    disposition: _str(map['disposition']),
    qtyAffected: _double(map['qty_affected']),
    qtyUnit: _str(map['qty_unit']),
    verifiedBy: _str(map['verified_by']),
    verifiedByName: _str(map['verified_by_name']),
    verifiedAt: _str(map['verified_at']),
    closedAt: _str(map['closed_at']),
    rejectedAt: _str(map['rejected_at']),
    evidenceJson: _str(map['evidence_json']),
    capaId: _int(map['capa_id']),
    createdAt: _str(map['created_at']),
    updatedAt: _str(map['updated_at']),
    createdBy: _str(map['created_by']),
    inspectionRefType: _str(map['inspection_ref_type']),
    inspectionRefId: _str(map['inspection_ref_id']),
    lotNo: _str(map['lot_no']),
    batchNo: _str(map['batch_no']),
    poNo: _str(map['po_no']),
    grnNo: _str(map['grn_no']),
    dept: _str(map['dept']),
    site: _str(map['site']),
    location: _str(map['location']),
    line: _str(map['line']),
    workCenter: _str(map['work_center']),
    inspectorId: _str(map['inspector_id']),
    inspectorName: _str(map['inspector_name']),
    inspectionDate: _str(map['inspection_date']),
    inspectionStatus: _str(map['inspection_status']),
    capaNo: _str(map['capa_no']),
    capaType: _str(map['capa_type']),
    capaStatus: _str(map['capa_status']),
    capaPriority: _str(map['capa_priority']),
    capaDueAt: _str(map['capa_due_at']),
    capaTargetCompletionAt: _str(map['capa_target_completion_at']),
    capaActionCompletedAt: _str(map['capa_action_completed_at']),
    capaVerifiedAt: _str(map['capa_verified_at']),
    capaIsEffective: _bool(map['capa_is_effective']),
    capaClosedAt: _str(map['capa_closed_at']),
    capaAssignedTo: _str(map['capa_assigned_to']),
    capaAssignedToName: _str(map['capa_assigned_to_name']),
  );

  @override
  List<Object?> get props => [
    findingId,
    inspectionId,
    code,
    severity,
    description,
    status,
    dueDate,
    assignedTo,
    capaId,
    capaStatus,
    createdAt,
    closedAt,
  ];
}

/// Days between two `yyyy-MM-dd HH:mm:ss` stamps, as whole days.
///
/// Date-only on purpose: `closedAt` carries a time of day and `dueDate` does
/// not, so comparing them raw would call a finding closed at 09:00 on its due
/// date one day late.
int _daysBetween(String from, String to) {
  final a = DateTime.tryParse(from.replaceFirst(' ', 'T'));
  final b = DateTime.tryParse(to.replaceFirst(' ', 'T'));
  if (a == null || b == null) return 0;
  final days = _midnight(b).difference(_midnight(a)).inDays;
  // A negative span means the data is inconsistent (closed before it was
  // raised). Clamped to zero so it cannot quietly drag MTTC down and flatter
  // the process; the inconsistency itself is visible in the timeline instead.
  return days < 0 ? 0 : days;
}

DateTime _midnight(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// Parses a stored stamp down to its date, tolerating both storage formats
/// (`yyyy-MM-dd HH:mm:ss` and a bare `yyyy-MM-dd`). Unparseable input maps to
/// the epoch, which keeps comparisons total - a missing due date must never
/// throw in the middle of rendering a KPI card.
DateTime _dateOnly(String stamp) => _midnight(
  DateTime.tryParse(stamp.trim().replaceFirst(' ', 'T')) ?? DateTime(1970),
);

/// "now" in the storage format, injected rather than read from the clock so the
/// KPI maths stays testable.
String nowStamp() => _stamp(DateTime.now());

/// Today as `yyyy-MM-dd` - the form the overdue comparisons are written in.
String todayStamp() {
  final now = DateTime.now();
  return '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
}

String _stamp(DateTime when) =>
    '${when.year.toString().padLeft(4, '0')}-'
    '${when.month.toString().padLeft(2, '0')}-'
    '${when.day.toString().padLeft(2, '0')} '
    '${when.hour.toString().padLeft(2, '0')}:'
    '${when.minute.toString().padLeft(2, '0')}:'
    '${when.second.toString().padLeft(2, '0')}';

String _str(Object? v) => v == null ? '' : '$v';

int? _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('$v');
}

double? _double(Object? v) {
  if (v is double) return v;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}

bool _bool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  return v == 1 || '$v'.toLowerCase() == 'true';
}
