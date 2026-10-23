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
import 'package:material_lab/features/qc_manager/domain/ncr_filters.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_kpis.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_report_repository.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/design_system/widgets/app_field.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_ncr_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/ncr/qc_ncr_create_screen.dart';

class _CapaMock extends Mock implements QcNcCapaRepository {}

class _InspectionsMock extends Mock implements QcInspectionRepository {}

class _ReportMock extends Mock implements QcNcReportRepository {}

class _GateMock extends Mock implements AuthGate {}

Widget _host(Widget child, QcNcrCubit cubit) => ScreenUtilInit(
  designSize: const Size(1280, 720),
  builder: (context, _) => BlocProvider.value(
    value: cubit,
    child: MaterialApp(home: child),
  ),
);

/// AppField keeps its label as a sibling of the input, so the field is
/// located as "the input under the [label]'s own widget".
TextFormField _fieldOf(WidgetTester tester, String label) {
  final tile = find.ancestor(
    of: find.text(label),
    matching: find.byType(AppField),
  );
  // One field per label; the last lookup is there to fail loudly with the
  // same message every finder-based test gives when the layout drifts.
  expect(tile, findsOneWidget, reason: "one '$label' field is expected");
  return tester.widget<TextFormField>(
    find.descendant(of: tile, matching: find.byType(TextFormField)),
  );
}

/// Schedules [label]'s text on its own controller immediately: widget-based
/// two-liner because the field may sit below the fold inside the window.
Future<void> _fill(WidgetTester tester, String label, String text) async {
  final tile = find.ancestor(
    of: find.text(label),
    matching: find.byType(AppField),
  );
  final field = find.descendant(of: tile, matching: find.byType(TextFormField));
  await tester.enterText(field, text);
}

/// Drives [QcNcrCreateScreen.open] from a button the way the dashboard does,
/// so window-vs-route is tested on the same call the production code makes.
Widget _hostWithTrigger(
  QcNcrCubit cubit, {
  List<({String id, String name})> assignees = const [],
}) => _host(
  Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () =>
              QcNcrCreateScreen.open(context, cubit, assignees: assignees),
          child: const Text('open create'),
        ),
      ),
    ),
  ),
  cubit,
);

