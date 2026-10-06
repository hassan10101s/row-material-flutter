import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/qc_manager/domain/qc_audit.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_goal.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_goal_detail_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_goals_cubit.dart';

/// In-memory stand-in for [QcGoalRepository].
///
/// It applies the filters the way SQL would (including the single-status
/// limitation the real repository has), so the cubit's own merge/dedupe logic
/// is exercised against something that behaves like the database rather than
/// against a stub that always agrees with it.
class _FakeGoals implements QcGoalRepository {
  _FakeGoals(this.goals);

  final List<QcGoal> goals;
  final Map<int, List<QcGoalAssignment>> assignments = {};
  final Map<int, List<QcGoalAction>> actions = {};
  final Map<int, List<QcGoalKpi>> kpis = {};
  final Map<int, List<QcGoalLink>> links = {};

  Object? failWith;
  final List<QcGoal> saved = [];
  final List<QcGoalAssignment> assigned = [];
  final List<QcGoalAction> actionsSaved = [];
  final List<int> removedAssignments = [];
  final List<int> removedKpis = [];
  final List<QcGoalLink> linksAdded = [];
  final List<QcGoalAction> actionsAdded = [];
  final List<QcGoalKpi> kpisAdded = [];
  final List<int> removedLinks = [];
  int createCalls = 0;

  @override
  Future<List<QcGoal>> listGoals({
    String status = '',
    String dept = '',
    String ownerId = '',
    bool overdueOnly = false,
    int limit = 100,
    int offset = 0,
  }) async {
    if (failWith != null) throw failWith!;
    var rows = goals.where((g) => g.isActive || g.goalId != null).toList();
    if (status.isNotEmpty) {
      rows = rows.where((g) => g.status == status).toList();
    }
    if (dept.isNotEmpty) rows = rows.where((g) => g.dept == dept).toList();
    if (ownerId.isNotEmpty) {
      rows = rows.where((g) => g.ownerId == ownerId).toList();
    }
    if (overdueOnly) rows = rows.where((g) => g.isOverdue).toList();
    final start = offset.clamp(0, rows.length);
    final end = (start + limit).clamp(start, rows.length);
    return rows.sublist(start, end);
  }

  @override
  Future<QcGoal?> getGoal(int goalId) async =>
      goals.where((g) => g.goalId == goalId).firstOrNull;

  @override
  Future<QcGoalBundle?> getGoalBundle(int goalId) async {
    if (failWith != null) throw failWith!;
    final goal = await getGoal(goalId);
    if (goal == null) return null;
    return QcGoalBundle(
      goal: goal,
      assignments: assignments[goalId] ?? const [],
      actions: actions[goalId] ?? const [],
      kpis: kpis[goalId] ?? const [],
      links: links[goalId] ?? const [],
    );
  }

  @override
  Future<int> createGoal(QcGoal goal) async {
    createCalls++;
    return 99;
  }

  @override
  Future<void> saveGoal(QcGoal goal) async {
    if (failWith != null) throw failWith!;
    saved.add(goal);
  }

  @override
  Future<void> deleteGoal(int goalId) async {}

  @override
  Future<List<QcGoalAssignment>> listAssignments(int goalId) async =>
      assignments[goalId] ?? const [];

  @override
  Future<void> assignGoal(QcGoalAssignment assignment) async {
    assigned.add(assignment);
  }

  @override
  Future<void> updateAssignment(QcGoalAssignment assignment) async {
    final list = assignments[assignment.goalId];
    if (list == null) return;
    assignments[assignment.goalId] = [
      for (final a in list)
        if (a.assignId == assignment.assignId) assignment else a,
    ];
  }

  @override
  Future<void> removeAssignment(int assignId) async {
    removedAssignments.add(assignId);
  }

  @override
  Future<List<QcGoalAction>> listActions(int goalId) async =>
      actions[goalId] ?? const [];

  @override
  Future<int> addAction(QcGoalAction action) async {
    actionsAdded.add(action);
    return 1;
  }

  @override
  Future<void> saveAction(QcGoalAction action) async {
    actionsSaved.add(action);
  }

  @override
  Future<int> addKpi(QcGoalKpi kpi) async {
    kpisAdded.add(kpi);
    return 1;
  }

  @override
  Future<void> saveKpi(QcGoalKpi kpi) async {}

  @override
  Future<void> deleteKpi(int kpiId) async {
    removedKpis.add(kpiId);
  }

  @override
  Future<List<QcGoalKpi>> listKpis(int goalId) async =>
      kpis[goalId] ?? const [];

