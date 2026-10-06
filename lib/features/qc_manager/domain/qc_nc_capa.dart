import 'package:equatable/equatable.dart';

import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_format.dart';
import 'qc_enums.dart';

/// A non-conformance raised against an inspection (qc_manager/domain).
///
/// A finding is never created directly by the inspector: it is raised by the
/// submit transaction from a failing [QcResponse], which is why [inspectionId]
/// is non-nullable and [respId] points at the answer that caused it.
class QcFindingNc extends Equatable {
  final int? findingId;
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
  final String proposedAction;
  final double? qtyAffected;
  final String qtyUnit;
  final String disposition;
  final String verifiedBy;
  final String verifiedByName;
  final String verifiedAt;
  final String closedAt;
  final String closedBy;
  final String rejectedAt;
  final String rejectionReason;
  final String evidenceJson;
  final int? capaId;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;

  const QcFindingNc({
    this.findingId,
    required this.inspectionId,
    this.itemId,
    this.respId,
    this.code = '',
    required this.severity,
    this.category = '',
    required this.description,
    this.status = NcStatus.open,
    this.type = NcType.nonConformance,
    this.dueDate = '',
    this.assignedTo = '',
    this.assignedToName = '',
    this.assignedAt = '',
    this.rootCause = '',
    this.actionPlan = '',
    this.proposedAction = '',
    this.qtyAffected,
    this.qtyUnit = '',
    this.disposition = NcDisposition.pending,
    this.verifiedBy = '',
    this.verifiedByName = '',
    this.verifiedAt = '',
    this.closedAt = '',
    this.closedBy = '',
    this.rejectedAt = '',
    this.rejectionReason = '',
    this.evidenceJson = '',
    this.capaId,
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
  });

  bool get isCritical => severity == NcSeverity.critical;
  bool get isMajor => severity == NcSeverity.major;
  bool get isMinor => severity == NcSeverity.minor;

  /// Excluded from the open/overdue counts on the NCR report.
  bool get isClosed => status == NcStatus.closed || status == NcStatus.rejected;

  bool get isOpenState => NcStatus.isOpenState(status);

  bool get hasCapa => capaId != null;

  /// Days since the finding was raised. Uses the closure date once closed so a
  /// month-old closed finding does not age forever in a report.
  int get ageDays =>
      qcDaysBetween(createdAt, closedAt.isNotEmpty ? closedAt : nowIso());

  bool get isOverdue => isOpenState && qcIsPastDue(dueDate);

  /// A Critical NC may only be verified by someone other than the assignee.
  bool canBeVerifiedBy(String uid) =>
      isOpenState && uid.isNotEmpty && uid != assignedTo;

  List<String> get evidence =>
      jsonLoadsList(evidenceJson).map((e) => '$e').toList();

  @override
  List<Object?> get props => [
    findingId,
    inspectionId,
    itemId,
    respId,
    code,
    severity,
    category,
    description,
    status,
    type,
    dueDate,
    assignedTo,
    assignedToName,
    assignedAt,
    rootCause,
    actionPlan,
    proposedAction,
    qtyAffected,
    qtyUnit,
    disposition,
    verifiedBy,
    verifiedByName,
    verifiedAt,
    closedAt,
    closedBy,
    rejectedAt,
    rejectionReason,
    evidenceJson,
    capaId,
    deletedAt,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
  ];

