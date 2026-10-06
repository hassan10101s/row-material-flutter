import 'package:equatable/equatable.dart';

import '../../../core/utils/app_format.dart';
import 'qc_enums.dart';
import 'qc_goal.dart';

/// An append-only, hash-chained QC audit entry (features/qc_manager/domain).
///
/// This models the whole `qc_audits` table, which is the single global trail
/// for every QC entity (plan V6_ENHANCED §21). It has **no update path by
/// construction**: the repository exposes `insert`, `listBy*` and
/// `verifyChain` and nothing else, so there is no code path that can rewrite a
/// row that has already been committed. `prevHash`/`hash` make a tamper
/// detectable even if someone reaches the database directly.
class QcAudit extends Equatable {
  final int? id;

  /// One of [QcAuditEntity]; stored as TEXT so a new entity kind does not need
  /// a schema change to be recordable.
  final String entityType;

  /// TEXT, not INTEGER: the audit trail spans both integer-keyed QC tables and
  /// hash-addressed SOP audit rows, and forcing one numeric type on both would
  /// lose information.
  final String entityId;
  final String action;
  final String byUserId;
  final String byUserName;
  final String at;

  /// Snapshots of the row before and after the change, as JSON. Kept as the
  /// exact string that was hashed, so a verifier re-hashes what was stored
  /// rather than a re-serialized approximation of it.
  final String beforeJson;
  final String afterJson;

  /// Anything else worth recording: reason, IP, device, before/after counts.
  final String metaJson;
  final String prevHash;
  final String hash;

  /// Always 1. Carried in the row so a copy exported for audit visibly claims
  /// to be immutable.
  final bool immutable;
  final String ipAddress;
  final String deviceId;

  const QcAudit({
    this.id,
    required this.entityType,
    required this.entityId,
    required this.action,
    this.byUserId = '',
    this.byUserName = '',
    required this.at,
    this.beforeJson = '',
    this.afterJson = '',
    this.metaJson = '',
    this.prevHash = '',
    this.hash = '',
    this.immutable = true,
    this.ipAddress = '',
    this.deviceId = '',
  });

  bool get isGenesis => prevHash.isEmpty;

  Map<String, dynamic> get meta => _jsonMap(metaJson);
  Map<String, dynamic> get before => _jsonMap(beforeJson);
  Map<String, dynamic> get after => _jsonMap(afterJson);

  /// The exact column set that is hashed, in a fixed order.
  ///
  /// `id`, `hash` and `immutable` are excluded on purpose: `id` is only known
  /// after the insert, and the other two are the output of the hash rather than
  /// an input to it. This list is the contract between the writer and the
  /// verifier - a field may only be added here together with a decision to
  /// break the chain of already-written rows, never silently.
  static const List<String> hashedFields = [
    'entity_type',
    'entity_id',
    'action',
    'by_user_id',
    'by_user_name',
    'at',
    'before_json',
    'after_json',
    'meta_json',
    'prev_hash',
  ];

  /// The hash payload as an ordered map, ready for canonical serialization.
  Map<String, dynamic> hashPayload() => {
    'entity_type': entityType,
    'entity_id': entityId,
    'action': action,
    'by_user_id': byUserId,
    'by_user_name': byUserName,
    'at': at,
    'before_json': beforeJson,
    'after_json': afterJson,
    'meta_json': metaJson,
    'prev_hash': prevHash,
  };

  @override
  List<Object?> get props => [
    id,
    entityType,
    entityId,
    action,
    byUserId,
    byUserName,
    at,
    beforeJson,
    afterJson,
    metaJson,
    prevHash,
    hash,
    immutable,
    ipAddress,
    deviceId,
  ];

  factory QcAudit.fromMap(Map<String, dynamic> m) => QcAudit(
    id: (m['id'] as num?)?.toInt(),
    entityType: '${m['entity_type'] ?? ''}',
    entityId: '${m['entity_id'] ?? ''}',
    action: '${m['action'] ?? ''}',
    byUserId: '${m['by_user_id'] ?? ''}',
    byUserName: '${m['by_user_name'] ?? ''}',
    at: '${m['at'] ?? ''}',
    beforeJson: '${m['before_json'] ?? ''}',
    afterJson: '${m['after_json'] ?? ''}',
    metaJson: '${m['meta_json'] ?? ''}',
    prevHash: '${m['prev_hash'] ?? ''}',
    hash: '${m['hash'] ?? ''}',
    immutable: (m['immutable'] as num?)?.toInt() != 0,
    ipAddress: '${m['ip_address'] ?? ''}',
    deviceId: '${m['device_id'] ?? ''}',
  );

  /// Insert-only by design: there is no `copyWith`, because there is no
  /// legitimate edit to an audit row.
  Map<String, dynamic> toMap({bool withId = true}) => {
    if (withId && id != null) 'id': id,
    'entity_type': entityType,
    'entity_id': entityId,
    'action': action,
    'by_user_id': byUserId,
    'by_user_name': byUserName,
    'at': at,
    'before_json': beforeJson,
    'after_json': afterJson,
    'meta_json': metaJson,
    'prev_hash': prevHash,
    'hash': hash,
    'immutable': immutable ? 1 : 0,
    'ip_address': ipAddress,
    'device_id': deviceId,
  };
}