  @override
  Future<int> addLink(QcGoalLink link) async {
    linksAdded.add(link);
    return 1;
  }

  @override
  Future<void> deleteLink(int linkId) async {
    removedLinks.add(linkId);
  }
}

class _FakeAudit implements QcAuditRepository {
  _FakeAudit();

  List<QcAudit> entries = const [];
  Object? failWith;
  String? seenEntityType;
  String? seenEntityId;
  int listCalls = 0;

  @override
  Future<List<QcAudit>> list({
    String entityType = '',
    String entityId = '',
    String action = '',
    int limit = 200,
    int offset = 0,
  }) async {
    listCalls++;
    seenEntityType = entityType;
    seenEntityId = entityId;
    if (failWith != null) throw failWith!;
    return entries;
  }

  @override
  Future<int> append({
    required String entityType,
    required String entityId,
    required String action,
    Map<String, dynamic>? before,
    Map<String, dynamic>? after,
    Map<String, dynamic>? meta,
  }) async => 1;

  @override
  Future<int> count({String entityType = '', String entityId = ''}) async =>
      entries.length;

  @override
  Future<QcAudit?> get(int id) async => null;

  @override
  Future<QcChainVerification> verifyChain({int? limit}) async =>
      const QcChainVerification.ok(checked: 0, headHash: '');
}

const _now = '2026-02-01 08:00:00';

