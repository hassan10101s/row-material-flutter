import 'package:equatable/equatable.dart';

import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_format.dart';
import 'qc_enums.dart';

/// A measurable quality objective (features/qc_manager/domain, plan
/// V6_ENHANCED §12).
///
/// The three fields [completedAt], [completedBy] and [completedByName] are the
/// point of the feature: a goal is not "done" until somebody is recorded as
/// having finished it. [hasFinisher] is what the completion transaction and the
/// UI both gate on, so a half-written completion cannot pass as a closed goal.
class QcGoal extends Equatable {
  final int? goalId;
  final String code;
  final String title;
  final String description;
  final String goalType;
  final String dept;
  final String site;
  final String priority;
  final String status;
  final double? targetValue;
  final String targetUnit;
  final double? baselineValue;
  final double? currentValue;
  final String startDate;
  final String dueDate;

  /// ── Who finished it ──
  final String completedAt;
  final String completedBy;
  final String completedByName;
  final String completionNotes;

  /// JSON array of evidence paths backing the completion. Required for a
  /// Critical-priority goal.
  final String completionEvidenceJson;

  final String ownerId;
  final String ownerName;
  final String approverId;
  final String approverName;
  final String approvedAt;
  final String tags;
  final bool isActive;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;

  /// Optimistic-concurrency counter, bumped by the repository on every write.
  ///
  /// A goal can be open for weeks and edited from two devices before the sync
  /// brings them together; without a version to compare, whichever edit landed
  /// last silently wins and the losing one is gone with no trace. The repository
  /// turns a stale [version] into an error instead of an overwrite.
  final int version;

  const QcGoal({
    this.goalId,
    required this.code,
    required this.title,
    this.description = '',
    this.goalType = QcGoalType.other,
    this.dept = '',
    this.site = '',
    this.priority = QcPriority.medium,
    this.status = QcGoalStatus.draft,
    this.targetValue,
    this.targetUnit = '',
    this.baselineValue,
    this.currentValue,
    required this.startDate,
    this.dueDate = '',
    this.completedAt = '',
    this.completedBy = '',
    this.completedByName = '',
    this.completionNotes = '',
    this.completionEvidenceJson = '',
    this.ownerId = '',
    this.ownerName = '',
    this.approverId = '',
    this.approverName = '',
    this.approvedAt = '',
    this.tags = '',
    this.isActive = true,
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
    this.version = 1,
  });

  bool get isDeleted => deletedAt.isNotEmpty;
  bool get isCompleted => status == QcGoalStatus.completed;
  bool get isOpenState => QcGoalStatus.isOpenState(status);
  bool get isOverdue => isOpenState && qcIsPastDue(dueDate);

  /// A completion is only real once it names who did it and when. This is the
  /// single check that keeps "Completed" from meaning "someone clicked save".
  bool get hasFinisher => completedBy.isNotEmpty && completedAt.isNotEmpty;

  /// Critical goals additionally require evidence, so a bare name cannot close
  /// them.
  bool get needsEvidence => priority == QcPriority.critical;

  bool get hasCompletionEvidence =>
      jsonLoadsList(completionEvidenceJson).isNotEmpty;

  /// Whether this goal may legally be marked complete right now, and why not
  /// when it may not. The form layer turns the message into a field error.
  String get completionBlocker {
    if (!isOpenState && status != QcGoalStatus.completed) {
      return 'Goal is not in an open state';
    }
    if (completedBy.trim().isEmpty) return 'A finisher ID is required';
    if (completedByName.trim().isEmpty) return 'A finisher name is required';
    if (completedAt.trim().isEmpty) return 'A completion date is required';
    if (needsEvidence && !hasCompletionEvidence) {
      return 'Evidence is required for a critical goal';
    }
    return '';
  }

  /// Progress toward [targetValue] as 0..1, or null when the goal is not
  /// measured. Direction is inferred from the baseline: a falling target
  /// (defect counts, cost) counts down, a rising one counts up.
  double? get progress {
    final target = targetValue;
    if (target == null || target == 0) return null;
    final current = currentValue ?? baselineValue;
    if (current == null) return null;
    final falling = target < (baselineValue ?? 0);
    final span = falling
        ? (baselineValue ?? 0) - target
        : target - (baselineValue ?? 0);
    if (span == 0) return null;
    final done = falling
        ? (baselineValue ?? 0) - current
        : current - (baselineValue ?? 0);
    return (done / span).clamp(0.0, 1.0);
  }

