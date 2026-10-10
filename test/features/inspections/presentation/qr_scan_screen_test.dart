import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/qr/qr_scan_screen.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';

class _RepoMock extends Mock implements InspectionRepository {}

class _ReportsMock extends Mock implements ReportRepository {}

class _LabMock extends Mock implements LabResultRepository {}

class _GateMock extends Mock implements AuthGate {}

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

  setUp(() {
    repo = _RepoMock();
    reports = _ReportsMock();
    lab = _LabMock();
    final gate = _GateMock();
    when(() => gate.currentUser).thenReturn(null);
    getIt.registerSingleton<InspectionRepository>(repo);
    getIt.registerSingleton<ReportRepository>(reports);
    getIt.registerSingleton<LabResultRepository>(lab);
    getIt.registerSingleton<AuthGate>(gate);
  });

  tearDown(() {
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
}
