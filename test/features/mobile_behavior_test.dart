import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_adaptive_list.dart';
import 'package:material_lab/design_system/widgets/app_paginated_table.dart';
import 'package:material_lab/design_system/widgets/app_wizard.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_detail_cubit.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_form_cubit.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspections_cubit.dart';
import 'package:material_lab/features/inspections/presentation/detail/mobile/inspection_detail_screen.dart';
import 'package:material_lab/features/inspections/presentation/form/inspection_form_screen.dart';
import 'package:material_lab/features/inspections/presentation/list/mobile/inspections_screen.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/analyses_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/inventory_cubit.dart';
import 'package:material_lab/features/lab/presentation/cubit/test_history_cubit.dart';
import 'package:material_lab/features/lab/presentation/inventory/inventory_tab.dart';
import 'package:material_lab/features/lab/presentation/analyses/analyses_tab.dart';
import 'package:material_lab/features/lab/presentation/test_history/test_history_tab.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_filters.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_kpis.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_report_repository.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_report_row.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_ncr_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/ncr/qc_ncr_list_screen.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/reference/presentation/cubit/products_cubit.dart';
import 'package:material_lab/features/reference/presentation/products/mobile/products_tab.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';

class _LocalMock extends Mock implements LabLocalRepository {}

class _LabConfigMock extends Mock implements LabConfigurationRepository {}

class _LabResultsMock extends Mock implements LabResultRepository {}

class _ReferenceMock extends Mock implements ReferenceRepository {}

class _InspectionRepoMock extends Mock implements InspectionRepository {}

class _ReportMock extends Mock implements ReportRepository {}

class _GateMock extends Mock implements AuthGate {}

class _NcrRepoMock extends Mock implements QcNcReportRepository {}

/// Mobile-behavior contract: every screen split in the desktop/mobile
/// refactor must render the phone experience on a phone grid — cards,
/// never tables; full-screen routes, never fixed dialogs; wizards step
/// through long forms. Desktop behavior is pinned alongside so a mobile
/// fix can never move a Windows pixel.
const mobileGrid = Size(400, 860);
const desktopGrid = Size(1280, 720);