  int get ageDays =>
      qcDaysBetween(startDate, completedAt.isNotEmpty ? completedAt : nowIso());

  List<String> get tagList => tags.isEmpty
      ? const []
      : tags
            .split(',')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList();

  List<String> get completionEvidence =>
      jsonLoadsList(completionEvidenceJson).map((e) => '$e').toList();

  @override
  List<Object?> get props => [
    goalId,
    code,
    title,
    description,
    goalType,
    dept,
    site,
    priority,
    status,
    targetValue,
    targetUnit,
    baselineValue,
    currentValue,
    startDate,
    dueDate,
    completedAt,
    completedBy,
    completedByName,
    completionNotes,
    completionEvidenceJson,
    ownerId,
    ownerName,
    approverId,
    approverName,
    approvedAt,
    tags,
    isActive,
    deletedAt,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
    version,
  ];

  factory QcGoal.fromMap(Map<String, dynamic> m) => QcGoal(
    goalId: (m['goal_id'] as num?)?.toInt(),
    code: '${m['code'] ?? ''}',
    title: '${m['title'] ?? ''}',
    description: '${m['description'] ?? ''}',
    goalType: QcGoalType.normalize('${m['goal_type'] ?? ''}'),
    dept: '${m['dept'] ?? ''}',
    site: '${m['site'] ?? ''}',
    priority: QcPriority.normalize('${m['priority'] ?? ''}'),
    status: QcGoalStatus.normalize('${m['status'] ?? ''}'),
    targetValue: (m['target_value'] as num?)?.toDouble(),
    targetUnit: '${m['target_unit'] ?? ''}',
    baselineValue: (m['baseline_value'] as num?)?.toDouble(),
    currentValue: (m['current_value'] as num?)?.toDouble(),
    startDate: '${m['start_date'] ?? ''}',
    dueDate: '${m['due_date'] ?? ''}',
    completedAt: '${m['completed_at'] ?? ''}',
    completedBy: '${m['completed_by'] ?? ''}',
    completedByName: '${m['completed_by_name'] ?? ''}',
    completionNotes: '${m['completion_notes'] ?? ''}',
    completionEvidenceJson: '${m['completion_evidence_json'] ?? ''}',
    ownerId: '${m['owner_id'] ?? ''}',
    ownerName: '${m['owner_name'] ?? ''}',
    approverId: '${m['approver_id'] ?? ''}',
    approverName: '${m['approver_name'] ?? ''}',
    approvedAt: '${m['approved_at'] ?? ''}',
    tags: '${m['tags'] ?? ''}',
    isActive: (m['is_active'] as num?)?.toInt() != 0,
    deletedAt: '${m['deleted_at'] ?? ''}',
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
    createdBy: '${m['created_by'] ?? ''}',
    updatedBy: '${m['updated_by'] ?? ''}',
    version: (m['version'] as num?)?.toInt() ?? 1,
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && goalId != null) 'goal_id': goalId,
    'code': code,
    'title': title,
    'description': description,
    'goal_type': goalType,
    'dept': dept,
    'site': site,
    'priority': priority,
    'status': status,
    if (targetValue != null) 'target_value': targetValue,
    'target_unit': targetUnit,
    if (baselineValue != null) 'baseline_value': baselineValue,
    if (currentValue != null) 'current_value': currentValue,
    'start_date': startDate,
    'due_date': dueDate,
    'completed_at': completedAt,
    'completed_by': completedBy,
    'completed_by_name': completedByName,
    'completion_notes': completionNotes,
    'completion_evidence_json': completionEvidenceJson,
    'owner_id': ownerId,
    'owner_name': ownerName,
    'approver_id': approverId,
    'approver_name': approverName,
    'approved_at': approvedAt,
    'tags': tags,
    'is_active': isActive ? 1 : 0,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy,
    'updated_by': updatedBy,
    'version': version,
  };

  QcGoal copyWith({
    String? title,
    String? description,
    String? goalType,
    String? dept,
    String? site,
    String? priority,
    String? status,
    double? targetValue,
    String? targetUnit,
    double? baselineValue,
    double? currentValue,
    String? startDate,
    String? dueDate,
    String? completedAt,
    String? completedBy,
    String? completedByName,
    String? completionNotes,
    String? completionEvidenceJson,
    String? ownerId,
    String? ownerName,
    String? approverId,
    String? approverName,
    String? approvedAt,
    String? tags,
    bool? isActive,
    String? deletedAt,
    String? updatedAt,
    String? updatedBy,
    int? version,
  }) => QcGoal(
    goalId: goalId,
    code: code,
    title: title ?? this.title,
    description: description ?? this.description,
    goalType: goalType ?? this.goalType,
    dept: dept ?? this.dept,
    site: site ?? this.site,
    priority: priority ?? this.priority,
    status: status ?? this.status,
    targetValue: targetValue ?? this.targetValue,
    targetUnit: targetUnit ?? this.targetUnit,
    baselineValue: baselineValue ?? this.baselineValue,
    currentValue: currentValue ?? this.currentValue,
    startDate: startDate ?? this.startDate,
    dueDate: dueDate ?? this.dueDate,
    completedAt: completedAt ?? this.completedAt,
    completedBy: completedBy ?? this.completedBy,
    completedByName: completedByName ?? this.completedByName,
    completionNotes: completionNotes ?? this.completionNotes,
    completionEvidenceJson:
        completionEvidenceJson ?? this.completionEvidenceJson,
    ownerId: ownerId ?? this.ownerId,
    ownerName: ownerName ?? this.ownerName,
    approverId: approverId ?? this.approverId,
    approverName: approverName ?? this.approverName,
    approvedAt: approvedAt ?? this.approvedAt,
    tags: tags ?? this.tags,
    isActive: isActive ?? this.isActive,
    deletedAt: deletedAt ?? this.deletedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    createdBy: createdBy,
    updatedBy: updatedBy ?? this.updatedBy,
    version: version ?? this.version,
  );
}

