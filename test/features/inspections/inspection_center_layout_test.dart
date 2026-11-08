import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/inspections/domain/inspection_repository.dart';
import 'package:material_lab/features/inspections/presentation/center/inspection_center_screen.dart';
import 'package:material_lab/features/inspections/presentation/cubit/inspections_cubit.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';
import 'package:material_lab/features/reports/presentation/cubit/reports_cubit.dart';

class _InspectionRepository extends Mock implements InspectionRepository {}

class _ReportRepository extends Mock implements ReportRepository {}

class _AuthGate extends Mock implements AuthGate {}

void main() {
  LeakTesting.enable();
  tearDown(() async {
    await getIt.reset();
    FormFactor.debugSet(null);
    AppText.useLanguage('ar');
  });

  for (final factor in [AppFormFactor.desktop, AppFormFactor.mobile]) {
    testWidgets(
      'inspection center reopens and switches tabs on ${factor.name}',
      (tester) async {
        FormFactor.debugSet(factor);
        AppText.useLanguage('en');
        final size = factor.isMobile
            ? const Size(400, 860)
            : const Size(1312, 737);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final repo = _InspectionRepository();
        final reports = _ReportRepository();
        final gate = _AuthGate();
        when(() => gate.currentUser).thenReturn(null);
        when(() => gate.canWrite(Permission.reportsCreate)).thenReturn(false);
        when(
          () => repo.list(
            query: any(named: 'query'),
            status: any(named: 'status'),
            reason: any(named: 'reason'),
            limit: any(named: 'limit'),
            offset: any(named: 'offset'),
            orderBy: any(named: 'orderBy'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
            supplier: any(named: 'supplier'),
            materialId: any(named: 'materialId'),
            productId: any(named: 'productId'),
          ),
        ).thenAnswer((_) async => []);
        when(
          () => repo.count(
            query: any(named: 'query'),
            status: any(named: 'status'),
            reason: any(named: 'reason'),
            kind: any(named: 'kind'),
            dateFrom: any(named: 'dateFrom'),
            dateTo: any(named: 'dateTo'),
            supplier: any(named: 'supplier'),
            materialId: any(named: 'materialId'),
            productId: any(named: 'productId'),
          ),
        ).thenAnswer((_) async => 0);
        getIt.registerSingleton<InspectionRepository>(repo);
        getIt.registerSingleton<ReportRepository>(reports);
        getIt.registerSingleton<AuthGate>(gate);
        final inspections = InspectionsCubit(repo: repo, reports: reports);
        final reportCubit = ReportsCubit(repo: reports);
        addTearDown(inspections.close);
        addTearDown(reportCubit.close);
        inspections.load();
        for (var cycle = 0; cycle < 3; cycle++) {
          await tester.pumpWidget(
            ScreenUtilInit(
              designSize: size,
              builder: (_, _) => MaterialApp(
                home: Scaffold(
                  body: MultiBlocProvider(
                    providers: [
                      BlocProvider.value(value: inspections),
                      BlocProvider.value(value: reportCubit),
                    ],
                    child: const InspectionCenterScreen(),
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          final pages = find
              .descendant(
                of: find.byType(InspectionCenterScreen),
                matching: find.byType(IndexedStack),
              )
              .first;
          const labels = [
            'Raw-material inspections',
            'Product inspections',
            'Inspection reports',
          ];
          for (final index in [1, 2, 0]) {
            final tab = find.widgetWithText(ChoiceChip, labels[index]);
            await tester.ensureVisible(tab);
            await tester.tap(tab);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            expect(tester.widget<IndexedStack>(pages).index, index);
            expect(tester.getSize(pages).height, greaterThan(0));
          }
          await tester.pumpWidget(const SizedBox.shrink());
          expect(find.byType(InspectionCenterScreen), findsNothing);
        }
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