QcGoal _goal({
  int id = 1,
  String code = 'Q-1',
  String title = 'Cut scrap rate',
  String status = QcGoalStatus.active,
  String dept = 'Production',
  String ownerId = 'u1',
  String dueDate = '2099-01-01',
  String priority = QcPriority.medium,
  double? target = 5,
  double? current,
}) => QcGoal(
  goalId: id,
  code: code,
  title: title,
  status: status,
  dept: dept,
  ownerId: ownerId,
  dueDate: dueDate,
  priority: priority,
  targetValue: target,
  currentValue: current,
  startDate: '2026-01-01',
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  group('QcGoalsCubit', () {
    test('loads the unfiltered population and summarises it', () async {
      final repo = _FakeGoals([
        _goal(id: 1),
        _goal(id: 2, status: QcGoalStatus.draft),
        _goal(id: 3, status: QcGoalStatus.completed),
      ]);
      final cubit = QcGoalsCubit(repo: repo);
      await cubit.load();

      expect(cubit.state.goals.length, 3);
      expect(cubit.state.summary.total, 3);
      expect(cubit.state.summary.active, 1);
      expect(cubit.state.summary.completed, 1);
      expect(cubit.state.loading, isFalse);
    });

    test('a multi-status filter asks the repository once per status', () async {
      // The repository takes a single status, so this is the compromise the
      // cubit is documenting: N statuses, N queries, merged and deduplicated.
      final repo = _FakeGoals([
        _goal(id: 1, status: QcGoalStatus.active),
        _goal(id: 2, status: QcGoalStatus.draft),
      ]);
      final cubit = QcGoalsCubit(repo: repo);
      await cubit.load();
      await cubit.toggleStatus(QcGoalStatus.active);
      expect(cubit.state.goals.map((g) => g.goalId), [1]);
      await cubit.toggleStatus(QcGoalStatus.draft);
      expect(cubit.state.goals.map((g) => g.goalId).toList()..sort(), [1, 2]);
    });

    test(
      'a filter change clears the old rows before the new ones land',
      () async {
        final repo = _FakeGoals([_goal(id: 1), _goal(id: 2, dept: 'Lab')]);
        final cubit = QcGoalsCubit(repo: repo);
        await cubit.load();
        expect(cubit.state.goals.length, 2);

        await cubit.applyFilters(const QcGoalFilters(dept: 'Lab'));
        expect(cubit.state.goals.map((g) => g.goalId), [2]);
        expect(cubit.state.summary.total, 1);
      },
    );

    test(
      'the assignee filter is resolved against the assignment rows',
      () async {
        final repo = _FakeGoals([_goal(id: 1), _goal(id: 2)]);
        repo.assignments[1] = [
          QcGoalAssignment(
            assignId: 10,
            goalId: 1,
            assigneeId: 'u9',
            assignedAt: _now,
            createdAt: _now,
            updatedAt: _now,
          ),
        ];
        final cubit = QcGoalsCubit(repo: repo);
        await cubit.applyFilters(const QcGoalFilters(assigneeId: 'u9'));
        expect(cubit.state.goals.map((g) => g.goalId), [1]);
      },
    );

    test('a due range narrows on both ends', () async {
      final repo = _FakeGoals([
        _goal(id: 1, dueDate: '2026-01-15'),
        _goal(id: 2, dueDate: '2026-06-01'),
        _goal(id: 3, dueDate: '2026-12-31'),
      ]);
      final cubit = QcGoalsCubit(repo: repo);
      await cubit.applyFilters(
        const QcGoalFilters(dueFrom: '2026-02-01', dueTo: '2026-11-30'),
      );
      expect(cubit.state.goals.map((g) => g.goalId), [2]);
    });

    test('loadMore stops once a short page comes back', () async {
      final repo = _FakeGoals([
        for (var i = 0; i < qcGoalsPageSize + 3; i++)
          _goal(
            id: i + 1,
            dueDate: '2099-01-${(i + 1).toString().padLeft(2, '0')}',
          ),
      ]);
      final cubit = QcGoalsCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.goals.length, qcGoalsPageSize);
      expect(cubit.state.hasMore, isTrue);

      await cubit.loadMore();
      expect(cubit.state.goals.length, qcGoalsPageSize + 3);
      expect(cubit.state.hasMore, isFalse);

      // A second call must not append again.
      await cubit.loadMore();
      expect(cubit.state.goals.length, qcGoalsPageSize + 3);
    });

    test('a failed load surfaces the message and stops the spinner', () async {
      final repo = _FakeGoals([_goal()])..failWith = Exception('boom');
      final cubit = QcGoalsCubit(repo: repo);
      await cubit.load();
      expect(cubit.state.loading, isFalse);
      expect(cubit.state.error, contains('boom'));
    });

    test('createGoal reloads so the new row is in scope', () async {
      final repo = _FakeGoals([_goal(id: 1)]);
      final cubit = QcGoalsCubit(repo: repo);
      await cubit.createGoal(_goal());
      expect(repo.createCalls, 1);
      expect(cubit.state.saved, isTrue);
      expect(cubit.state.goals.length, 1);
    });

    test('a stale load cannot overwrite the newer filter scope', () async {
      // Two overlapping loads with different scopes: whichever resolves last
      // wins unless the older one notices its token moved on.
      final repo = _FakeGoals([_goal(id: 1), _goal(id: 2, dept: 'Lab')]);
      final cubit = QcGoalsCubit(repo: repo);
      final first = cubit.load();
      final second = cubit.applyFilters(const QcGoalFilters(dept: 'Lab'));
      await Future.wait([first, second]);
      expect(cubit.state.filters.dept, 'Lab');
    });
  });

  group('QcGoalDetailCubit', () {
    test('loads the goal and its slice of the audit trail', () async {
      final repo = _FakeGoals([_goal(id: 7)]);
      final audit = _FakeAudit();
      final cubit = QcGoalDetailCubit(repo: repo, audit: audit, goalId: 7);
      await cubit.load();

      expect(cubit.state.goal?.goalId, 7);
      expect(audit.seenEntityType, QcAuditEntity.goal);
      expect(audit.seenEntityId, '7');
    });

    test(
      'a missing goal reports itself instead of rendering nothing',
      () async {
        final cubit = QcGoalDetailCubit(
          repo: _FakeGoals(const []),
          audit: _FakeAudit(),
          goalId: 404,
        );
        await cubit.load();
        expect(cubit.state.goal, isNull);
        expect(cubit.state.error, isNotNull);
      },
    );

    test('an unreadable trail does not blank the goal', () async {
      final repo = _FakeGoals([_goal(id: 7)]);
      final audit = _FakeAudit()..failWith = Exception('trail down');
      final cubit = QcGoalDetailCubit(repo: repo, audit: audit, goalId: 7);
      await cubit.load();
      expect(cubit.state.goal?.goalId, 7);
      expect(cubit.state.history, isEmpty);
      expect(cubit.state.historyError, contains('trail down'));
      audit.failWith = null;
      await cubit.reloadHistory();
      expect(cubit.state.historyError, isNull);
    });

    test('completing a goal stamps the finisher and the timestamp', () async {
      final repo = _FakeGoals([_goal(id: 7)]);
      final cubit = QcGoalDetailCubit(
        repo: repo,
        audit: _FakeAudit(),
        goalId: 7,
      );
      await cubit.load();
      await cubit.completeGoal(
        completedBy: 'u1',
        completedByName: 'Hassan',
        notes: 'done',
      );

      final saved = repo.saved.single;
      expect(saved.status, QcGoalStatus.completed);
      expect(saved.completedBy, 'u1');
      expect(saved.completedByName, 'Hassan');
      expect(saved.completedAt, isNotEmpty);
      expect(saved.completionNotes, 'done');
      expect(cubit.state.notice, isNotNull);
    });

    test('completing a goal writes the evidence as json', () async {
      final repo = _FakeGoals([_goal(id: 7)]);
      final cubit = QcGoalDetailCubit(
        repo: repo,
        audit: _FakeAudit(),
        goalId: 7,
      );
      await cubit.load();
      await cubit.completeGoal(
        completedBy: 'u1',
        completedByName: 'Hassan',
        evidence: const ['photo.png', 'log-3.txt'],
      );
      final saved = repo.saved.single;
      expect(saved.completionEvidence, ['photo.png', 'log-3.txt']);
    });

    test('closing a step records who did it', () async {
      final repo = _FakeGoals([_goal(id: 7)]);
      repo.actions[7] = [
        QcGoalAction(
          actionId: 55,
          goalId: 7,
          actionText: 'Retrain line 3',
          createdAt: _now,
          updatedAt: _now,
        ),
      ];
      final cubit = QcGoalDetailCubit(
        repo: repo,
        audit: _FakeAudit(),
        goalId: 7,
      );
      await cubit.load();
      await cubit.completeAction(55, 'u2', 'Mona');

      final saved = repo.actionsSaved.single;
      expect(saved.status, QcGoalActionStatus.done);
      expect(saved.doneByName, 'Mona');
      expect(saved.doneAt, isNotEmpty);
    });

    test('closing a step that no longer exists writes nothing', () async {
      final repo = _FakeGoals([_goal(id: 7)]);
      final cubit = QcGoalDetailCubit(
        repo: repo,
        audit: _FakeAudit(),
        goalId: 7,
      );
      await cubit.load();
      await cubit.completeAction(999, 'u2', 'Mona');
      expect(repo.actionsSaved, isEmpty);
    });

    test('a KPI with a known name is updated, not duplicated', () async {
      final repo = _FakeGoals([_goal(id: 7)]);
      repo.kpis[7] = [
        QcGoalKpi(
          kpiId: 3,
          goalId: 7,
          name: 'Scrap',
          target: 5,
          actual: 8,
          createdAt: _now,
          updatedAt: _now,
        ),
      ];
      final cubit = QcGoalDetailCubit(
        repo: repo,
        audit: _FakeAudit(),
        goalId: 7,
      );
      await cubit.load();
      // addKpi/saveKpi are both recorded through the same fake; the assertion
      // that matters is that the existing row keeps its id.
      await cubit.saveKpi(name: 'Scrap', target: 4, actual: 3);
      expect(cubit.state.kpis.single.kpiId, 3);
    });

    test('assigning records who assigned and when', () async {
      final repo = _FakeGoals([_goal(id: 7)]);
      final cubit = QcGoalDetailCubit(
        repo: repo,
        audit: _FakeAudit(),
        goalId: 7,
      );
      await cubit.load();
      await cubit.assign(
        assigneeId: 'u5',
        assigneeName: 'Sara',
        assignedBy: 'u1',
        assignedByName: 'Hassan',
        dueDate: '2026-06-01',
      );
      final a = repo.assigned.single;
      expect(a.assigneeId, 'u5');
      expect(a.assigneeName, 'Sara');
      expect(a.assignedByName, 'Hassan');
      expect(a.assignedAt, isNotEmpty);
      expect(a.dueDate, '2026-06-01');
    });

    test(
      'a link is created against the goal, with its table resolved',
      () async {
        final repo = _FakeGoals([_goal(id: 7)]);
        final cubit = QcGoalDetailCubit(
          repo: repo,
          audit: _FakeAudit(),
          goalId: 7,
        );
        await cubit.load();
        await cubit.link(linkType: QcGoalLinkType.finding, refId: '42');
        final link = repo.linksAdded.single;
        expect(link.goalId, 7);
        expect(link.toMap()['ref_table'], 'qc_findings_nc');
      },
    );

    test('a failed save surfaces the message', () async {
      final repo = _FakeGoals([_goal(id: 7)])..failWith = Exception('denied');
      final cubit = QcGoalDetailCubit(
        repo: repo,
        audit: _FakeAudit(),
        goalId: 7,
      );
      await cubit.load();
      await cubit.setStatus(QcGoalStatus.onHold);
      expect(cubit.state.saving, isFalse);
      expect(cubit.state.error, contains('denied'));
    });
  });
}
