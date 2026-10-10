import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/qc_manager/domain/qc_enums.dart';
import 'package:material_lab/features/qc_manager/domain/qc_inspection.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/qc_repositories.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_inspection_sheet_cubit.dart';
import 'package:material_lab/features/qc_manager/presentation/inspections/qc_inspection_sheet_screen.dart';

class _InspectionsMock extends Mock implements QcInspectionRepository {}

class _TemplatesMock extends Mock implements QcTemplateRepository {}

class _NcCapaMock extends Mock implements QcNcCapaRepository {}

class _GateMock extends Mock implements AuthGate {}

const _now = '2026-05-01 08:00:00';

/// Regression: the sheet crashed on open with real-shaped rows —
/// `RenderFlex children have non-zero flex but incoming width constraints
/// are unbounded` from `_ChoiceButton`'s max-axis inner row, plus a
/// deactivated-ancestor lookup when `_PassFailRowState`'s lazy controllers
/// first initialized inside `dispose()`.
/// Served by mocks (no timing variable); `qc_entry_real_db_test.dart` covers
/// the same path against a real database.
void main() {
  setUp(() => AppText.arabic = false);
  tearDownAll(() => AppText.arabic = true);
  setUpAll(() {
    registerFallbackValue(Permission.qcWrite);
  });

  testWidgets('sheet with real-shaped rows renders', (tester) async {
    final repo = _InspectionsMock();
    final templates = _TemplatesMock();
    final ncCapa = _NcCapaMock();
    final gate = _GateMock();
    when(() => gate.canWrite(any())).thenReturn(true);
    getIt.registerSingleton<AuthGate>(gate);
    addTearDown(() => getIt.unregister<AuthGate>());

    final inspection = QcInspection(
      inspectionId: 1,
      templateId: 1,
      refType: QcRefType.lot,
      lotNo: 'LOT-9',
      status: QcInspectionStatus.inProgress,
      resultOverall: QcOverallResult.pending,
      inspectionDate: '2026-05-01',
      createdAt: _now,
      updatedAt: _now,
    );
    const section = QcSection(
      sectionId: 1,
      templateId: 1,
      title: 'Visual',
    );
    const item1 = QcItem(
      itemId: 1,
      sectionId: 1,
      templateId: 1,
      label: 'No rust',
      itemType: QcItemType.passFail,
    );
    const item2 = QcItem(
      itemId: 2,
      sectionId: 1,
      templateId: 1,
      label: 'Thickness',
      itemType: QcItemType.number,
      minValue: 1,
      maxValue: 5,
      unit: 'mm',
    );
    QcResponse response(int itemId) => QcResponse(
      respId: itemId,
      inspectionId: 1,
      itemId: itemId,
      sectionId: 1,
      result: QcResponseResult.na,
      createdAt: _now,
      updatedAt: _now,
    );

    when(() => repo.getInspection(1)).thenAnswer((_) async => inspection);
    when(() => repo.listFindings(1)).thenAnswer((_) async => <QcFindingNc>[]);
    when(
      () => repo.listResponses(1),
    ).thenAnswer((_) async => [response(1), response(2)]);
    when(() => templates.getTemplateTree(1)).thenAnswer(
      (_) async => (
        template: QcTemplate(
          templateId: 1,
          name: 'Incoming Steel',
          isPublished: true,
          createdAt: _now,
          updatedAt: _now,
        ),
        sections: const [section],
        items: const [item1, item2],
      ),
    );

    final cubit = QcInspectionSheetCubit(
      repo: repo,
      templates: templates,
      ncCapa: ncCapa,
      inspectionId: 1,
    )..load();
    addTearDown(cubit.close);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        builder: (context, _) => BlocProvider.value(
          value: cubit,
          child: const MaterialApp(home: QcInspectionSheetScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No rust'), findsOneWidget);
    expect(find.text('Thickness'), findsOneWidget);
  });
}