void main() {
  setUpAll(() {
    registerFallbackValue(const NcrFilters());
    registerFallbackValue(Permission.qcWrite);
    registerFallbackValue(
      QcFindingNc(
        inspectionId: 0,
        severity: 'Minor',
        description: '',
        createdAt: '',
        updatedAt: '',
      ),
    );
  });

  // AppText default is Arabic; every assert names the English string.
  setUp(() => AppText.useLanguage('en'));

  setUp(() {
    final capa = _CapaMock();
    when(() => capa.listDefectCodes()).thenAnswer((_) async => []);
    when(() => capa.createFinding(any())).thenAnswer((_) async => 401);
    final inspections = _InspectionsMock();
    when(
      () => inspections.listInspections(
        templateId: any(named: 'templateId'),
        status: any(named: 'status'),
        refType: any(named: 'refType'),
        refId: any(named: 'refId'),
        lotNo: any(named: 'lotNo'),
        dept: any(named: 'dept'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((_) async => []);
    getIt.registerSingleton<QcNcCapaRepository>(capa);
    getIt.registerSingleton<QcInspectionRepository>(inspections);
    addTearDown(getIt.reset);
  });

  QcNcrCubit cubitWithReport(_ReportMock report) {
    when(() => report.kpis(any())).thenAnswer(
      (_) async => NcrKpis(total: 3, open: 2, overdue: 1, critical: 1),
    );
    when(
      () => report.list(
        any(),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
        orderBy: any(named: 'orderBy'),
        orderDir: any(named: 'orderDir'),
      ),
    ).thenAnswer((_) async => const []);
    when(() => report.count(any())).thenAnswer((_) async => 0);
    when(() => report.agingBuckets(any())).thenAnswer((_) async => const []);
    when(
      () => report.topDefects(any(), limit: any(named: 'limit')),
    ).thenAnswer((_) async => const []);
    when(
      () => report.repeatByRef(any(), limit: any(named: 'limit')),
    ).thenAnswer((_) async => const []);
    return QcNcrCubit(report);
  }

  group('desktop (window, no back stack)', () {
    setUp(() {
      FormFactor.debugSet(AppFormFactor.desktop);
      addTearDown(() => FormFactor.debugSet(AppFormFactor.desktop));
    });

    testWidgets('open() shows the form in a window, not a route', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      final report = _ReportMock();
      final cubit = cubitWithReport(report);
      addTearDown(cubit.close);
      await tester.pumpWidget(_hostWithTrigger(cubit));
      await tester.pumpAndSettle();

      expect(find.byType(Scaffold), findsOneWidget);
      await tester.tap(find.text('open create'));
      await tester.pumpAndSettle();

      // The form renders inside the dialog; the base screen's single
      // Scaffold remains the only one - no Navigator route was pushed.
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppWindow), findsOneWidget);
      expect(find.text('New non-conformance'), findsOneWidget);
      expect(find.text('Description'), findsOneWidget);

      // âœ• must close the window straight away - the route affordance does
      // not exist on desktop.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(AppWindow), findsNothing);
      // An empty close is not a save: the report must not refetch.
      verifyNever(() => report.kpis(any()));
    });

    testWidgets('Cancel dismisses without writing', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      final report = _ReportMock();
      final cubit = cubitWithReport(report);
      addTearDown(cubit.close);
      await tester.pumpWidget(_hostWithTrigger(cubit));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open create'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AppWindow), findsNothing);
      final capa = getIt<QcNcCapaRepository>() as _CapaMock;
      verifyNever(() => capa.createFinding(any()));
    });

    testWidgets('saving a standalone finding writes it and refetches', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      final report = _ReportMock();
      final cubit = cubitWithReport(report);
      // The one load the test itself performs; the window being open must
      // not add another until a save succeeds.
      await cubit.load();
      addTearDown(cubit.close);
      final gate = _GateMock();
      when(() => gate.canWrite(any())).thenReturn(true);
      when(() => gate.session).thenReturn(
        const AppSession(
          uid: 'u1',
          organizationId: 'org-1',
          status: MemberStatus.active,
        ),
      );
      getIt.registerSingleton<AuthGate>(gate);

      await tester.pumpWidget(_hostWithTrigger(cubit));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open create'));
      await tester.pumpAndSettle();
      // One load from the test itself, none from the window being open.
      verify(() => report.kpis(any())).called(1);
      // Forget the initial load so the next verify counts only what the
      // successful save triggered (mocktail drops already-verified calls).
      clearInteractions(report);

      // No inspection picker content, no defect codes: the form must still
      // be savable - a standalone Minor finding with the typed description.
      await _fill(tester, 'Description', 'weld undercut');
      await tester.ensureVisible(find.text('Create'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final capa = getIt<QcNcCapaRepository>() as _CapaMock;
      final captured =
          verify(() => capa.createFinding(captureAny())).captured.single
              as QcFindingNc;
      expect(captured.inspectionId, 0);
      expect(captured.description, 'weld undercut');
      expect(captured.severity, 'Minor');
      expect(captured.status, 'Open');
      expect(captured.createdBy, 'u1');

      // Pop(true) reaches open()'s continuation and the dashboard refetches.
      expect(find.byType(AppWindow), findsNothing);
      verify(() => report.kpis(any())).called(1);
    });

    testWidgets('an empty description is refused, nothing is written', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      final report = _ReportMock();
      final cubit = cubitWithReport(report);
      addTearDown(cubit.close);
      final gate = _GateMock();
      when(() => gate.canWrite(any())).thenReturn(true);
      when(() => gate.session).thenReturn(
        const AppSession(
          uid: 'u1',
          organizationId: 'org-1',
          status: MemberStatus.active,
        ),
      );
      getIt.registerSingleton<AuthGate>(gate);

      await tester.pumpWidget(_hostWithTrigger(cubit));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open create'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text('A description is required'), findsOneWidget);
      // The window stays open for correction.
      expect(find.byType(AppWindow), findsOneWidget);
      final capa = getIt<QcNcCapaRepository>() as _CapaMock;
      verifyNever(() => capa.createFinding(any()));
      verifyNever(() => report.kpis(any()));
    });
  });

  group('mobile (pushed route with Back)', () {
    setUp(() {
      FormFactor.debugSet(AppFormFactor.mobile);
      addTearDown(() => FormFactor.debugSet(AppFormFactor.mobile));
    });

    testWidgets('open() pushes the form as a route', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 820);
      addTearDown(tester.view.reset);

      final report = _ReportMock();
      final cubit = cubitWithReport(report);
      addTearDown(cubit.close);
      await tester.pumpWidget(_hostWithTrigger(cubit));
      await tester.pumpAndSettle();

      await tester.tap(find.text('open create'));
      await tester.pumpAndSettle();

      // Two Scaffolds when offstage pages count: the caller's and the pushed
      // route's - the exact thing the desktop test asserts the absence of.
      expect(find.byType(Scaffold, skipOffstage: false), findsNWidgets(2));
      expect(find.byType(AppWindow), findsNothing);
      expect(find.text('New non-conformance'), findsOneWidget);
      // The window's dismiss button must not exist on phones; Back is the
      // system affordance.
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.text('Description'), findsOneWidget);
    });

    testWidgets('Cancel pops back to the caller', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(420, 820);
      addTearDown(tester.view.reset);

      final report = _ReportMock();
      final cubit = cubitWithReport(report);
      addTearDown(cubit.close);
      await tester.pumpWidget(_hostWithTrigger(cubit));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open create'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsOneWidget);
      final capa = getIt<QcNcCapaRepository>() as _CapaMock;
      verifyNever(() => capa.createFinding(any()));
    });
  });

  group('the assignee roster flows into the save', () {
    setUp(() {
      FormFactor.debugSet(AppFormFactor.desktop);
      addTearDown(() => FormFactor.debugSet(AppFormFactor.desktop));
    });

    testWidgets('choosing an assignee schedules the finding to them', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      final report = _ReportMock();
      final cubit = cubitWithReport(report);
      addTearDown(cubit.close);
      final gate = _GateMock();
      when(() => gate.canWrite(any())).thenReturn(true);
      when(() => gate.session).thenReturn(
        const AppSession(
          uid: 'u1',
          organizationId: 'org-1',
          status: MemberStatus.active,
        ),
      );
      getIt.registerSingleton<AuthGate>(gate);

      await tester.pumpWidget(
        _hostWithTrigger(cubit, assignees: const [(id: 'm-9', name: 'Ali Qa')]),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open create'));
      await tester.pumpAndSettle();

      await _fill(tester, 'Description', 'scratched surface');
      // The label is a sibling of the input, so tapping it opens nothing:
      // the assignee dropdown itself is what has to be tapped, identified
      // by its reified record type.
      await tester.ensureVisible(
        find.byType(DropdownButtonFormField<({String id, String name})>),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byType(DropdownButtonFormField<({String id, String name})>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ali Qa').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Create'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      final capa = getIt<QcNcCapaRepository>() as _CapaMock;
      final captured =
          verify(() => capa.createFinding(captureAny())).captured.single
              as QcFindingNc;
      expect(captured.status, 'Assigned');
      expect(captured.assignedTo, 'm-9');
      expect(captured.assignedToName, 'Ali Qa');
      expect(captured.assignedAt, isNotEmpty);
    });
  });

  group('edit mode (prefilled form writes through saveFinding)', () {
    setUp(() {
      FormFactor.debugSet(AppFormFactor.desktop);
      addTearDown(() => FormFactor.debugSet(AppFormFactor.desktop));
    });

    QcFindingNc baseFinding() => QcFindingNc(
      findingId: 7,
      inspectionId: 3,
      code: 'NC-01',
      type: NcType.nonConformance,
      severity: NcSeverity.major,
      category: 'Packaging',
      description: 'seal broken',
      status: NcStatus.assigned,
      dueDate: '2026-02-01',
      assignedTo: 'm-9',
      assignedToName: 'Ali Qa',
      assignedAt: '2026-01-02 10:00:00',
      proposedAction: 'quarantine the case',
      qtyAffected: 12,
      qtyUnit: 'kg',
      disposition: NcDisposition.scrap,
      rootCause: 'human factor',
      actionPlan: 'retrain',
      capaId: 5,
      createdAt: '2026-01-01 09:00:00',
      updatedAt: '2026-01-01 09:00:00',
      createdBy: 'u0',
      updatedBy: 'u0',
    );

    Widget hostWithEdit(QcNcrCubit cubit) => _host(
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => QcNcrCreateScreen.open(
                context,
                cubit,
                finding: baseFinding(),
                assignees: const [(id: 'm-9', name: 'Ali Qa')],
              ),
              child: const Text('open edit'),
            ),
          ),
        ),
      ),
      cubit,
    );

    testWidgets('prefills every editable field and saves in place', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      final report = _ReportMock();
      final cubit = cubitWithReport(report);
      addTearDown(cubit.close);
      final capa = getIt<QcNcCapaRepository>() as _CapaMock;
      when(() => capa.saveFinding(any())).thenAnswer((_) async {});
      final gate = _GateMock();
      when(() => gate.canWrite(any())).thenReturn(true);
      when(() => gate.session).thenReturn(
        const AppSession(
          uid: 'u1',
          organizationId: 'org-1',
          status: MemberStatus.active,
        ),
      );
      getIt.registerSingleton<AuthGate>(gate);

      await tester.pumpWidget(hostWithEdit(cubit));
      await tester.pumpAndSettle();
      await tester.tap(find.text('open edit'));
      await tester.pumpAndSettle();

      expect(find.text('Edit non-conformance'), findsOneWidget);
      final description = _fieldOf(tester, 'Description');
      expect(description.controller?.text, 'seal broken');
      expect(_fieldOf(tester, 'Category (optional)').controller?.text, 'Packaging');
      expect(find.text('2026-02-01'), findsOneWidget);

      await _fill(tester, 'Description', 'seal crushed');
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final captured =
          verify(() => capa.saveFinding(captureAny())).captured.single
              as QcFindingNc;
      expect(captured.findingId, 7);
      // The stored inspection/text facts the form never touched survive.
      expect(captured.inspectionId, 3);
      expect(captured.code, 'NC-01');
      expect(captured.description, 'seal crushed');
      expect(captured.status, 'Assigned');
      expect(captured.assignedTo, 'm-9');
      expect(captured.assignedAt, '2026-01-02 10:00:00');
      expect(captured.createdAt, '2026-01-01 09:00:00');
      expect(captured.capaId, 5);
      expect(captured.updatedAt, isNotEmpty);
      expect(find.byType(AppWindow), findsNothing);
      verifyNever(() => capa.createFinding(any()));
    });

    testWidgets('reassigning an open finding moves it to Assigned', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      final report = _ReportMock();
      final cubit = cubitWithReport(report);
      addTearDown(cubit.close);
      final capa = getIt<QcNcCapaRepository>() as _CapaMock;
      when(() => capa.saveFinding(any())).thenAnswer((_) async {});
      final gate = _GateMock();
      when(() => gate.canWrite(any())).thenReturn(true);
      when(() => gate.session).thenReturn(
        const AppSession(
          uid: 'u1',
          organizationId: 'org-1',
          status: MemberStatus.active,
        ),
      );
      getIt.registerSingleton<AuthGate>(gate);

      final open = QcFindingNc(
        findingId: 8,
        inspectionId: 4,
        type: NcType.nonConformance,
        severity: NcSeverity.minor,
        description: 'typing error',
        status: NcStatus.open,
        assignedTo: '',
        assignedToName: '',
        assignedAt: '',
        createdAt: '2026-01-01 09:00:00',
        updatedAt: '2026-01-01 09:00:00',
      );

      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => QcNcrCreateScreen.open(
                    context,
                    cubit,
                    finding: open,
                    assignees: const [(id: 'm-2', name: 'Sara Qa')],
                  ),
                  child: const Text('open edit'),
                ),
              ),
            ),
          ),
          cubit,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open edit'));
      await tester.pumpAndSettle();

      await _fill(tester, 'Description', 'typo fixed');
      await tester.ensureVisible(
        find.byType(DropdownButtonFormField<({String id, String name})>),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byType(DropdownButtonFormField<({String id, String name})>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sara Qa').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final captured =
          verify(() => capa.saveFinding(captureAny())).captured.single
              as QcFindingNc;
      expect(captured.findingId, 8);
      expect(captured.status, 'Assigned');
      expect(captured.assignedTo, 'm-2');
      expect(captured.assignedAt, isNotEmpty);
      expect(captured.createdAt, '2026-01-01 09:00:00');
    });
  });
}

