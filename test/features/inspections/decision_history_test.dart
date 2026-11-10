import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/inspections/domain/inspection_decision_history.dart';

void main() {
  test('shows the initial decision and reason for a new inspection', () {
    final history = inspectionDecisionHistory({
      'id': 12,
      'decision_status': 'FULL_REJECTION',
      'decision_reason': 'Moisture above limit',
      'decision_version': 1,
      'created_by_name': 'QC reviewer',
      'created_at': '2026-11-09T10:00:00',
      'status_history': [],
    });

    expect(history, hasLength(1));
    expect(history.single['version'], 1);
    expect(history.single['old_status'], isNull);
    expect(history.single['new_status'], 'FULL_REJECTION');
    expect(history.single['change_reason'], 'Moisture above limit');
    expect(history.single['changed_by_name'], 'QC reviewer');
  });

  test('recovers the initial status without reusing the updated reason', () {
    final history = inspectionDecisionHistory({
      'id': 12,
      'decision_status': 'APPROVED',
      'decision_reason': 'Accepted after retest',
      'decision_version': 3,
      'status_history': [
        {
          'version': 3,
          'old_status': 'FULL_REJECTION',
          'new_status': 'APPROVED',
          'change_reason': 'Accepted after retest',
        },
        {
          'version': 2,
          'old_status': 'APPROVED',
          'new_status': 'FULL_REJECTION',
          'change_reason': 'Moisture above limit',
        },
      ],
    });

    expect(history.map((row) => row['version']), [1, 2, 3]);
    expect(history.first['new_status'], 'APPROVED');
    expect(history.first['change_reason'], '');
    expect(history[1]['change_reason'], 'Moisture above limit');
    expect(history.last['change_reason'], 'Accepted after retest');
  });

  test('does not infer an initial status if there is no evidence for it', () {
    final history = inspectionDecisionHistory({
      'decision_status': 'APPROVED',
      'decision_version': 3,
      'status_history': [],
    });

    expect(history, isEmpty);
  });
}