  factory QcFindingNc.fromMap(Map<String, dynamic> m) => QcFindingNc(
    findingId: (m['finding_id'] as num?)?.toInt(),
    inspectionId: (m['inspection_id'] as num?)?.toInt() ?? 0,
    itemId: (m['item_id'] as num?)?.toInt(),
    respId: (m['resp_id'] as num?)?.toInt(),
    code: '${m['code'] ?? ''}',
    severity: NcSeverity.normalize('${m['severity'] ?? ''}'),
    category: '${m['category'] ?? ''}',
    description: '${m['description'] ?? ''}',
    status: NcStatus.normalize('${m['status'] ?? ''}'),
    type: NcType.normalize('${m['type'] ?? ''}'),
    dueDate: '${m['due_date'] ?? ''}',
    assignedTo: '${m['assigned_to'] ?? ''}',
    assignedToName: '${m['assigned_to_name'] ?? ''}',
    assignedAt: '${m['assigned_at'] ?? ''}',
    rootCause: '${m['root_cause'] ?? ''}',
    actionPlan: '${m['action_plan'] ?? ''}',
    proposedAction: '${m['proposed_action'] ?? ''}',
    qtyAffected: (m['qty_affected'] as num?)?.toDouble(),
    qtyUnit: '${m['qty_unit'] ?? ''}',
    disposition: NcDisposition.normalize('${m['disposition'] ?? ''}'),
    verifiedBy: '${m['verified_by'] ?? ''}',
    verifiedByName: '${m['verified_by_name'] ?? ''}',
    verifiedAt: '${m['verified_at'] ?? ''}',
    closedAt: '${m['closed_at'] ?? ''}',
    closedBy: '${m['closed_by'] ?? ''}',
    rejectedAt: '${m['rejected_at'] ?? ''}',
    rejectionReason: '${m['rejection_reason'] ?? ''}',
    evidenceJson: '${m['evidence_json'] ?? ''}',
    capaId: (m['capa_id'] as num?)?.toInt(),
    deletedAt: '${m['deleted_at'] ?? ''}',
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
    createdBy: '${m['created_by'] ?? ''}',
    updatedBy: '${m['updated_by'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && findingId != null) 'finding_id': findingId,
    'inspection_id': inspectionId,
    if (itemId != null) 'item_id': itemId,
    if (respId != null) 'resp_id': respId,
    'code': code,
    'severity': severity,
    'category': category,
    'description': description,
    'status': status,
    'type': type,
    'due_date': dueDate,
    'assigned_to': assignedTo,
    'assigned_to_name': assignedToName,
    'assigned_at': assignedAt,
    'root_cause': rootCause,
    'action_plan': actionPlan,
    'proposed_action': proposedAction,
    if (qtyAffected != null) 'qty_affected': qtyAffected,
    'qty_unit': qtyUnit,
    'disposition': disposition,
    'verified_by': verifiedBy,
    'verified_by_name': verifiedByName,
    'verified_at': verifiedAt,
    'closed_at': closedAt,
    'closed_by': closedBy,
    'rejected_at': rejectedAt,
    'rejection_reason': rejectionReason,
    'evidence_json': evidenceJson,
    if (capaId != null) 'capa_id': capaId,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy,
    'updated_by': updatedBy,
  };

  QcFindingNc copyWith({
    String? status,
    String? severity,
    String? dueDate,
    String? assignedTo,
    String? assignedToName,
    String? assignedAt,
    String? rootCause,
    String? actionPlan,
    String? proposedAction,
    String? disposition,
    String? verifiedBy,
    String? verifiedByName,
    String? verifiedAt,
    String? closedAt,
    String? closedBy,
    String? rejectedAt,
    String? rejectionReason,
    String? evidenceJson,
    int? capaId,
    String? updatedAt,
    String? updatedBy,
  }) => QcFindingNc(
    findingId: findingId,
    inspectionId: inspectionId,
    itemId: itemId,
    respId: respId,
    code: code,
    severity: severity ?? this.severity,
    category: category,
    description: description,
    status: status ?? this.status,
    type: type,
    dueDate: dueDate ?? this.dueDate,
    assignedTo: assignedTo ?? this.assignedTo,
    assignedToName: assignedToName ?? this.assignedToName,
    assignedAt: assignedAt ?? this.assignedAt,
    rootCause: rootCause ?? this.rootCause,
    actionPlan: actionPlan ?? this.actionPlan,
    proposedAction: proposedAction ?? this.proposedAction,
    qtyAffected: qtyAffected,
    qtyUnit: qtyUnit,
    disposition: disposition ?? this.disposition,
    verifiedBy: verifiedBy ?? this.verifiedBy,
    verifiedByName: verifiedByName ?? this.verifiedByName,
    verifiedAt: verifiedAt ?? this.verifiedAt,
    closedAt: closedAt ?? this.closedAt,
    closedBy: closedBy ?? this.closedBy,
    rejectedAt: rejectedAt ?? this.rejectedAt,
    rejectionReason: rejectionReason ?? this.rejectionReason,
    evidenceJson: evidenceJson ?? this.evidenceJson,
    capaId: capaId ?? this.capaId,
    deletedAt: deletedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    createdBy: createdBy,
    updatedBy: updatedBy ?? this.updatedBy,
  );
}