/// One person's accountability for a goal, and - once done - who finished
/// their share.
///
/// `UNIQUE(goal_id, assignee_id)` means a person appears at most once per goal,
/// so reassignment is an update of the existing row rather than a second row
/// that would double-count completion progress.
class QcGoalAssignment extends Equatable {
  final int? assignId;
  final int goalId;
  final String assigneeId;
  final String assigneeName;
  final String role;
  final String assignedAt;
  final String assignedBy;
  final String assignedByName;
  final String dueDate;
  final String status;
  final String completedAt;
  final String completedBy;
  final String completedByName;
  final String completionNotes;
  final String completionEvidenceJson;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;

  const QcGoalAssignment({
    this.assignId,
    required this.goalId,
    required this.assigneeId,
    this.assigneeName = '',
    this.role = QcGoalRole.member,
    required this.assignedAt,
    this.assignedBy = '',
    this.assignedByName = '',
    this.dueDate = '',
    this.status = QcGoalAssignmentStatus.pending,
    this.completedAt = '',
    this.completedBy = '',
    this.completedByName = '',
    this.completionNotes = '',
    this.completionEvidenceJson = '',
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isCompleted => status == QcGoalAssignmentStatus.completed;
  bool get isOpenState => QcGoalAssignmentStatus.isOpenState(status);
  bool get hasFinisher => completedBy.isNotEmpty && completedAt.isNotEmpty;

  bool get isOverdue => isOpenState && qcIsPastDue(dueDate);

  /// Completion requires naming who finished it - same rule as the goal.
  String get completionBlocker {
    if (isCompleted && !hasFinisher) return 'A finisher is required';
    if (completedAt.isNotEmpty && completedBy.isEmpty) {
      return 'A completion date requires a finisher';
    }
    return '';
  }

  /// The label to show in a "finished by" column: the name, falling back to
  /// the uid so the row is never blank when a member has left the roster.
  String get completedByLabel =>
      completedByName.isNotEmpty ? completedByName : completedBy;

  String get assigneeLabel =>
      assigneeName.isNotEmpty ? assigneeName : assigneeId;

  List<String> get completionEvidence =>
      jsonLoadsList(completionEvidenceJson).map((e) => '$e').toList();

  @override
  List<Object?> get props => [
    assignId,
    goalId,
    assigneeId,
    assigneeName,
    role,
    assignedAt,
    assignedBy,
    assignedByName,
    dueDate,
    status,
    completedAt,
    completedBy,
    completedByName,
    completionNotes,
    completionEvidenceJson,
    deletedAt,
    createdAt,
    updatedAt,
  ];

  factory QcGoalAssignment.fromMap(Map<String, dynamic> m) => QcGoalAssignment(
    assignId: (m['assign_id'] as num?)?.toInt(),
    goalId: (m['goal_id'] as num?)?.toInt() ?? 0,
    assigneeId: '${m['assignee_id'] ?? ''}',
    assigneeName: '${m['assignee_name'] ?? ''}',
    role: QcGoalRole.normalize('${m['role'] ?? ''}'),
    assignedAt: '${m['assigned_at'] ?? ''}',
    assignedBy: '${m['assigned_by'] ?? ''}',
    assignedByName: '${m['assigned_by_name'] ?? ''}',
    dueDate: '${m['due_date'] ?? ''}',
    status: QcGoalAssignmentStatus.normalize('${m['status'] ?? ''}'),
    completedAt: '${m['completed_at'] ?? ''}',
    completedBy: '${m['completed_by'] ?? ''}',
    completedByName: '${m['completed_by_name'] ?? ''}',
    completionNotes: '${m['completion_notes'] ?? ''}',
    completionEvidenceJson: '${m['completion_evidence_json'] ?? ''}',
    deletedAt: '${m['deleted_at'] ?? ''}',
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && assignId != null) 'assign_id': assignId,
    'goal_id': goalId,
    'assignee_id': assigneeId,
    'assignee_name': assigneeName,
    'role': role,
    'assigned_at': assignedAt,
    'assigned_by': assignedBy,
    'assigned_by_name': assignedByName,
    'due_date': dueDate,
    'status': status,
    'completed_at': completedAt,
    'completed_by': completedBy,
    'completed_by_name': completedByName,
    'completion_notes': completionNotes,
    'completion_evidence_json': completionEvidenceJson,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  QcGoalAssignment copyWith({
    String? assigneeId,
    String? assigneeName,
    String? role,
    String? assignedAt,
    String? assignedBy,
    String? assignedByName,
    String? dueDate,
    String? status,
    String? completedAt,
    String? completedBy,
    String? completedByName,
    String? completionNotes,
    String? completionEvidenceJson,
    String? deletedAt,
    String? updatedAt,
  }) => QcGoalAssignment(
    assignId: assignId,
    goalId: goalId,
    assigneeId: assigneeId ?? this.assigneeId,
    assigneeName: assigneeName ?? this.assigneeName,
    role: role ?? this.role,
    assignedAt: assignedAt ?? this.assignedAt,
    assignedBy: assignedBy ?? this.assignedBy,
    assignedByName: assignedByName ?? this.assignedByName,
    dueDate: dueDate ?? this.dueDate,
    status: status ?? this.status,
    completedAt: completedAt ?? this.completedAt,
    completedBy: completedBy ?? this.completedBy,
    completedByName: completedByName ?? this.completedByName,
    completionNotes: completionNotes ?? this.completionNotes,
    completionEvidenceJson:
        completionEvidenceJson ?? this.completionEvidenceJson,
    deletedAt: deletedAt ?? this.deletedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// A discrete step under a goal, with its own finisher.
class QcGoalAction extends Equatable {
  final int? actionId;
  final int goalId;
  final int? assignId;
  final String actionText;
  final String status;
  final String priority;
  final String dueDate;
  final String doneAt;
  final String doneBy;
  final String doneByName;
  final String blockedReason;
  final String evidenceJson;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;
  final String createdBy;
  final String updatedBy;

  const QcGoalAction({
    this.actionId,
    required this.goalId,
    this.assignId,
    required this.actionText,
    this.status = QcGoalActionStatus.todo,
    this.priority = QcPriority.medium,
    this.dueDate = '',
    this.doneAt = '',
    this.doneBy = '',
    this.doneByName = '',
    this.blockedReason = '',
    this.evidenceJson = '',
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
    this.createdBy = '',
    this.updatedBy = '',
  });

  bool get isDone => QcGoalActionStatus.isDone(status);
  bool get isBlocked => status == QcGoalActionStatus.blocked;

  bool get isOverdue {
    if (isDone || status == QcGoalActionStatus.cancelled) return false;
    return qcIsPastDue(dueDate);
  }

  String get doneByLabel => doneByName.isNotEmpty ? doneByName : doneBy;

  List<String> get evidence =>
      jsonLoadsList(evidenceJson).map((e) => '$e').toList();

  @override
  List<Object?> get props => [
    actionId,
    goalId,
    assignId,
    actionText,
    status,
    priority,
    dueDate,
    doneAt,
    doneBy,
    doneByName,
    blockedReason,
    evidenceJson,
    deletedAt,
    createdAt,
    updatedAt,
    createdBy,
    updatedBy,
  ];

  factory QcGoalAction.fromMap(Map<String, dynamic> m) => QcGoalAction(
    actionId: (m['action_id'] as num?)?.toInt(),
    goalId: (m['goal_id'] as num?)?.toInt() ?? 0,
    assignId: (m['assign_id'] as num?)?.toInt(),
    actionText: '${m['action_text'] ?? ''}',
    status: QcGoalActionStatus.normalize('${m['status'] ?? ''}'),
    priority: QcPriority.normalize('${m['priority'] ?? ''}'),
    dueDate: '${m['due_date'] ?? ''}',
    doneAt: '${m['done_at'] ?? ''}',
    doneBy: '${m['done_by'] ?? ''}',
    doneByName: '${m['done_by_name'] ?? ''}',
    blockedReason: '${m['blocked_reason'] ?? ''}',
    evidenceJson: '${m['evidence_json'] ?? ''}',
    deletedAt: '${m['deleted_at'] ?? ''}',
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
    createdBy: '${m['created_by'] ?? ''}',
    updatedBy: '${m['updated_by'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && actionId != null) 'action_id': actionId,
    'goal_id': goalId,
    if (assignId != null) 'assign_id': assignId,
    'action_text': actionText,
    'status': status,
    'priority': priority,
    'due_date': dueDate,
    'done_at': doneAt,
    'done_by': doneBy,
    'done_by_name': doneByName,
    'blocked_reason': blockedReason,
    'evidence_json': evidenceJson,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy,
    'updated_by': updatedBy,
  };

  QcGoalAction copyWith({
    int? assignId,
    String? actionText,
    String? status,
    String? priority,
    String? dueDate,
    String? doneAt,
    String? doneBy,
    String? doneByName,
    String? blockedReason,
    String? evidenceJson,
    String? deletedAt,
    String? updatedAt,
    String? updatedBy,
  }) => QcGoalAction(
    actionId: actionId,
    goalId: goalId,
    assignId: assignId ?? this.assignId,
    actionText: actionText ?? this.actionText,
    status: status ?? this.status,
    priority: priority ?? this.priority,
    dueDate: dueDate ?? this.dueDate,
    doneAt: doneAt ?? this.doneAt,
    doneBy: doneBy ?? this.doneBy,
    doneByName: doneByName ?? this.doneByName,
    blockedReason: blockedReason ?? this.blockedReason,
    evidenceJson: evidenceJson ?? this.evidenceJson,
    deletedAt: deletedAt ?? this.deletedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    createdBy: createdBy,
    updatedBy: updatedBy ?? this.updatedBy,
  );
}

/// A measured KPI attached to a goal (target vs actual).
class QcGoalKpi extends Equatable {
  final int? kpiId;
  final int goalId;
  final String name;
  final double target;
  final double? actual;
  final String unit;
  final String measureDate;
  final String measuredBy;
  final String measuredByName;
  final String notes;
  final bool higherIsBetter;
  final String deletedAt;
  final String createdAt;
  final String updatedAt;

  const QcGoalKpi({
    this.kpiId,
    required this.goalId,
    required this.name,
    required this.target,
    this.actual,
    this.unit = '',
    this.measureDate = '',
    this.measuredBy = '',
    this.measuredByName = '',
    this.notes = '',
    this.higherIsBetter = true,
    this.deletedAt = '',
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isMeasured => actual != null;

  /// Met means actual reached target in whichever direction is better. A target
  /// of zero is treated as "at or below zero", i.e. always met once measured.
  bool get isMet {
    final value = actual;
    if (value == null) return false;
    if (target == 0) {
      return higherIsBetter ? value >= 0 : value <= 0;
    }
    return higherIsBetter ? value >= target : value <= target;
  }

  /// Signed gap to target, for the "off by" column in the goal detail.
  double? get variance => actual == null ? null : actual! - target;

  String get measuredByLabel =>
      measuredByName.isNotEmpty ? measuredByName : measuredBy;

  @override
  List<Object?> get props => [
    kpiId,
    goalId,
    name,
    target,
    actual,
    unit,
    measureDate,
    measuredBy,
    measuredByName,
    notes,
    higherIsBetter,
    deletedAt,
    createdAt,
    updatedAt,
  ];

  factory QcGoalKpi.fromMap(Map<String, dynamic> m) => QcGoalKpi(
    kpiId: (m['kpi_id'] as num?)?.toInt(),
    goalId: (m['goal_id'] as num?)?.toInt() ?? 0,
    name: '${m['name'] ?? ''}',
    target: (m['target'] as num?)?.toDouble() ?? 0,
    actual: (m['actual'] as num?)?.toDouble(),
    unit: '${m['unit'] ?? ''}',
    measureDate: '${m['measure_date'] ?? ''}',
    measuredBy: '${m['measured_by'] ?? ''}',
    measuredByName: '${m['measured_by_name'] ?? ''}',
    notes: '${m['notes'] ?? ''}',
    higherIsBetter: (m['higher_is_better'] as num?)?.toInt() != 0,
    deletedAt: '${m['deleted_at'] ?? ''}',
    createdAt: '${m['created_at'] ?? ''}',
    updatedAt: '${m['updated_at'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && kpiId != null) 'kpi_id': kpiId,
    'goal_id': goalId,
    'name': name,
    'target': target,
    if (actual != null) 'actual': actual,
    'unit': unit,
    'measure_date': measureDate,
    'measured_by': measuredBy,
    'measured_by_name': measuredByName,
    'notes': notes,
    'higher_is_better': higherIsBetter ? 1 : 0,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  QcGoalKpi copyWith({
    String? name,
    double? target,
    double? actual,
    String? unit,
    String? measureDate,
    String? measuredBy,
    String? measuredByName,
    String? notes,
    bool? higherIsBetter,
    String? deletedAt,
    String? updatedAt,
  }) => QcGoalKpi(
    kpiId: kpiId,
    goalId: goalId,
    name: name ?? this.name,
    target: target ?? this.target,
    actual: actual ?? this.actual,
    unit: unit ?? this.unit,
    measureDate: measureDate ?? this.measureDate,
    measuredBy: measuredBy ?? this.measuredBy,
    measuredByName: measuredByName ?? this.measuredByName,
    notes: notes ?? this.notes,
    higherIsBetter: higherIsBetter ?? this.higherIsBetter,
    deletedAt: deletedAt ?? this.deletedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

/// A pointer from a goal to the record that evidences it.
///
/// `refId` is TEXT because the targets are heterogeneous: a `sop_id` /
/// `finding_id` / `capa_id` are all integers but an audit row may be addressed
/// by hash instead, and one column keeps the link table honest about not
/// pretending to know the target's type.
class QcGoalLink extends Equatable {
  final int? linkId;
  final int goalId;
  final String linkType;
  final String refId;
  final String refTable;
  final String notes;
  final String deletedAt;
  final String createdAt;
  final String createdBy;

  const QcGoalLink({
    this.linkId,
    required this.goalId,
    required this.linkType,
    required this.refId,
    this.refTable = '',
    this.notes = '',
    this.deletedAt = '',
    required this.createdAt,
    this.createdBy = '',
  });

  /// Resolved target table, so the drilldown does not depend on the caller
  /// remembering the mapping.
  String get targetTable =>
      refTable.isNotEmpty ? refTable : QcGoalLinkType.refTable(linkType);

  int? get refIdAsInt => int.tryParse(refId);

  @override
  List<Object?> get props => [
    linkId,
    goalId,
    linkType,
    refId,
    refTable,
    notes,
    deletedAt,
    createdAt,
    createdBy,
  ];

  factory QcGoalLink.fromMap(Map<String, dynamic> m) => QcGoalLink(
    linkId: (m['link_id'] as num?)?.toInt(),
    goalId: (m['goal_id'] as num?)?.toInt() ?? 0,
    linkType: QcGoalLinkType.normalize('${m['link_type'] ?? ''}'),
    refId: '${m['ref_id'] ?? ''}',
    refTable: '${m['ref_table'] ?? ''}',
    notes: '${m['notes'] ?? ''}',
    deletedAt: '${m['deleted_at'] ?? ''}',
    createdAt: '${m['created_at'] ?? ''}',
    createdBy: '${m['created_by'] ?? ''}',
  );

  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && linkId != null) 'link_id': linkId,
    'goal_id': goalId,
    'link_type': linkType,
    'ref_id': refId,
    'ref_table': refTable.isEmpty
        ? QcGoalLinkType.refTable(linkType)
        : refTable,
    'notes': notes,
    if (deletedAt.isNotEmpty) 'deleted_at': deletedAt,
    'created_at': createdAt,
    'created_by': createdBy,
  };
}
