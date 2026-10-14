import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/auth/domain/user.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/lab/domain/product_batch_repository.dart';
import 'package:material_lab/features/lab/presentation/batch/product_batch_section.dart';

class _BatchRepoMock extends Mock implements ProductBatchRepository {}

class _InspectionRepoMock extends Mock implements InspectionRepository {}

class _GateMock extends Mock implements AuthGate {}

class _UserMock extends Mock implements User {}

/// The batch section renders inside the product detail only:
/// independent samples (taker, time, own physical + chemical results),
/// with add/edit affordances and no lab coupling.
void main() {
  late _BatchRepoMock repo;
  late _InspectionRepoMock inspections;
  late _GateMock gate;
  late _UserMock user;

  setUp(() {
    AppText.useLanguage('en');
    repo = _BatchRepoMock();
    inspections = _InspectionRepoMock();
    gate = _GateMock();
    user = _UserMock();
    when(() => gate.currentUser).thenReturn(user);
    when(() => user.id).thenReturn(1);
    when(() => user.uid).thenReturn('uid-1');
    when(() => user.fullName).thenReturn('QC Tech');
    when(() => user.role).thenReturn('admin');
    getIt.registerSingleton<ProductBatchRepository>(repo);
    getIt.registerSingleton<InspectionRepository>(inspections);
    getIt.registerSingleton<AuthGate>(gate);

    when(() => repo.listBatchSamples(any())).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {
          'id': 11,
          'batch_id': 7,
          'sample_no': 1,
          'sample_name': 'Sample 1',
          'sample_taker': 'Karim',
          'physical_results_json': '{"Color": "white"}',
          'chemical_results_json':
              '[{"name": "Protein", "result": "12.5", "unit": "%"}]',
          'tested_by_name_resolved': 'QC Tech',
          'tested_at': '2026-01-01',
          'decision_status': 'APPROVED',
          'decision_reason': '',
        },
      ],
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<void> pumpSection(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 860);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(400, 860),
        builder: (_, _) => const MaterialApp(
          home: Scaffold(
            body: ProductBatchSection(
              batchId: 7,
              productId: 3,
              productName: 'Flour 50T',
              entryCode: 'BATCH-50T',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows sequential table with taker + time + counts', (
    tester,
  ) async {
    await pumpSection(tester);
    expect(find.text('Batch samples'), findsOneWidget);
    // Sequential table headers: sample-after-sample with taker + date/hour.
    expect(find.text('Sample'), findsWidgets);
    expect(find.textContaining('Sample 1'), findsWidgets);
    expect(find.textContaining('Karim'), findsWidgets);
    // Own result rows stay collapsed until the sample row is tapped.
    expect(find.text('Protein'), findsNothing);
    await tester.tap(find.text('Sample 1'));
    await tester.pumpAndSettle();
    expect(find.text('Protein'), findsOneWidget);
    expect(find.text('12.5'), findsOneWidget);
    expect(find.text('Color'), findsOneWidget);
    expect(find.text('Edit sample & results'), findsOneWidget);
  });

  testWidgets('tapping an undecided sample expands its own tables', (
    tester,
  ) async {
    when(() => repo.listBatchSamples(any())).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {
          'id': 12,
          'batch_id': 7,
          'sample_no': 2,
          'sample_name': 'Sample 2',
          'sample_taker': '',
          'physical_results_json': '{}',
          'chemical_results_json': '[]',
          'tested_by_name_resolved': 'QC Tech',
          'tested_at': '2026-01-02 14:30:00',
          'decision_status': '',
          'decision_reason': '',
        },
      ],
    );
    await pumpSection(tester);
    expect(find.text('Edit sample & results'), findsNothing);
    await tester.tap(find.text('Sample 2'));
    await tester.pumpAndSettle();
    expect(find.text('Edit sample & results'), findsOneWidget);
  });

  testWidgets('empty batch offers a first sample', (tester) async {
    when(
      () => repo.listBatchSamples(any()),
    ).thenAnswer((_) async => <Map<String, dynamic>>[]);
    await pumpSection(tester);
    expect(find.text('No samples yet'), findsOneWidget);
    expect(find.text('New sample'), findsOneWidget);
  });
}
