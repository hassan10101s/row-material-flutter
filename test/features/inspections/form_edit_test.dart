import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/design_system/widgets/app_wizard.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspection_detail_cubit.dart';
import 'package:material_lab/features/inspections/presentation/detail/desktop/inspection_detail_screen.dart';
import 'package:material_lab/features/inspections/presentation/detail/mobile/inspection_detail_screen.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';

class _InspectionRepoMock extends Mock implements InspectionRepository {}

class _ReferenceMock extends Mock implements ReferenceRepository {}

class _ReportMock extends Mock implements ReportRepository {}

class _GateMock extends Mock implements AuthGate {}

class _UserMock extends Mock implements User {}

Map<String, dynamic> _inspection() => {
      'id': 7,
      'material_id': 1,
      'material_name': 'Sugar',
      'material_code': 'SUG',
      'entry_code': 'QC-3',
      'inspection_date': '2026-09-05',
      'expiry_date': '',
      'supplier': 'Acme',
      'truck_number': '',
      'quantity': '100',
      'sample_taken_by': 'QC Man',
      'specialist_name': 'Spec',
      'decision_version': 1,
      'decision_status': 'APPROVED',
      'decision_reason': '',
      'follow_up_note': '',
      'rejected_quantity': '',
      'physical_reference': {'Moisture': 'Max 14%'},
      'physical_results': {'Moisture': '12'},
      'chemical_reference': <String, dynamic>{},
      'chemical_results': <String, dynamic>{},
      'sample_names': ['S1'],
    };

/// Edit flow for the inspection record (محضر الفحص): the detail screen's
/// Edit button opens the prefilled form — design-system dialog on desktop,
/// stepped wizard route on phones — and saving updates (never creates).
void main() {
  setUpAll(() {
    registerFallbackValue(const UserContext(id: 0, fullName: '', role: ''));
  });

  late _InspectionRepoMock repo;
  late _ReferenceMock reference;
  late _ReportMock reports;
  late _GateMock gate;
  late _UserMock user;

  setUp(() {
    AppText.useLanguage('en');
    repo = _InspectionRepoMock();
    reference = _ReferenceMock();
    reports = _ReportMock();
    gate = _GateMock();
    user = _UserMock();
    when(() => user.id).thenReturn(1);
    when(() => user.uid).thenReturn('u');
    when(() => user.fullName).thenReturn('QC');
    when(() => user.role).thenReturn('Admin');
    when(() => user.canEditInspections).thenReturn(true);
    when(() => user.canEditUsers).thenReturn(false);
    when(() => gate.currentUser).thenReturn(user);
    getIt.registerSingleton<AuthGate>(gate);
    getIt.registerSingleton<InspectionRepository>(repo);
    getIt.registerSingleton<ReferenceRepository>(reference);

    when(() => repo.getById(7)).thenAnswer((_) async => _inspection());
    when(() => reference.listMaterials()).thenAnswer(
      (_) async => [
        {'id': 1, 'material_name': 'Sugar', 'material_code': 'SUG'},
      ],
    );
    when(() => reference.getMaterial(1, inspectionDate: '2026-09-05'))
        .thenAnswer((_) async => {
              'material_code': 'SUG',
              'next_entry_code': 'QC-9',
              'physical_reference': {'Moisture': 'Max 14%'},
              'chemical_reference': <String, dynamic>{},
            });
    when(() => repo.update(any(), any(), any()))
        .thenAnswer((_) async => <String, dynamic>{});
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

  Future<InspectionDetailCubit> loadedDetailCubit() async {
    final cubit = InspectionDetailCubit(
      inspectionId: 7,
      repo: repo,
      reports: reports,
    );
    addTearDown(cubit.close);
    await cubit.load();
    return cubit;
  }

  Finder supplierField() => find.byWidgetPredicate(
        (w) => w is TextField && w.controller?.text == 'Acme',
      );

  group('desktop edit', () {
    testWidgets('opens the prefilled design-system dialog and updates',
        (tester) async {
      final cubit = await loadedDetailCubit();
      await pumpAs(
        tester,
        AppFormFactor.desktop,
        BlocProvider.value(
          value: cubit,
          child: const DesktopInspectionDetailScreen(inspectionId: 7),
        ),
      );

      await tester.tap(find.text('Edit record'));
      await tester.pumpAndSettle();

      // Windows design-system chrome, prefilled from the stored row.
      expect(find.byType(AppWindow), findsOneWidget);
      expect(supplierField(), findsOneWidget);

      // The full form scrolls inside the window: drive to Save first.
      await tester.ensureVisible(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      verify(() => repo.update(7, any(), any())).called(1);
      verifyNever(() => repo.create(any(), any()));
      expect(find.byType(AppWindow), findsNothing);
    });
  });

  group('mobile edit', () {
    testWidgets('opens the prefilled wizard route, no dialog', (tester) async {
      final cubit = await loadedDetailCubit();
      await pumpAs(
        tester,
        AppFormFactor.mobile,
        BlocProvider.value(
          value: cubit,
          child: const MobileInspectionDetailScreen(inspectionId: 7),
        ),
      );

      await tester.tap(find.text('Edit record'));
      await tester.pumpAndSettle();

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Edit inspection'), findsOneWidget);
      expect(find.byType(AppWizardBar), findsOneWidget);
      expect(find.byType(AppWindow), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(supplierField(), findsOneWidget);
    });
  });
}