/// A corrective/preventive action raised for a finding.
///
/// The status machine in [CapaStatus.transitions] is what stops the classic
/// failure mode of closing a CAPA in the same edit that performs the action:
/// `actionComplete` must be followed by an independent effectiveness verdict.
class QcCapa extends Equatable {
  final int? capaId;
  final int findingId;
  final String capaNo;
  final String type;
  final String title;
  final String description;
  final String rootCause;
  final String rootCauseMethod;

  /// Mandatory - a CAPA without a stated action is not an action.
  final String actionPlan;
  final String actionStepsJson;
  final String assignedTo;
  final String assignedToName;
  final String dept;
  final String status;
  final String priority;
  final String dueAt;
  final String targetCompletionAt;
  final String actionCompletedAt;
  final String actionCompletedBy;
  final String actionCompletionNotes;
  final String verifiedBy;
  final String verifiedByName;
  final String verifiedAt;
  final String verificationNotes;
  final bool isEffective;
  final String effectivenessCheckedAt;
  final String effectivenessNotes;
  final String closureNotes;
  final String closedAt;
  final String closedBy;
  final String rejectedAt;
  final String rejectionReason;
  final String evidenceJson;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;

  const QcCapa({
    this.capaId,
    required this.findingId,
    this.capaNo = '',
    this.type = CapaType.corrective,
    this.title = '',
    this.description = '',
    this.rootCause = '',
    this.rootCauseMethod = RootCauseMethod.other,
    required this.actionPlan,
    this.actionStepsJson = '',
    this.assignedTo = '',
    this.assignedToName = '',
    this.dept = '',
    this.status = CapaStatus.open,
    this.priority = QcPriority.medium,
    this.dueAt = '',
    this.targetCompletionAt = '',
    this.actionCompletedAt = '',
    this.actionCompletedBy = '',
    this.actionCompletionNotes = '',
    this.verifiedBy = '',
    this.verifiedByName = '',
    this.verifiedAt = '',
    this.verificationNotes = '',
    this.isEffective = false,
    this.effectivenessCheckedAt = '',
    this.effectivenessNotes = '',
    this.closureNotes = '',
    this.closedAt = '',
    this.closedBy = '',
    this.rejectedAt = '',
    this.rejectionReason = '',
    this.evidenceJson = '',
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
  });

  bool get isClosed =>
      status == CapaStatus.closed || status == CapaStatus.rejected;

  bool get awaitsVerification => CapaStatus.awaitsVerification(status);

  /// Closed only once the loop actually terminated.
  bool get isEffectivenessVerified => isEffective && verifiedAt.isNotEmpty;

  /// Days between the action being reported done and the effectiveness verdict -
  /// the lag the NCR report surfaces as MTTV.
  int? get verificationLagDays {
    if (actionCompletedAt.isEmpty || verifiedAt.isEmpty) return null;
    return qcDaysBetween(actionCompletedAt, verifiedAt);
  }

  int get ageDays =>
      qcDaysBetween(createdAt, closedAt.isNotEmpty ? closedAt : nowIso());

  bool get isOverdue =>
      CapaStatus.isOverdue({'status': status, 'due_at': dueAt});

  /// The person who carried out the action. Only a uid is stored (there is no
  /// `action_completed_by_name` column), so the UI resolves the display name
  /// through the members roster rather than trusting a denormalised copy.
  String get actionCompletedByLabel =>
      actionCompletedBy.isEmpty ? '-' : actionCompletedBy;

  List<String> get actionSteps =>
      jsonLoadsList(actionStepsJson).map((e) => '$e').toList();

  @override
  List<Object?> get props => [
    capaId,
    findingId,
    capaNo,
    type,
    title,
    description,
    rootCause,
    rootCauseMethod,
    actionPlan,
    actionStepsJson,
    assignedTo,
    assignedToName,
    dept,
    status,
    priority,
    dueAt,
    targetCompletionAt,
    actionCompletedAt,
    actionCompletedBy,
    actionCompletionNotes,
    verifiedBy,
    verifiedByName,
    verifiedAt,
    verificationNotes,
    isEffective,
    effectivenessCheckedAt,
    effectivenessNotes,
    closureNotes,
    closedAt,
    closedBy,
    rejectedAt,
    rejectionReason,
    evidenceJson,
    deletedAt,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
  ];

