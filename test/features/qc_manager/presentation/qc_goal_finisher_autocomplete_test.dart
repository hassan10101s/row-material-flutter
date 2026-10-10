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
import 'package:material_lab/features/qc_manager/presentation/goals/qc_goal_detail_screen.dart';

class _GoalsMock extends Mock implements QcGoalRepository {}

class _AuditMock extends Mock implements QcAuditRepository {}

class _QcGoalFake extends Fake implements QcGoal {}

void main() {
  late _GoalsMock repository;
  late _AuditMock audit;
  late QcGoalDetailCubit cubit;

  setUpAll(() {
    registerFallbackValue(_QcGoalFake());
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
    cubit = QcGoalDetailCubit(repo: repository, audit: audit, goalId: 1);
  });

  tearDown(() async {
    await cubit.close();
    AppText.arabic = true;
  });

  Future<void> pumpDetail(WidgetTester tester) async {
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
  }

  testWidgets('selecting a suggested finisher binds the matching ID', (
    tester,
  ) async {
    when(() => repository.saveGoal(any())).thenAnswer((_) async {});
    await pumpDetail(tester);

    await tester.tap(find.text('Complete goal'));
    await tester.pumpAndSettle();
    final nameField = find.byType(TextField).first;
    await tester.tap(nameField);
    await tester.enterText(nameField, 'Hass');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hassan').last);
    await tester.pumpAndSettle();
    expect(find.text('u1'), findsOneWidget);

    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    final saved =
        verify(() => repository.saveGoal(captureAny())).captured.single
            as QcGoal;
    expect(saved.completedBy, 'u1');
    expect(saved.completedByName, 'Hassan');
    expect(saved.completedAt, isNotEmpty);
  });

  testWidgets('editing a typed finisher name clears any linked identity', (
    tester,
  ) async {
    await pumpDetail(tester);

    await tester.tap(find.text('Complete goal'));
    await tester.pumpAndSettle();
    final nameField = find.byType(TextField).first;
    await tester.tap(nameField);
    await tester.enterText(nameField, 'Hass');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hassan').last);
    await tester.pumpAndSettle();

    final editedNameField = find.byType(TextField).first;
    await tester.tap(editedNameField);
    await tester.enterText(editedNameField, 'Someone else');
    await tester.pumpAndSettle();
    expect(find.text('u1'), findsNothing);

    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    verifyNever(() => repository.saveGoal(any()));
    expect(find.text('Cannot complete without a finisher'), findsOneWidget);
  });
}
