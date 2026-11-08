import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/members/domain/member_repository.dart';
import 'package:material_lab/features/members/presentation/members/members_screen.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/lab/presentation/analyses/analysis_editor.dart';
import 'package:material_lab/features/lab/presentation/analyses/desktop/analyses_tab.dart';
import 'package:material_lab/features/lab/presentation/cubit/analyses_cubit.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';

class _Gate extends Mock implements AuthGate {}

class _Members extends Mock implements MemberRepository {}

class _Config extends Mock implements LabConfigurationRepository {}

class _Stock extends Mock implements LabLocalRepository {}

class _Reference extends Mock implements ReferenceRepository {}

void main() {
  setUpAll(() => registerFallbackValue(Permission.usersUpdate));
  setUp(() => AppText.useLanguage('en'));
  tearDown(() async {
    FormFactor.debugSet(null);
    AppText.useLanguage('ar');
    await getIt.reset();
  });

  Future<void> pump(WidgetTester tester, Widget child, bool mobile) async {
    FormFactor.debugSet(mobile ? AppFormFactor.mobile : AppFormFactor.desktop);
    final size = mobile ? const Size(390, 844) : const Size(1280, 900);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: size,
        builder: (_, _) => MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop Cancel closes the analysis dialog above a nested navigator',
    (tester) async {
      final stock = _Stock(), reference = _Reference(), config = _Config();
      when(stock.listInventory).thenAnswer((_) async => []);
      when(stock.listUnitSymbols).thenAnswer((_) async => ['%']);
      when(reference.listParameters).thenAnswer((_) async => []);
      when(
        () => config.listAnalysesPaged(query: '', limit: 1, offset: 0),
      ).thenAnswer((_) async => []);
      when(() => config.countAnalyses(query: '')).thenAnswer((_) async => 0);
      getIt.registerSingleton<LabConfigurationRepository>(config);
      getIt.registerSingleton<LabLocalRepository>(stock);
      getIt.registerSingleton<ReferenceRepository>(reference);
      final cubit = AnalysesCubit(repo: config, pageSize: 1);
      addTearDown(cubit.close);
      await cubit.load();
      await pump(
        tester,
        Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              body: BlocProvider.value(
                value: cubit,
                child: const DesktopAnalysesTab(),
              ),
            ),
          ),
        ),
        false,
      );
      await tester.tap(find.text('Add analysis'));
      await tester.pumpAndSettle();
      expect(find.byType(AnalysisEditor), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AnalysisEditor), findsNothing);
      expect(find.byType(DesktopAnalysesTab), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'phone' : 'desktop'} role picker preserves selection and cancels without a write',
      (tester) async {
        final gate = _Gate(), members = _Members();
        when(() => gate.canWrite(any())).thenReturn(true);
        when(() => gate.online).thenReturn(true);
        when(() => gate.organizationId).thenReturn('org');
        when(() => gate.session).thenReturn(
          const AppSession(
            uid: 'owner',
            organizationId: 'org',
            memberId: 'owner',
            role: 'admin',
            status: 'active',
          ),
        );
        when(() => members.listMembers()).thenAnswer(
          (_) async => const [
            Member(
              id: 'tech',
              email: 'tech@example.com',
              displayName: 'Lab technician',
              role: 'lab',
              status: 'active',
            ),
          ],
        );
        getIt.registerSingleton<AuthGate>(gate);
        getIt.registerSingleton<MemberRepository>(members);
        await pump(tester, const MembersScreen(), mobile);
        clearInteractions(members);
        final change = find.byTooltip('Change role');
        await tester.ensureVisible(change);
        await tester.tap(change);
        await tester.pumpAndSettle();
        expect(find.text('Employee roles'), findsOneWidget);
        expect(find.byType(Dialog), mobile ? findsNothing : findsOneWidget);
        expect(
          tester
              .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
              .where((tile) => tile.value == true),
          hasLength(1),
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Employee roles'), findsNothing);
        verifyNever(
          () => members.changeRole(
            memberId: any(named: 'memberId'),
            role: any(named: 'role'),
            roles: any(named: 'roles'),
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${mobile ? 'phone' : 'desktop'} consumed chemical selection returns to the analysis editor',
      (tester) async {
        final stock = _Stock(), reference = _Reference();
        when(() => stock.listInventory()).thenAnswer(
          (_) async => [
            {'id': 1, 'name': 'HCl', 'unit': 'mL', 'category': 'volume'},
          ],
        );
        when(() => stock.listUnitSymbols()).thenAnswer((_) async => ['mL']);
        when(() => reference.listParameters()).thenAnswer((_) async => []);
        getIt.registerSingleton<LabConfigurationRepository>(_Config());
        getIt.registerSingleton<LabLocalRepository>(stock);
        getIt.registerSingleton<ReferenceRepository>(reference);
        await pump(
          tester,
          const SingleChildScrollView(child: AnalysisEditor()),
          mobile,
        );
        final add = find.text('Add consumed chemical');
        await tester.ensureVisible(add);
        await tester.tap(add);
        await tester.pumpAndSettle();
        expect(find.text('Pick consumed chemical'), findsOneWidget);
        expect(find.byType(Dialog), mobile ? findsNothing : findsOneWidget);
        await tester.tap(find.text('HCl (mL)'));
        await tester.pumpAndSettle();
        expect(find.text('Pick consumed chemical'), findsNothing);
        expect(find.textContaining('HCl'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