  factory QcCapa.fromMap(Map<String, dynamic> m) => QcCapa(
    capaId: (m['capa_id'] as num?)?.toInt(),
    findingId: (m['finding_id'] as num?)?.toInt() ?? 0,
    capaNo: '${m['capa_no'] ?? ''}',
    type: CapaType.normalize('${m['type'] ?? ''}'),
    title: '${m['title'] ?? ''}',
    description: '${m['description'] ?? ''}',
    rootCause: '${m['root_cause'] ?? ''}',
    rootCauseMethod: RootCauseMethod.normalize(
      '${m['root_cause_method'] ?? ''}',
    ),
    actionPlan: '${m['action_plan'] ?? ''}',
    actionStepsJson: '${m['action_steps_json'] ?? ''}',
    assignedTo: '${m['assigned_to'] ?? ''}',
    assignedToName: '${m['assigned_to_name'] ?? ''}',
    dept: '${m['dept'] ?? ''}',
    status: CapaStatus.normalize('${m['status'] ?? ''}'),
    priority: QcPriority.normalize('${m['priority'] ?? ''}'),
    dueAt: '${m['due_at'] ?? ''}',
    targetCompletionAt: '${m['target_completion_at'] ?? ''}',
    actionCompletedAt: '${m['action_completed_at'] ?? ''}',
    actionCompletedBy: '${m['action_completed_by'] ?? ''}',
    actionCompletionNotes: '${m['action_completion_notes'] ?? ''}',
    verifiedBy: '${m['verified_by'] ?? ''}',
    verifiedByName: '${m['verified_by_name'] ?? ''}',
    verifiedAt: '${m['verified_at'] ?? ''}',
    verificationNotes: '${m['verification_notes'] ?? ''}',
    isEffective: (m['is_effective'] as num?)?.toInt() == 1,
    effectivenessCheckedAt: '${m['effectiveness_checked_at'] ?? ''}',
    effectivenessNotes: '${m['effectiveness_notes'] ?? ''}',
    closureNotes: '${m['closure_notes'] ?? ''}',
    closedAt: '${m['closed_at'] ?? ''}',
    closedBy: '${m['closed_by'] ?? ''}',
    rejectedAt: '${m['rejected_at'] ?? ''}',
    rejectionReason: '${m['rejection_reason'] ?? ''}',
    evidenceJson: '${m['evidence_json'] ?? ''}',
    deletedAt: '${m['deleted_at'] ?? ''}',
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
    createdBy: '${m['created_by'] ?? ''}',
    updatedBy: '${m['updated_by'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && capaId != null) 'capa_id': capaId,
    'finding_id': findingId,
    'capa_no': capaNo,
    'type': type,
    'title': title,
    'description': description,
    'root_cause': rootCause,
    'root_cause_method': rootCauseMethod,
    'action_plan': actionPlan,
    'action_steps_json': actionStepsJson,
    'assigned_to': assignedTo,
    'assigned_to_name': assignedToName,
    'dept': dept,
    'status': status,
    'priority': priority,
    'due_at': dueAt,
    'target_completion_at': targetCompletionAt,
    'action_completed_at': actionCompletedAt,
    'action_completed_by': actionCompletedBy,
    'action_completion_notes': actionCompletionNotes,
    'verified_by': verifiedBy,
    'verified_by_name': verifiedByName,
    'verified_at': verifiedAt,
    'verification_notes': verificationNotes,
    'is_effective': isEffective ? 1 : 0,
    'effectiveness_checked_at': effectivenessCheckedAt,
    'effectiveness_notes': effectivenessNotes,
    'closure_notes': closureNotes,
    'closed_at': closedAt,
    'closed_by': closedBy,
    'rejected_at': rejectedAt,
    'rejection_reason': rejectionReason,
    'evidence_json': evidenceJson,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy,
    'updated_by': updatedBy,
  };

