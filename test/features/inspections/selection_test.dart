import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/platform/file_delivery.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_paginated_table.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspections_cubit.dart';
import 'package:material_lab/features/inspections/presentation/list/inspections_screen.dart';
import 'package:material_lab/features/inspections/presentation/list/mobile/inspections_screen.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';

class _InspectionRepoMock extends Mock implements InspectionRepository {}

class _ReportMock extends Mock implements ReportRepository {}

class _GateMock extends Mock implements AuthGate {}

Map<String, dynamic> _row(int id) => {
      'id': id,
      'entry_code': 'QC-$id',
      'inspection_date': '2026-10-0$id',
      'material_name': 'Sugar',
      'supplier': 'Acme',
      'quantity': '100',
      'decision_status': 'APPROVED',
    };

/// Multi-row selection + bulk export for the inspections ledger (Vue
/// register parity): header checkbox selects the page, the gold bar
/// exports reports/labels for the picked ids, success clears.
void main() {
  late _InspectionRepoMock repo;
  late _ReportMock reports;
  late _GateMock gate;

  setUpAll(() {
    registerFallbackValue(DateTime(2020));
    registerFallbackValue(
      ReportDoc(filename: '', bytes: Uint8List.fromList([])),
    );
  });

  setUp(() {
    AppText.useLanguage('en');
    repo = _InspectionRepoMock();
    reports = _ReportMock();
    gate = _GateMock();
    when(() => gate.currentUser).thenReturn(null);
    getIt.registerSingleton<AuthGate>(gate);
    getIt.registerSingleton<ReportRepository>(reports);
    // Hermetic delivery: no platform channels, no dialogs — the export
    // sheet degrades to the info banner.
    getIt.registerSingleton<FileDelivery>(const UnsupportedFileDelivery());

    when(
      () => repo.list(
        query: any(named: 'query'),
        status: any(named: 'status'),
        limit: any(named: 'limit'),
        offset: any(named: 'offset'),
        orderBy: any(named: 'orderBy'),
        kind: any(named: 'kind'),
      ),
    ).thenAnswer((_) async => [_row(1), _row(2)]);
    when(
      () => repo.count(
        query: any(named: 'query'),
        status: any(named: 'status'),
        kind: any(named: 'kind'),
      ),
    ).thenAnswer((_) async => 2);
  });

  tearDown(() async {
    await getIt.reset();
    FormFactor.debugSet(null);
  });

  Future<void> pumpAs(
    WidgetTester tester,
    AppFormFactor factor,
    Widget child,
  ) async {
    FormFactor.debugSet(factor);
    final grid =
        factor.isMobile ? const Size(400, 860) : const Size(1280, 720);
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

  group('InspectionsCubit selection', () {
    test('toggle / page-select / clear', () async {
      final cubit = InspectionsCubit(repo: repo, reports: reports);
      addTearDown(cubit.close);
      await cubit.load();

      expect(cubit.state.selectedIds, isEmpty);
      cubit.toggleSelect(1);
      expect(cubit.state.selectedIds, {1});
      cubit.toggleSelect(1);
      expect(cubit.state.selectedIds, isEmpty);

      cubit.setPageSelection([1, 2], true);
      expect(cubit.state.selectedIds, {1, 2});
      cubit.setPageSelection([1], false);
      expect(cubit.state.selectedIds, {2});
      cubit.clearSelection();
      expect(cubit.state.selectedIds, isEmpty);
    });
  });

  group('desktop ledger selection + bulk export', () {
    testWidgets('header checkbox selects the page and exports reports',
        (tester) async {
      when(() => reports.inspectionReport(any())).thenAnswer(
        (inv) async => ReportDoc(
          filename: 'r.pdf',
          bytes: Uint8List.fromList(const [0x25, 0x50, 0x44, 0x46]),
        ),
      );
      when(
        () => reports.saveReport(any(), date: any(named: 'date')),
      ).thenAnswer((_) async => File('out.pdf'));

      final cubit = InspectionsCubit(repo: repo, reports: reports);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.desktop,
        BlocProvider.value(
          value: cubit,
          child: const InspectionsScreen(),
        ),
      );

      // Header checkbox + one per row, always visible like the Vue
      // register; the bulk bar only appears once something is picked.
      expect(find.byType(AppPaginatedTable), findsOneWidget);
      expect(find.byType(Checkbox), findsNWidgets(3));
      expect(find.textContaining('Export report ('), findsNothing);

      // Header checkbox selects both page rows.
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(cubit.state.selectedIds, {1, 2});
      expect(find.textContaining('Export report (2)'), findsOneWidget);
      expect(find.text('Selected: 2'), findsOneWidget);

      // Bulk export: one PDF per id, then success + cleared selection.
      await tester.tap(find.textContaining('Export report (2)'));
      await tester.pumpAndSettle();
      verify(() => reports.inspectionReport(any())).called(2);
      verify(
        () => reports.saveReport(any(), date: any(named: 'date')),
      ).called(2);
      expect(find.text('Exported 2 reports successfully.'), findsOneWidget);
      expect(cubit.state.selectedIds, isEmpty);
      expect(find.textContaining('Export report ('), findsNothing);
    });

    testWidgets('labels export uses the batch endpoint and clears',
        (tester) async {
      when(() => reports.batchLabelsPdf(any())).thenAnswer(
        (_) async => ReportDoc(
          filename: 'labels.pdf',
          bytes: Uint8List.fromList(const [0x25, 0x50, 0x44, 0x46]),
        ),
      );
      when(
        () => reports.saveReport(any(), date: any(named: 'date')),
      ).thenAnswer((_) async => File('labels.pdf'));

      final cubit = InspectionsCubit(repo: repo, reports: reports);
      addTearDown(cubit.close);
      await cubit.load();

      await pumpAs(
        tester,
        AppFormFactor.desktop,
        BlocProvider.value(
          value: cubit,
          child: const InspectionsScreen(),
        ),
      );

      // Select a single row via its own checkbox.
      await tester.tap(find.byType(Checkbox).at(1));
      await tester.pumpAndSettle();
      expect(cubit.state.selectedIds, {1});

      await tester.tap(find.textContaining('Export labels (1)'));
      await tester.pumpAndSettle();
      verify(() => reports.batchLabelsPdf([1])).called(1);
      expect(cubit.state.selectedIds, isEmpty);
    });
  });

  group('mobile ledger selection', () {
    testWidgets('card checkbox toggles the bulk bar', (tester) async {
      final cubit = InspectionsCubit(repo: repo, reports: reports);
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

      expect(find.byType(Checkbox), findsWidgets);
      expect(find.textContaining('Export report ('), findsNothing);

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(cubit.state.selectedIds, isNotEmpty);
      expect(find.textContaining('Export report ('), findsOneWidget);

      await tester.tap(find.text('Clear selection'));
      await tester.pumpAndSettle();
      expect(cubit.state.selectedIds, isEmpty);
      expect(find.textContaining('Export report ('), findsNothing);
    });
  });
}
