/// Returns decision events in chronological order, adding the original
/// decision when it can be recovered from the inspection's current state or
/// the first later update.
///
/// New inspections store their first decision on the sample row; only later
/// status changes have a history row. For updated records, the earliest
/// change's `old_status` preserves the initial status, but not its old reason.
List<Map<String, dynamic>> inspectionDecisionHistory(
  Map<String, dynamic> inspection, [
  List<Map<String, dynamic>>? history,
]) {
  final rows =
      [
        for (final row in history ?? _historyFrom(inspection))
          Map<String, dynamic>.from(row),
      ]..sort((a, b) {
        final versionOrder = _versionOf(a).compareTo(_versionOf(b));
        if (versionOrder != 0) return versionOrder;
        return '${a['changed_at'] ?? ''}'.compareTo('${b['changed_at'] ?? ''}');
      });

  if (rows.any((row) => _versionOf(row) == 1)) return rows;

  String initialStatus;
  final initialReason = rows.isEmpty
      ? '${inspection['decision_reason'] ?? ''}'.trim()
      : '';
  if (rows.isEmpty) {
    final version = (inspection['decision_version'] as num?)?.toInt() ?? 1;
    if (version > 1) return rows;
    initialStatus = '${inspection['decision_status'] ?? ''}'.trim();
  } else {
    initialStatus = '${rows.first['old_status'] ?? ''}'.trim();
  }
  if (!_isDecision(initialStatus)) return rows;

  rows.insert(0, {
    'inspection_id': inspection['id'],
    'version': 1,
    'old_status': null,
    'new_status': initialStatus,
    'change_reason': initialReason,
    'follow_up_note': rows.isEmpty
        ? '${inspection['follow_up_note'] ?? ''}'.trim()
        : '',
    'rejected_quantity': rows.isEmpty
        ? '${inspection['rejected_quantity'] ?? ''}'.trim()
        : '',
    'changed_by_name':
        '${inspection['created_by_name'] ?? inspection['specialist_name'] ?? ''}',
    'changed_at':
        '${inspection['created_at'] ?? inspection['inspection_date'] ?? ''}',
  });
  return rows;
}

List<Map<String, dynamic>> _historyFrom(Map<String, dynamic> inspection) {
  final raw = inspection['status_history'];
  if (raw is! List) return const [];
  return [
    for (final row in raw)
      if (row is Map) Map<String, dynamic>.from(row),
  ];
}

int _versionOf(Map<String, dynamic> row) =>
    (row['version'] as num?)?.toInt() ?? int.tryParse('${row['version']}') ?? 0;

bool _isDecision(String status) => const {
  'APPROVED',
  'CONDITIONAL_APPROVAL',
  'PARTIAL_REJECTION',
  'FULL_REJECTION',
}.contains(status);