  QcCapa copyWith({
    String? status,
    String? actionPlan,
    String? actionStepsJson,
    String? assignedTo,
    String? assignedToName,
    String? priority,
    String? dueAt,
    String? actionCompletedAt,
    String? actionCompletedBy,
    String? actionCompletionNotes,
    String? verifiedBy,
    String? verifiedByName,
    String? verifiedAt,
    String? verificationNotes,
    bool? isEffective,
    String? effectivenessCheckedAt,
    String? effectivenessNotes,
    String? closureNotes,
    String? closedAt,
    String? closedBy,
    String? evidenceJson,
    String? updatedAt,
    String? updatedBy,
  }) => QcCapa(
    capaId: capaId,
    findingId: findingId,
    capaNo: capaNo,
    type: type,
    title: title,
    description: description,
    rootCause: rootCause,
    rootCauseMethod: rootCauseMethod,
    actionPlan: actionPlan ?? this.actionPlan,
    actionStepsJson: actionStepsJson ?? this.actionStepsJson,
    assignedTo: assignedTo ?? this.assignedTo,
    assignedToName: assignedToName ?? this.assignedToName,
    dept: dept,
    status: status ?? this.status,
    priority: priority ?? this.priority,
    dueAt: dueAt ?? this.dueAt,
    targetCompletionAt: targetCompletionAt,
    actionCompletedAt: actionCompletedAt ?? this.actionCompletedAt,
    actionCompletedBy: actionCompletedBy ?? this.actionCompletedBy,
    actionCompletionNotes: actionCompletionNotes ?? this.actionCompletionNotes,
    verifiedBy: verifiedBy ?? this.verifiedBy,
    verifiedByName: verifiedByName ?? this.verifiedByName,
    verifiedAt: verifiedAt ?? this.verifiedAt,
    verificationNotes: verificationNotes ?? this.verificationNotes,
    isEffective: isEffective ?? this.isEffective,
    effectivenessCheckedAt:
        effectivenessCheckedAt ?? this.effectivenessCheckedAt,
    effectivenessNotes: effectivenessNotes ?? this.effectivenessNotes,
    closureNotes: closureNotes ?? this.closureNotes,
    closedAt: closedAt ?? this.closedAt,
    closedBy: closedBy ?? this.closedBy,
    rejectedAt: rejectedAt,
    rejectionReason: rejectionReason,
    evidenceJson: evidenceJson ?? this.evidenceJson,
    deletedAt: deletedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    createdBy: createdBy,
    updatedBy: updatedBy ?? this.updatedBy,
  );
}

/// Master defect catalogue, used to pick a code and default severity when an
/// inspector raises a finding.
class QcDefectCode extends Equatable {
  final int? id;
  final String code;
  final String name;
  final String description;
  final String category;
  final String severity;
  final String defaultType;
  final String suggestedCapa;
  final bool isActive;
  final String dept;

  const QcDefectCode({
    this.id,
    required this.code,
    required this.name,
    this.description = '',
    this.category = '',
    this.severity = NcSeverity.minor,
    this.defaultType = NcType.nonConformance,
    this.suggestedCapa = '',
    this.isActive = true,
    this.dept = '',
  });

  @override
  List<Object?> get props => [
    id,
    code,
    name,
    description,
    category,
    severity,
    defaultType,
    suggestedCapa,
    isActive,
    dept,
  ];

  factory QcDefectCode.fromMap(Map<String, dynamic> m) => QcDefectCode(
    id: (m['id'] as num?)?.toInt(),
    code: '${m['code'] ?? ''}',
    name: '${m['name'] ?? ''}',
    description: '${m['description'] ?? ''}',
    category: '${m['category'] ?? ''}',
    severity: NcSeverity.normalize('${m['severity'] ?? ''}'),
    defaultType: NcType.normalize('${m['default_type'] ?? ''}'),
    suggestedCapa: '${m['suggested_capa'] ?? ''}',
    isActive: (m['is_active'] as num?)?.toInt() != 0,
    dept: '${m['dept'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && id != null) 'id': id,
    'code': code,
    'name': name,
    'description': description,
    'category': category,
    'severity': severity,
    'default_type': defaultType,
    'suggested_capa': suggestedCapa,
    'is_active': isActive ? 1 : 0,
    'dept': dept,
  };
}
