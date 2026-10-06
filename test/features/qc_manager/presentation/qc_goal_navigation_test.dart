import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/features/qc_manager/domain/qc_audit.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_goal.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_goal_detail_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/qc_goal_detail_screen.dart';

class _GoalsMock extends Mock implements QcGoalRepository {}

class _AuditMock extends Mock implements QcAuditRepository {}

void main() {
  final locator = GetIt.instance;
  late _GoalsMock repository;
  late _AuditMock audit;

  setUp(() async {
    await locator.reset();
    repository = _GoalsMock();
    audit = _AuditMock();
    when(() => repository.getGoalBundle(7)).thenAnswer(
      (_) async => QcGoalBundle(
        goal: QcGoal(
          goalId: 7,
          code: 'G-7',
          title: 'Reduce scrap',
          status: QcGoalStatus.active,
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
    locator.registerFactoryParam<QcGoalDetailCubit, int, void>(
      (goalId, _) =>
          QcGoalDetailCubit(repo: repository, audit: audit, goalId: goalId),
    );
  });

  tearDown(() async {
    await locator.reset();
  });

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, _) => MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => QcGoalDetailScreen.open(context, 7),
                  child: const Text('Open goal'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('mobile opens details as a route and returns to the list', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpHost(tester);

    await tester.tap(find.text('Open goal'));
    await tester.pumpAndSettle();

    expect(find.text('Reduce scrap'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open goal'), findsOneWidget);
  });

  testWidgets('desktop opens a dismissible floating detail dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpHost(tester);

    await tester.tap(find.text('Open goal'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Reduce scrap'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Open goal'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
  });
}
