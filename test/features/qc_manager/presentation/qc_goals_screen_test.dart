import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/qc_manager/domain/qc_audit.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_goal.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_goal_detail_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_goals_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/qc_goal_detail_screen.dart';
import 'package:material_lab/features/qc_manager/presentation/qc_goals_screen.dart';

class _GoalsMock extends Mock implements QcGoalRepository {}

class _AuditMock extends Mock implements QcAuditRepository {}

const _now = '2026-02-01 08:00:00';

QcGoal _goal({
  int id = 1,
  String title = 'Cut scrap rate',
  String status = QcGoalStatus.active,
  String dueDate = '2099-01-01',
  String priority = QcPriority.medium,
  String dept = 'Production',
  String ownerName = 'Hassan',
}) => QcGoal(
  goalId: id,
  code: 'Q-2026-0$id',
  title: title,
  status: status,
  dept: dept,
  ownerName: ownerName,
  ownerId: 'u1',
  priority: priority,
  dueDate: dueDate,
  targetValue: 5,
  startDate: '2026-01-01',
  createdAt: _now,
  updatedAt: _now,
);

/// Stubs `listGoals` so the fake applies the *arguments it was actually
/// called with*, the way SQL would. The cubit fans a multi-status filter out
/// into one call per status, so a stub that ignored `status` would hand back
/// the same rows every time and make the merge look like it works.
void _stubGoals(_GoalsMock repo, {List<QcGoal> rows = const []}) {
  when(
    () => repo.listGoals(
      status: any(named: 'status'),
      dept: any(named: 'dept'),
      ownerId: any(named: 'ownerId'),
      overdueOnly: any(named: 'overdueOnly'),
      limit: any(named: 'limit'),
      offset: any(named: 'offset'),
    ),
  ).thenAnswer((invocation) async {
    final status = invocation.namedArguments[#status] as String;
    final dept = invocation.namedArguments[#dept] as String;
    final overdueOnly = invocation.namedArguments[#overdueOnly] as bool;
    final limit = invocation.namedArguments[#limit] as int;
    final offset = invocation.namedArguments[#offset] as int;
    var out = rows;
    if (status.isNotEmpty) out = out.where((g) => g.status == status).toList();
    if (dept.isNotEmpty) out = out.where((g) => g.dept == dept).toList();
    if (overdueOnly) out = out.where((g) => g.isOverdue).toList();
    final start = offset.clamp(0, out.length);
    return out.sublist(start, (start + limit).clamp(start, out.length));
  });
  when(
    () => repo.listAssignments(any()),
  ).thenAnswer((_) async => <QcGoalAssignment>[]);
  when(() => repo.getGoal(any())).thenAnswer((_) async => null);
  when(() => repo.getGoalBundle(any())).thenAnswer((_) async => null);
}

void _stubAudit(_AuditMock audit, {List<QcAudit> entries = const []}) {
  when(
    () => audit.list(
      entityType: any(named: 'entityType'),
      entityId: any(named: 'entityId'),
      action: any(named: 'action'),
      limit: any(named: 'limit'),
      offset: any(named: 'offset'),
    ),
  ).thenAnswer((_) async => entries);
}

Widget _host(Widget child, QcGoalsCubit cubit) => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => BlocProvider.value(
    value: cubit,
    child: MaterialApp(home: child),
  ),
);

Widget _hostDetail(Widget child, QcGoalDetailCubit cubit) => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => BlocProvider.value(
    value: cubit,
    child: MaterialApp(home: child),
  ),
);

/// Switches detail tab by its chip.
///
/// The six tabs live in a horizontally scrolling strip, so the last ones are
/// built but clipped at a phone width - `ensureVisible` first, or the tap lands
/// on whatever is painted over them.
Future<void> _tapTab(WidgetTester tester, String label) async {
  final chip = find.widgetWithText(ChoiceChip, label);
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => AppText.arabic = false);
  tearDownAll(() => AppText.arabic = true);

  group('QcGoalsScreen', () {
    late _GoalsMock repo;
    late QcGoalsCubit cubit;

    setUp(() {
      repo = _GoalsMock();
      cubit = QcGoalsCubit(repo: repo);
    });

    tearDown(() => cubit.close());

    testWidgets(
      'an empty register explains itself instead of showing a table',
      (tester) async {
        _stubGoals(repo);
        await cubit.load();
        await tester.pumpWidget(_host(const QcGoalsScreen(), cubit));
        await tester.pumpAndSettle();

        expect(find.text('No goals yet'), findsOneWidget);
        expect(find.text('Create the first quality objective'), findsOneWidget);
      },
    );

    testWidgets('each goal shows its title, status and owner', (tester) async {
      _stubGoals(
        repo,
        rows: [
          _goal(id: 1),
          _goal(id: 2, title: 'Train line 3'),
        ],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcGoalsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Cut scrap rate'), findsOneWidget);
      expect(find.text('Train line 3'), findsOneWidget);
      // The status pill, not a raw "Active" - the same word as a finding's
      // state must not be coloured as if it meant that.
      expect(find.text('Active'), findsWidgets);
      expect(find.text('Hassan'), findsWidgets);
    });

    testWidgets('the summary strip counts the rows in scope', (tester) async {
      _stubGoals(
        repo,
        rows: [
          _goal(id: 1),
          _goal(id: 2, status: QcGoalStatus.completed),
          _goal(id: 3, dueDate: '2020-01-01'),
        ],
      );
      await cubit.load();
      await tester.pumpWidget(_host(const QcGoalsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Total'), findsOneWidget);
      expect(find.text('Closed'), findsOneWidget);
      // Late is counted, and the late goal carries its own marker.
      expect(find.text('Late'), findsOneWidget);
      expect(find.text('Overdue'), findsWidgets);
    });

    testWidgets('the filter sheet lists every status as a chip', (
      tester,
    ) async {
      _stubGoals(repo, rows: [_goal()]);
      await cubit.load();
      await tester.pumpWidget(_host(const QcGoalsScreen(), cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Filters').last);
      await tester.pumpAndSettle();

      expect(find.text('Goal filters'), findsOneWidget);
      for (final status in QcGoalStatus.all) {
        expect(find.text(_englishStatus(status)), findsWidgets, reason: status);
      }
    });

    testWidgets('toggling a status chip in the sheet filters the list', (
      tester,
    ) async {
      _stubGoals(repo, rows: [_goal(id: 1, status: QcGoalStatus.draft)]);
      await cubit.load();
      await tester.pumpWidget(_host(const QcGoalsScreen(), cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Filters').last);
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilterChip, 'Active'));
      await tester.pumpAndSettle();
      expect(cubit.state.filters.statuses, contains(QcGoalStatus.active));
    });

    testWidgets('a screen with no filter offers to clear one', (tester) async {
      _stubGoals(repo);
      await cubit.load();
      await cubit.applyFilters(const QcGoalFilters(dept: 'Nowhere'));
      await tester.pumpWidget(_host(const QcGoalsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('No goals match these filters'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(cubit.state.filters.isEmpty, isTrue);
    });

    testWidgets('the last page says so rather than offering a dead button', (
      tester,
    ) async {
      _stubGoals(repo, rows: [_goal()]);
      await cubit.load();
      await tester.pumpWidget(_host(const QcGoalsScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('End of list'), findsOneWidget);
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('a short list offers to load the next page', (tester) async {
      _stubGoals(
        repo,
        rows: [
          for (var i = 0; i < qcGoalsPageSize; i++)
            _goal(id: i + 1, title: 'Goal $i'),
        ],
      );
      await cubit.load();
      expect(cubit.state.hasMore, isTrue);
      await tester.pumpWidget(_host(const QcGoalsScreen(), cubit));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Load more'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      expect(find.text('Load more'), findsOneWidget);
    });
  });

  group('QcGoalDetailScreen', () {
    late _GoalsMock repo;
    late _AuditMock audit;
    late QcGoalDetailCubit cubit;

    setUp(() {
      repo = _GoalsMock();
      audit = _AuditMock();
      cubit = QcGoalDetailCubit(repo: repo, audit: audit, goalId: 1);
    });

    tearDown(() => cubit.close());

    void stubBundle(QcGoalBundle bundle) {
      when(() => repo.getGoalBundle(any())).thenAnswer((_) async => bundle);
      when(
        () => repo.listAssignments(any()),
      ).thenAnswer((_) async => bundle.assignments);
      when(
        () => repo.listActions(any()),
      ).thenAnswer((_) async => bundle.actions);
      when(() => repo.listKpis(any())).thenAnswer((_) async => bundle.kpis);
    }

    testWidgets('the overview names the owner and the measures', (
      tester,
    ) async {
      stubBundle(QcGoalBundle(goal: _goal()));
      _stubAudit(audit);
      await cubit.load();
      await tester.pumpWidget(_hostDetail(const QcGoalDetailScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Overview'), findsOneWidget);
      expect(find.text('Hassan'), findsWidgets);
      expect(find.text('Complete goal'), findsOneWidget);
    });

    testWidgets('a completed goal shows who finished it, not a button', (
      tester,
    ) async {
      stubBundle(
        QcGoalBundle(
          goal: _goal(status: QcGoalStatus.completed).copyWith(
            completedBy: 'u1',
            completedByName: 'Hassan Ali',
            completedAt: '2026-02-01 10:00:00',
          ),
        ),
      );
      _stubAudit(audit);
      await cubit.load();
      await tester.pumpWidget(_hostDetail(const QcGoalDetailScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('Completed by'), findsOneWidget);
      expect(find.text('Hassan Ali'), findsOneWidget);
      expect(find.text('Complete goal'), findsNothing);
    });

    testWidgets('the assignment tab lists each person with their role', (
      tester,
    ) async {
      stubBundle(
        QcGoalBundle(
          goal: _goal(),
          assignments: [
            QcGoalAssignment(
              assignId: 1,
              goalId: 1,
              assigneeId: 'u2',
              assigneeName: 'Sara',
              role: QcGoalRole.lead,
              dueDate: '2026-06-01',
              assignedAt: _now,
              createdAt: _now,
              updatedAt: _now,
            ),
          ],
        ),
      );
      _stubAudit(audit);
      await cubit.load();
      await tester.pumpWidget(_hostDetail(const QcGoalDetailScreen(), cubit));
      await tester.pumpAndSettle();

      await _tapTab(tester, 'Assignments');

      expect(find.text('Sara'), findsOneWidget);
      expect(find.text('Lead - 2026-06-01'), findsOneWidget);
    });

    testWidgets('a blocked step shows its reason', (tester) async {
      stubBundle(
        QcGoalBundle(
          goal: _goal(),
          actions: [
            QcGoalAction(
              actionId: 1,
              goalId: 1,
              actionText: 'Retrain line 3',
              status: QcGoalActionStatus.blocked,
              blockedReason: 'Vendor has not shipped the jig',
              createdAt: _now,
              updatedAt: _now,
            ),
          ],
        ),
      );
      _stubAudit(audit);
      await cubit.load();
      await tester.pumpWidget(_hostDetail(const QcGoalDetailScreen(), cubit));
      await tester.pumpAndSettle();

      await _tapTab(tester, 'Steps');

      expect(find.text('Retrain line 3'), findsOneWidget);
      expect(find.text('Vendor has not shipped the jig'), findsOneWidget);
      expect(find.text('Blocked'), findsOneWidget);
    });

    testWidgets('the KPI tab shows the gap to target', (tester) async {
      stubBundle(
        QcGoalBundle(
          goal: _goal(),
          kpis: [
            QcGoalKpi(
              kpiId: 1,
              goalId: 1,
              name: 'Scrap rate',
              target: 5,
              actual: 8,
              unit: '%',
              createdAt: _now,
              updatedAt: _now,
            ),
          ],
        ),
      );
      _stubAudit(audit);
      await cubit.load();
      await tester.pumpWidget(_hostDetail(const QcGoalDetailScreen(), cubit));
      await tester.pumpAndSettle();

      await _tapTab(tester, 'KPIs');

      expect(find.text('Scrap rate'), findsOneWidget);
      expect(find.text('+3.0'), findsOneWidget);
    });

    testWidgets('the links tab names the table it points at', (tester) async {
      stubBundle(
        QcGoalBundle(
          goal: _goal(),
          links: [
            QcGoalLink(
              linkId: 1,
              goalId: 1,
              linkType: QcGoalLinkType.finding,
              refId: '42',
              createdAt: _now,
            ),
          ],
        ),
      );
      _stubAudit(audit);
      await cubit.load();
      await tester.pumpWidget(_hostDetail(const QcGoalDetailScreen(), cubit));
      await tester.pumpAndSettle();

      await _tapTab(tester, 'Links');

      expect(find.text('FINDING #42'), findsOneWidget);
      expect(find.text('qc_findings_nc'), findsOneWidget);
    });

    testWidgets('a goal with no history says so', (tester) async {
      stubBundle(QcGoalBundle(goal: _goal()));
      _stubAudit(audit);
      await cubit.load();
      await tester.pumpWidget(_hostDetail(const QcGoalDetailScreen(), cubit));
      await tester.pumpAndSettle();

      await _tapTab(tester, 'History');

      expect(cubit.state.tab, QcGoalTab.history);
      expect(find.text('No history yet'), findsOneWidget);
    });

    testWidgets('a goal that no longer exists does not render a blank page', (
      tester,
    ) async {
      when(() => repo.getGoalBundle(any())).thenAnswer((_) async => null);
      _stubAudit(audit);
      await cubit.load();
      await tester.pumpWidget(_hostDetail(const QcGoalDetailScreen(), cubit));
      await tester.pumpAndSettle();

      expect(find.text('This goal no longer exists'), findsOneWidget);
    });
  });
}

String _englishStatus(String status) => switch (status) {
  QcGoalStatus.draft => 'Draft',
  QcGoalStatus.active => 'Active',
  QcGoalStatus.onHold => 'On hold',
  QcGoalStatus.completed => 'Completed',
  QcGoalStatus.cancelled => 'Cancelled',
  QcGoalStatus.archived => 'Archived',
  _ => status,
};
