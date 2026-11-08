import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/chemical_consumption_report.dart';
import 'package:material_lab/features/lab/presentation/inventory/chemical_consumption_report_screen.dart';
import 'package:material_lab/features/reports/domain/report_repository.dart';

class _Repo extends Mock implements LabLocalRepository {}

class _Reports extends Mock implements ReportRepository {}

class _Gate extends Mock implements AuthGate {}

void main() {
  setUpAll(() {
    registerFallbackValue(Permission.reportsRead);
    registerFallbackValue(ConsumptionPeriod(DateTime(2026), DateTime(2026)));
  });
  tearDown(() async {
    FormFactor.debugSet(null);
    AppText.useLanguage('ar');
    await getIt.reset();
  });

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'phone' : 'desktop'} consumption report opens with correct period, chemical filter, and viewer export disabled',
      (tester) async {
        AppText.useLanguage('en');
        FormFactor.debugSet(
          mobile ? AppFormFactor.mobile : AppFormFactor.desktop,
        );
        final repo = _Repo(), reports = _Reports(), gate = _Gate();
        when(() => gate.canWrite(any())).thenAnswer(
          (call) => call.positionalArguments.first != Permission.reportsExport,
        );
        when(
          () => repo.chemicalConsumptionReport(
            period: any(named: 'period'),
            inventoryId: any(named: 'inventoryId'),
          ),
        ).thenAnswer(
          (call) async => ChemicalConsumptionReport(
            period: call.namedArguments[#period] as ConsumptionPeriod,
            inventoryId: call.namedArguments[#inventoryId] as int?,
            chemicals: const [
              ChemicalConsumptionRow(
                inventoryId: 1,
                name: 'HCl',
                unit: 'mL',
                consumed: 15,
                returned: 5,
              ),
              ChemicalConsumptionRow(
                inventoryId: 2,
                name: 'Salt',
                unit: 'kg',
                consumed: 0.5,
                returned: 0,
              ),
            ],
          ),
        );
        getIt.registerSingleton<LabLocalRepository>(repo);
        getIt.registerSingleton<ReportRepository>(reports);
        getIt.registerSingleton<AuthGate>(gate);
        final size = mobile ? const Size(390, 844) : const Size(1280, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: size,
            builder: (_, _) => const MaterialApp(
              home: Scaffold(body: ChemicalConsumptionReportButton()),
            ),
          ),
        );
        await tester.tap(find.byTooltip('Chemical consumption report'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), mobile ? findsNothing : findsOneWidget);
        expect(
          find.text(ConsumptionPeriod.lastThreeMonths(DateTime.now()).label),
          findsOneWidget,
        );
        expect(
          tester
              .widget<AppButton>(find.widgetWithText(AppButton, 'Save PDF'))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<AppButton>(find.widgetWithText(AppButton, 'Print'))
              .onPressed,
          isNull,
        );
        expect(find.text(mobile ? 'HCl (mL)' : 'HCl'), findsWidgets);
        await tester.tap(find.text('All chemicals'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('HCl (mL)').last);
        await tester.pumpAndSettle();
        final captures = verify(
          () => repo.chemicalConsumptionReport(
            period: captureAny(named: 'period'),
            inventoryId: captureAny(named: 'inventoryId'),
          ),
        ).captured;
        expect(captures.last, 1);
        expect(find.text(mobile ? 'Salt (kg)' : 'Salt'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.tap(
          mobile ? find.byType(BackButton) : find.byIcon(Icons.close),
        );
        await tester.pumpAndSettle();
        verifyNoMoreInteractions(reports);
      },
    );
  }
}
