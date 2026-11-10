import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/security/qr_payload.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/presentation/equipment/equipment_tab.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/qr/qr_scan_screen.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';
import 'package:material_lab/core/responsive/form_factor.dart';

class _RepoMock extends Mock implements InspectionRepository {}

class _ReportsMock extends Mock implements ReportRepository {}

class _LabMock extends Mock implements LabResultRepository {}

class _GateMock extends Mock implements AuthGate {}

class _LocalLabMock extends Mock implements LabLocalRepository {}

/// The scanner is mobile-only; in widget tests there is no plugin host, so
/// the camera permission calls fail into the manual-entry path — which is
/// exactly what these tests drive.
///
/// A successful lookup opens the inspection at once (no intermediate card).
void main() {
  setUp(() => AppText.arabic = false);
  tearDownAll(() => AppText.arabic = true);

  late _RepoMock repo;
  late _ReportsMock reports;
  late _LabMock lab;
  late _LocalLabMock localLab;
  late _GateMock gate;

  setUp(() {
    repo = _RepoMock();
    reports = _ReportsMock();
    lab = _LabMock();
    localLab = _LocalLabMock();
    gate = _GateMock();
    when(() => gate.currentUser).thenReturn(null);
    when(() => gate.isAuthenticated).thenReturn(true);
    when(() => gate.session).thenReturn(
      const AppSession(
        uid: 'u',
        role: AppRoles.admin,
        status: MemberStatus.active,
      ),
    );
    getIt.registerSingleton<InspectionRepository>(repo);
    getIt.registerSingleton<ReportRepository>(reports);
    getIt.registerSingleton<LabResultRepository>(lab);
    getIt.registerSingleton<AuthGate>(gate);
    getIt.registerSingleton<LabLocalRepository>(localLab);
  });

  tearDown(() {
    getIt.unregister<LabLocalRepository>();
    FormFactor.debugSet(null);
    if (getIt.isRegistered<InspectionRepository>()) {
      getIt.unregister<InspectionRepository>();
    }
    if (getIt.isRegistered<ReportRepository>()) {
      getIt.unregister<ReportRepository>();
    }
    if (getIt.isRegistered<LabResultRepository>()) {
      getIt.unregister<LabResultRepository>();
    }
    if (getIt.isRegistered<AuthGate>()) {
      getIt.unregister<AuthGate>();
    }
  });

  Widget host() => ScreenUtilInit(
    designSize: const Size(1280, 720),
    builder: (context, _) => const MaterialApp(home: QrScanScreen()),
  );

  /// pumpAndSettle never settles while the checking spinner is up, so pump
  /// a few frames instead; mocked calls resolve between frames.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  const row = {
    'id': 7,
    'entry_code': 'R-9',
    'material_name': 'Cement',
    'inspection_date': '2026-10-01',
    'decision_status': 'APPROVED',
  };

  const detail = {
    'id': 7,
    'entry_code': 'R-9',
    'material_name': 'Cement',
    'material_code': 'CEM',
    'inspection_date': '2026-10-01',
    'supplier': 'Acme',
    'quantity': '100',
    'sample_taken_by': 'Tech',
    'specialist_name': 'Tech',
    'decision_status': 'APPROVED',
    'decision_version': 1,
    'sample_names': ['Result'],
    'physical_reference': {},
    'physical_results': {},
    'chemical_reference': {},
    'chemical_results': {},
    'status_history': [],
  };

  void stubDetail() {
    when(() => repo.getById(any())).thenAnswer((_) async => detail);
    when(
      () => lab.listSampleTestsForEntryCode(any()),
    ).thenAnswer((_) async => []);
  }

  for (final size in [const Size(390, 844), const Size(844, 420)]) {
    testWidgets('phone QR details stay a pushed page at ${size.width}dp', (
      tester,
    ) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      when(
        () => repo.list(
          query: any(named: 'query'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => [row]);
      stubDetail();
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(400, 860),
          minTextAdapt: true,
          splitScreenMode: true,
          builder: (_, _) => const MaterialApp(home: QrScanScreen()),
        ),
      );
      await settle(tester);
      await tester.enterText(find.byType(TextFormField), 'R-9');
      await tester.ensureVisible(find.text('Search'));
      await tester.tap(find.text('Search'));
      await settle(tester);
      expect(find.text('Cement'), findsWidgets);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Scan QR code'), findsOneWidget);
      expect(find.text('Cement'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('manual entry opens the inspection at once', (tester) async {
    when(
      () => repo.list(
        query: any(named: 'query'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => [row]);
    stubDetail();

    await tester.pumpWidget(host());
    await settle(tester);

    await tester.enterText(find.byType(TextFormField), 'R-9');
    await tester.tap(find.text('Search'));
    await settle(tester);

    // The detail opened in a window: header shows the material, and there
    // is no intermediate "open" card anymore.
    expect(find.text('Cement'), findsWidgets);
    expect(find.text('Open inspection'), findsNothing);
  });

  testWidgets('unknown code explains the miss without crashing', (
    tester,
  ) async {
    when(
      () => repo.list(
        query: any(named: 'query'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => <Map<String, dynamic>>[]);

    await tester.pumpWidget(host());
    await settle(tester);

    await tester.enterText(find.byType(TextFormField), 'R-404');
    await tester.tap(find.text('Search'));
    await settle(tester);

    expect(find.text('Open inspection'), findsNothing);
    expect(find.textContaining('Not on this device'), findsOneWidget);
  });

  testWidgets('equipment QR opens equipment instead of searching inspections', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.mobile);
    const equipment = {'id': 4, 'code': 'EQ-0004', 'name': 'Audit balance'};
    when(() => localLab.listEquipment()).thenAnswer((_) async => [equipment]);
    when(() => localLab.getEquipment(4)).thenAnswer((_) async => equipment);
    when(() => localLab.listEquipmentEvents(4)).thenAnswer((_) async => []);
    await tester.pumpWidget(host());
    await settle(tester);
    await tester.enterText(
      find.byType(TextFormField),
      encodeAppQrPayload(
        entryCode: 'EQ-0004',
        kind: appQrKindEquipment,
        body: '{}',
      ),
    );
    await tester.tap(find.text('Search'));
    await settle(tester);
    expect(find.byType(EquipmentDetailScreen), findsOneWidget);
    expect(find.text('Audit balance'), findsWidgets);
    verifyNever(
      () => repo.list(
        query: any(named: 'query'),
        limit: any(named: 'limit'),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown QR family is refused without opening another record', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await settle(tester);
    await tester.enterText(
      find.byType(TextFormField),
      encodeAppQrPayload(entryCode: 'R-9', kind: 'unsupported', body: '{}'),
    );
    await tester.tap(find.text('Search'));
    await settle(tester);
    expect(find.textContaining('The code type is unsupported'), findsOneWidget);
    verifyNever(
      () => repo.list(
        query: any(named: 'query'),
        limit: any(named: 'limit'),
      ),
    );
    verifyNever(() => localLab.listEquipment());
  });

  testWidgets('a QR cannot bypass record read permissions', (tester) async {
    when(
      () => gate.session,
    ).thenReturn(const AppSession(uid: 'u', status: MemberStatus.invited));
    await tester.pumpWidget(host());
    await settle(tester);
    await tester.enterText(find.byType(TextFormField), 'R-9');
    await tester.tap(find.text('Search'));
    await settle(tester);
    expect(find.textContaining('do not have permission'), findsOneWidget);
    verifyNever(
      () => repo.list(
        query: any(named: 'query'),
        limit: any(named: 'limit'),
      ),
    );
  });

  testWidgets(
    'shared scanner is replaced by the target; back returns to the original page',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      when(
        () => repo.list(
          query: any(named: 'query'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => [row]);
      stubDetail();
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(400, 860),
          builder: (_, _) => MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => const QrScanScreen(replaceOnOpen: true),
                    ),
                  ),
                  child: const Text('Original page'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Original page'));
      await settle(tester);
      await tester.enterText(
        find.byType(TextFormField),
        encodeAppQrPayload(entryCode: 'R-9', body: '{}'),
      );
      await tester.tap(find.text('Search'));
      await settle(tester);
      expect(find.text('Cement'), findsWidgets);
      expect(find.byType(QrScanScreen), findsNothing);
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(find.text('Original page'), findsOneWidget);
      expect(find.byType(QrScanScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