/// Outcome of walking the hash chain, returned by `QcAuditRepo.verifyChain`.
///
/// A boolean would say *that* the chain is broken; this says *where*, which is
/// what an auditor actually needs and what the high-audit tests assert on.
class QcChainVerification extends Equatable {
  /// True only when every row hashed correctly and every `prev_hash` matched
  /// its predecessor.
  final bool isValid;

  /// Number of rows examined.
  final int checked;

  /// 1-based position of the first row that failed, or 0 when the chain is
  /// intact. `checked + 1` means a row was missing from the sequence.
  final int brokenAt;

  /// Why it failed: `null` when intact.
  final String? reason;

  /// Hash of the last good row, i.e. the chain head. Null/empty when empty.
  final String headHash;

  const QcChainVerification({
    required this.isValid,
    required this.checked,
    this.brokenAt = 0,
    this.reason,
    this.headHash = '',
  });

  const QcChainVerification.ok({required this.checked, required this.headHash})
    : isValid = true,
      brokenAt = 0,
      reason = null;

  const QcChainVerification.broken({
    required this.checked,
    required this.brokenAt,
    required this.reason,
    this.headHash = '',
  }) : isValid = false;

  @override
  List<Object?> get props => [isValid, checked, brokenAt, reason, headHash];

  @override
  String toString() => isValid
      ? 'QcChainVerification.ok(checked: $checked)'
      : 'QcChainVerification.broken(at: $brokenAt, reason: $reason)';
}

/// A goal plus the child rows the detail screen renders, fetched in one go.
///
/// Bundling them avoids the N+1 that a screen issuing five list queries would
/// otherwise cause on every open, and guarantees the summary figures and the
/// rows they were derived from come from the same snapshot.
class QcGoalBundle extends Equatable {
  final QcGoal goal;
  final List<QcGoalAssignment> assignments;
  final List<QcGoalAction> actions;
  final List<QcGoalKpi> kpis;
  final List<QcGoalLink> links;

  const QcGoalBundle({
    required this.goal,
    this.assignments = const [],
    this.actions = const [],
    this.kpis = const [],
    this.links = const [],
  });

  int get totalAssignments => assignments.length;

  int get completedAssignments =>
      assignments.where((a) => a.isCompleted).length;

  int get overdueAssignments => assignments.where((a) => a.isOverdue).length;

  int get totalActions => actions.length;

  int get doneActions => actions.where((a) => a.isDone).length;

  int get blockedActions => actions.where((a) => a.isBlocked).length;

  int get overdueActions => actions.where((a) => a.isOverdue).length;

  int get measuredKpis => kpis.where((k) => k.isMeasured).length;

  int get metKpis => kpis.where((k) => k.isMet).length;

  /// Who finished the goal itself, or an empty string when it is still open.
  String get finishedBy =>
      goal.completedByName.isNotEmpty ? goal.completedByName : goal.completedBy;

  String get finishedAt => goal.completedAt;

  /// True once every assignee has signed off - the precondition the repository
  /// enforces before allowing the goal itself to be completed.
  bool get allAssignmentsComplete =>
      assignments.every(
        (a) => a.isCompleted || a.status == QcGoalAssignmentStatus.cancelled,
      );

  bool get allActionsDone =>
      actions.every(
        (a) => a.isDone || a.status == QcGoalActionStatus.cancelled,
      );

  /// Combined reason this goal cannot be closed yet, or an empty string when it
  /// can. Surfaced as a disabled-button hint rather than an error dialog.
  String get completionBlocker {
    if (goal.completionBlocker.isNotEmpty) return goal.completionBlocker;
    final openAssignments = assignments
        .where(
          (a) =>
              !a.isCompleted &&
              a.status != QcGoalAssignmentStatus.cancelled,
        )
        .length;
    if (openAssignments > 0) {
      return '$openAssignments assignment(s) still open';
    }
    final openActions = actions
        .where((a) => !a.isDone && a.status != QcGoalActionStatus.cancelled)
        .length;
    if (openActions > 0) {
      return '$openActions action(s) still open';
    }
    return '';
  }

  bool get canComplete => completionBlocker.isEmpty;

  /// Share of finished work, 0..1. Actions weigh more than assignments because
  /// they are the actual steps; with neither, progress falls back to the goal's
  /// own KPI progress.
  double? get progress {
    if (totalActions > 0) return doneActions / totalActions;
    if (totalAssignments > 0) return completedAssignments / totalAssignments;
    return goal.progress;
  }

  @override
  List<Object?> get props => [goal, assignments, actions, kpis, links];
}

Map<String, dynamic> _jsonMap(Object? value) {
  if (value == null) return const {};
  if (value is Map) return Map<String, dynamic>.from(value);
  return jsonLoads(value.toString());
}