void main() {
  late _LocalMock local;
  late _LabConfigMock labConfig;
  late _LabResultsMock labResults;
  late _ReferenceMock reference;
  late _InspectionRepoMock inspections;
  late _ReportMock reports;
  late _GateMock gate;

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(const NcrFilters());
  });

  setUp(() {
    AppText.useLanguage('en');

    local = _LocalMock();
    labConfig = _LabConfigMock();
    labResults = _LabResultsMock();
    reference = _ReferenceMock();
    inspections = _InspectionRepoMock();
    reports = _ReportMock();
    gate = _GateMock();
    when(() => gate.currentUser).thenReturn(null);

    // Editors resolve registries through getIt; a route built under the
    // root navigator cannot see screen providers, so the singletons must
    // exist like in production.
    getIt.registerSingleton<LabLocalRepository>(local);
    getIt.registerSingleton<LabConfigurationRepository>(labConfig);
    getIt.registerSingleton<LabResultRepository>(labResults);
    getIt.registerSingleton<ReferenceRepository>(reference);
    getIt.registerSingleton<AuthGate>(gate);

    when(() => local.listUnitSymbols()).thenAnswer((_) async => <String>[]);
    when(() => local.listInventory()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {
          'id': 1,
          'name': 'Sugar',
          'category': 'powder',
          'unit': 'kg',
          'current_qty': 10,
          'min_qty': 2,
        },
      ],
    );
    when(() => labConfig.listAnalyses()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {
          'id': 1,
          'name': 'Moisture',
          'unit': '%',
          'dynamic_fields': ['Sample Name'],
          'formula': {'expression': ''},
          'items': [],
        },
      ],
    );
    // Tested-at is "now": the history tab defaults to the last-24h
    // filter, so a fixed old date would be filtered out of the cards.
    final nowIso = DateTime.now().toIso8601String();
    when(() => labResults.listSampleTests()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {
          'analysis_name': 'Moisture',
          'sample_name': 'S1',
          'source_name': 'Sugar',
          'result_text': '14',
          'range_state': 'in',
          'tested_at': nowIso,
          'tested_by_name': 'QC',
        },
      ],
    );
    when(() => local.listConsumptionLog()).thenAnswer(
      (_) async => <Map<String, dynamic>>[],
    );
    when(() => labConfig.listProducts()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {
          'id': 1,
          'name': 'Gel',
          'category': 'Food',
          'description': 'Test gel',
          'ranges': [
            {
              'analysis_name': 'Moisture',
              'min_value': '10',
              'max_value': '14',
              'unit': '%',
            },
          ],
        },
      ],
    );
    when(() => reference.listParameters()).thenAnswer(
      (_) async => <Map<String, dynamic>>[],
    );
    when(() => reference.listUnits()).thenAnswer(
      (_) async => <Map<String, dynamic>>[],
    );
    when(() => reference.listMaterials()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {'id': 1, 'material_name': 'Sugar', 'material_code': 'SUG'},
      ],
    );
  });

  tearDown(() async {
    await getIt.reset();
    FormFactor.debugSet(null);
  });

  /// Lays [child] out on the grid its experience was authored against,
  /// with the form factor pinned (a test cannot turn the platform knob).
  Future<void> pumpAs(
    WidgetTester tester,
    AppFormFactor factor,
    Widget child,
  ) async {
    FormFactor.debugSet(factor);
    final grid = factor.isMobile ? mobileGrid : desktopGrid;
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = grid;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: grid,
        builder: (_, _) => MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('mobile renders cards, never tables', () {
    testWidgets('inventory host shows cards on a phone grid', (tester) async {
      final cubit = InventoryCubit(repo: local);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(value: cubit, child: const InventoryTab()),
      );

      expect(find.byType(DataTable), findsNothing);
      expect(find.text('Sugar'), findsOneWidget);
      expect(find.text('Add item'), findsOneWidget);
    });

    testWidgets('analyses host shows cards on a phone grid', (tester) async {
      final cubit = AnalysesCubit(repo: labConfig);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(value: cubit, child: const AnalysesTab()),
      );

      expect(find.byType(DataTable), findsNothing);
      expect(find.text('Moisture'), findsOneWidget);
    });

    testWidgets('products host shows cards with ranges inline', (tester) async {
      final cubit = ProductsCubit(repo: labConfig);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(
          value: cubit,
          child: const MobileProductsTab(),
        ),
      );

      expect(find.byType(DataTable), findsNothing);
      expect(find.text('Gel'), findsOneWidget);
      expect(find.textContaining('Moisture'), findsOneWidget);
    });

    testWidgets('test history host shows cards on a phone grid',
        (tester) async {
      final cubit = TestHistoryCubit(
        results: labResults,
        local: local,
        config: labConfig,
      );
      addTearDown(cubit.close);

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(value: cubit, child: const TestHistoryTab()),
      );

      expect(find.byType(DataTable), findsNothing);
      expect(find.textContaining('Moisture'), findsOneWidget);
    });

    testWidgets('NCR list shows cards plus the total line', (tester) async {
      final repo = _NcrRepoMock();
      when(() => repo.kpis(any()))
          .thenAnswer((_) async => const NcrKpis(total: 1));
      when(
        () => repo.list(
          any(),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
          orderBy: any(named: 'orderBy'),
          orderDir: any(named: 'orderDir'),
        ),
      ).thenAnswer(
        (_) async => [
          NcrReportRow(
            findingId: 1,
            inspectionId: 1,
            inspectionRefId: 'INS-1',
            code: 'NC-1',
            severity: 'Major',
            description: 'defect 1',
            status: 'Open',
            lotNo: 'LOT-1',
            createdAt: '2026-01-01 09:00:00',
            dueDate: '',
          ),
        ],
      );
      when(() => repo.count(any())).thenAnswer((_) async => 1);
      when(() => repo.detail(any())).thenAnswer((_) async => null);
      when(() => repo.agingBuckets(any())).thenAnswer((_) async => const []);
      when(
        () => repo.topDefects(any(), limit: any(named: 'limit')),
      ).thenAnswer((_) async => const []);
      when(
        () => repo.repeatByRef(any(), limit: any(named: 'limit')),
      ).thenAnswer((_) async => const []);
      when(() => repo.filterOptions()).thenAnswer(
        (_) async => const NcrFilterOptions(
          statuses: ['Open'],
          severities: ['Major'],
          capaStatuses: ['Open'],
        ),
      );
      final cubit = QcNcrCubit(repo);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        QcNcrListScreen(cubit: cubit),
      );

      expect(find.byType(DataTable), findsNothing);
      expect(find.byType(AppAdaptiveDataView), findsOneWidget);
      expect(find.text('NC-1'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('NCR list shows the same cards on a desktop grid',
        (tester) async {
      final repo = _NcrRepoMock();
      when(() => repo.kpis(any()))
          .thenAnswer((_) async => const NcrKpis(total: 1));
      when(
        () => repo.list(
          any(),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
          orderBy: any(named: 'orderBy'),
          orderDir: any(named: 'orderDir'),
        ),
      ).thenAnswer(
        (_) async => [
          NcrReportRow(
            findingId: 1,
            inspectionId: 1,
            inspectionRefId: 'INS-1',
            code: 'NC-1',
            severity: 'Major',
            description: 'defect 1',
            status: 'Open',
            lotNo: 'LOT-1',
            createdAt: '2026-01-01 09:00:00',
            dueDate: '',
          ),
        ],
      );
      when(() => repo.count(any())).thenAnswer((_) async => 1);
      when(() => repo.detail(any())).thenAnswer((_) async => null);
      when(() => repo.agingBuckets(any())).thenAnswer((_) async => const []);
      when(
        () => repo.topDefects(any(), limit: any(named: 'limit')),
      ).thenAnswer((_) async => const []);
      when(
        () => repo.repeatByRef(any(), limit: any(named: 'limit')),
      ).thenAnswer((_) async => const []);
      when(() => repo.filterOptions()).thenAnswer(
        (_) async => const NcrFilterOptions(
          statuses: ['Open'],
          severities: ['Major'],
          capaStatuses: ['Open'],
        ),
      );
      final cubit = QcNcrCubit(repo);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.desktop,
        QcNcrListScreen(cubit: cubit),
      );

      // Unified mobile logic: cards on desktop too, never a table.
      expect(find.byType(DataTable), findsNothing);
      expect(find.byType(AppAdaptiveDataView), findsOneWidget);
      expect(find.text('NC-1'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('inspections ledger shows cards on a phone grid',
        (tester) async {
      when(
        () => inspections.list(
          query: any(named: 'query'),
          status: any(named: 'status'),
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
          orderBy: any(named: 'orderBy'),
          kind: any(named: 'kind'),
        ),
      ).thenAnswer(
        (_) async => <Map<String, dynamic>>[
          {
            'id': 1,
            'entry_code': 'QC-1',
            'inspection_date': '2026-10-01',
            'material_name': 'Sugar',
            'supplier': 'Acme',
            'quantity': '100',
            'decision_status': 'APPROVED',
          },
        ],
      );
      when(
        () => inspections.count(
          query: any(named: 'query'),
          status: any(named: 'status'),
          kind: any(named: 'kind'),
        ),
      ).thenAnswer((_) async => 1);
      final cubit = InspectionsCubit(repo: inspections, reports: reports);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(
          value: cubit,
          child: const MobileInspectionsScreen(),
        ),
      );

      expect(find.byType(DataTable), findsNothing);
      expect(find.byType(AppPaginatedTable), findsNothing);
      expect(find.textContaining('Sugar'), findsOneWidget);
    });
  });

  group('mobile opens routes, never fixed dialogs', () {
    testWidgets('inventory editor is a full-screen route', (tester) async {
      final cubit = InventoryCubit(repo: local);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(value: cubit, child: const InventoryTab()),
      );

      await tester.tap(find.text('Add item'));
      await tester.pumpAndSettle();

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(AppWindow), findsNothing);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('analyses editor is a full-screen route', (tester) async {
      final cubit = AnalysesCubit(repo: labConfig);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(value: cubit, child: const AnalysesTab()),
      );

      await tester.tap(find.text('Add analysis'));
      await tester.pumpAndSettle();

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(AppWindow), findsNothing);
    });

    testWidgets('products editor is a full-screen route', (tester) async {
      final cubit = ProductsCubit(repo: labConfig);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(
          value: cubit,
          child: const MobileProductsTab(),
        ),
      );

      await tester.tap(find.text('New Product'));
      await tester.pumpAndSettle();

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(AppWindow), findsNothing);
    });

    testWidgets('overlay renders a bottom sheet on narrow widths',
        (tester) async {
      await pumpAs(
        tester,
        AppFormFactor.mobile,
        Builder(
          builder: (context) => FilledButton(
            onPressed: () => showAppOverlay<void>(
              context,
              title: 'Filters',
              builder: (context, close) => const Text('sheet content'),
            ),
            child: const Text('open'),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('sheet content'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
    });
  });

  group('mobile inspection form is a stepped wizard', () {
    testWidgets('wizard steps through sections and holds step 1',
        (tester) async {
      final cubit =
          InspectionFormCubit(repo: inspections, reference: reference);
      addTearDown(cubit.close);
      await cubit.loadMaterials();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(
          value: cubit,
          child: const InspectionFormScreen(wizard: true),
        ),
      );

      // Step chrome: segmented bar + 52h bottom bar, one section at a time.
      expect(find.byType(AppWizardBar), findsOneWidget);
      expect(find.byType(AppWizardBottomBar), findsOneWidget);
      expect(find.text('Basics'), findsOneWidget);
      // Step 1 (basics card) visible; decision card not yet.
      expect(find.text('Basic data'), findsOneWidget);
      expect(find.text('Decision'), findsOneWidget);

      // Tapping the Decision step moves there; basics leave.
      await tester.tap(find.text('Decision').first);
      await tester.pumpAndSettle();
      expect(find.text('Basic data'), findsNothing);
      expect(find.text('Decision'), findsWidgets);
    });

    testWidgets('wizard holds step 1 without a material', (tester) async {
      final cubit =
          InspectionFormCubit(repo: inspections, reference: reference);
      addTearDown(cubit.close);
      await cubit.loadMaterials();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(
          value: cubit,
          child: const InspectionFormScreen(wizard: true),
        ),
      );

      // Next with no material holds the step and explains why.
      await tester.tap(find.text('Next'));
      await tester.pump();
      expect(find.text('Basic data'), findsOneWidget);
    });
  });

  group('mobile inspection detail uses cards, desktop keeps tables', () {
    testWidgets('detail renders parameter cards on a phone grid',
        (tester) async {
      final cubit = InspectionDetailCubit(
        inspectionId: 1,
        repo: inspections,
        reports: reports,
      );
      addTearDown(cubit.close);
      when(() => inspections.getById(1)).thenAnswer(
        (_) async => <String, dynamic>{
          'id': 1,
          'material_name': 'Sugar',
          'material_code': 'SUG',
          'entry_code': 'QC-1',
          'inspection_date': '2026-10-01',
          'supplier': 'Acme',
          'quantity': '100',
          'sample_taken_by': 'QC',
          'specialist_name': 'Spec',
          'decision_version': 1,
          'decision_status': 'APPROVED',
          'physical_reference': {'Moisture': 'Max 14%'},
          'physical_results': {'Moisture': '12'},
          'chemical_reference': <String, dynamic>{},
          'chemical_results': <String, dynamic>{},
          'sample_names': ['S1'],
        },
      );
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(
          value: cubit,
          child: const MobileInspectionDetailScreen(inspectionId: 1),
        ),
      );

      expect(find.text('Sugar'), findsOneWidget);
      expect(find.byType(Table), findsNothing);
      expect(find.text('Moisture'), findsOneWidget);
    });
  });

  group('desktop pixels do not move', () {
    testWidgets('inventory host still renders the table dialog',
        (tester) async {
      final cubit = InventoryCubit(repo: local);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.desktop,
        BlocProvider.value(value: cubit, child: const InventoryTab()),
      );

      expect(find.byType(DataTable), findsOneWidget);

      await tester.tap(find.text('Add item'));
      await tester.pumpAndSettle();
      expect(find.byType(AppWindow), findsOneWidget);
    });
  });
}
