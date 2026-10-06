import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/qc_manager/domain/qc_audit.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_goal.dart';

void main() {
  const now = '2026-01-06T09:30:00Z';

  QcGoal completedGoal({
    String status = QcGoalStatus.completed,
    String finisherId = 'u1',
    String finisherName = 'Hana',
    String completedAt = now,
    String evidence = '',
    String priority = QcPriority.medium,
  }) => QcGoal(
    code: 'G-1',
    title: 'Reduce defects',
    goalType: QcGoalType.kpi,
    priority: priority,
    startDate: '2026-01-01',
    status: status,
    completedBy: finisherId,
    completedByName: finisherName,
    completedAt: completedAt,
    completionEvidenceJson: evidence,
    createdAt: now,
    updatedAt: now,
  );

  group('goal completion rules', () {
    test('accepts a completed goal with a named finisher and date', () {
      expect(completedGoal().completionBlocker, isEmpty);
    });

    test('requires both finisher identity fields and completion time', () {
      expect(completedGoal(finisherId: '').completionBlocker, contains('ID'));
      expect(
        completedGoal(finisherName: '').completionBlocker,
        contains('name'),
      );
      expect(completedGoal(completedAt: '').completionBlocker, contains('date'));
    });

    test('requires evidence for critical goals', () {
      expect(
        completedGoal(priority: QcPriority.critical).completionBlocker,
        contains('Evidence'),
      );
      expect(
        completedGoal(
          priority: QcPriority.critical,
          evidence: '["inspection-photo.png"]',
        ).completionBlocker,
        isEmpty,
      );
    });

    test('rejects cancelled goals even when completion fields are populated', () {
      expect(
        completedGoal(status: QcGoalStatus.cancelled).completionBlocker,
        contains('open state'),
      );
    });
  });

  group('bundle completion rules', () {
    test('goals without assignments or actions can be completed', () {
      final bundle = QcGoalBundle(goal: completedGoal());
      expect(bundle.canComplete, isTrue);
    });

    test('open assignments and actions block completion', () {
      final bundle = QcGoalBundle(
        goal: completedGoal(),
        assignments: [
          QcGoalAssignment(
            goalId: 1,
            assigneeId: 'u2',
            assignedAt: now,
            createdAt: now,
            updatedAt: now,
          ),
        ],
        actions: [
          QcGoalAction(
            goalId: 1,
            actionText: 'Verify the process',
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      expect(bundle.completionBlocker, contains('assignment(s)'));
    });

    test('cancelled assignments and actions do not block completion', () {
      final bundle = QcGoalBundle(
        goal: completedGoal(),
        assignments: [
          QcGoalAssignment(
            goalId: 1,
            assigneeId: 'u2',
            status: QcGoalAssignmentStatus.cancelled,
            assignedAt: now,
            createdAt: now,
            updatedAt: now,
          ),
        ],
        actions: [
          QcGoalAction(
            goalId: 1,
            actionText: 'Verify the process',
            status: QcGoalActionStatus.cancelled,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      expect(bundle.canComplete, isTrue);
    });
  });

  group('KPI direction', () {
    QcGoalKpi kpi({
      required double target,
      required double actual,
      required bool higherIsBetter,
    }) => QcGoalKpi(
      goalId: 1,
      name: 'Defect rate',
      target: target,
      actual: actual,
      higherIsBetter: higherIsBetter,
      createdAt: now,
      updatedAt: now,
    );

    test('uses the configured direction to decide whether a target is met', () {
      expect(
        kpi(target: 90, actual: 95, higherIsBetter: true).isMet,
        isTrue,
      );
      expect(
        kpi(target: 90, actual: 85, higherIsBetter: true).isMet,
        isFalse,
      );
      expect(
        kpi(target: 2, actual: 1, higherIsBetter: false).isMet,
        isTrue,
      );
      expect(
        kpi(target: 2, actual: 3, higherIsBetter: false).isMet,
        isFalse,
      );
    });
  });
}
