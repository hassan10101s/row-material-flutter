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
import 'package:material_lab/features/qc_manager/presentation/qc_goal_detail_screen.dart';

class _GoalsMock extends Mock implements QcGoalRepository {}

class _AuditMock extends Mock implements QcAuditRepository {}

class _KpiFake extends Fake implements QcGoalKpi {}

void main() {
  late _GoalsMock repository;
  late _AuditMock audit;
  late QcGoalDetailCubit cubit;

  setUpAll(() {
    registerFallbackValue(_KpiFake());
  });

  setUp(() {
    AppText.arabic = false;
    repository = _GoalsMock();
    audit = _AuditMock();
    when(() => repository.getGoalBundle(1)).thenAnswer(
      (_) async => QcGoalBundle(
        goal: QcGoal(
          goalId: 1,
          code: 'G-1',
          title: 'Reduce defects',
          status: QcGoalStatus.active,
          ownerId: 'u1',
          ownerName: 'Hassan',
          startDate: '2026-01-01',
          createdAt: '2026-01-01',
          updatedAt: '2026-01-01',
        ),
      ),
    );
    when(
      () => audit.list(
        entityType: any(named: 'entityType'),
        entityId: any(named: 'entityId'),
        action: any(named: 'action'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((_) async => const <QcAudit>[]);
    when(() => repository.addKpi(any())).thenAnswer((_) async => 1);
    cubit = QcGoalDetailCubit(repo: repository, audit: audit, goalId: 1);
  });

  tearDown(() async {
    await cubit.close();
    AppText.arabic = true;
  });

  testWidgets('the KPI form saves and evaluates a lower-is-better measure', (
    tester,
  ) async {
    await cubit.load();
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, _) => BlocProvider.value(
          value: cubit,
          child: const MaterialApp(home: QcGoalDetailScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('KPIs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add KPI'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'Defect rate');
    await tester.enterText(find.byType(TextFormField).at(1), '2');
    await tester.enterText(find.byType(TextFormField).at(2), '1');

    final measuredByName = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == 'Name',
    );
    await tester.tap(measuredByName);
    await tester.enterText(measuredByName, 'Hass');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hassan').last);
    await tester.pumpAndSettle();

    final directionSwitch = find.byType(SwitchListTile);
    await tester.ensureVisible(directionSwitch);
    await tester.pumpAndSettle();
    await tester.tap(directionSwitch);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final saved =
        verify(() => repository.addKpi(captureAny())).captured.single
            as QcGoalKpi;
    expect(saved.higherIsBetter, isFalse);
    expect(saved.target, 2);
    expect(saved.actual, 1);
    expect(saved.isMet, isTrue);
  });
}
