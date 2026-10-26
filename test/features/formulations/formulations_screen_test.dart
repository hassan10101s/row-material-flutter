import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';
import 'package:material_lab/design_system/widgets/app_text_field.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/formulations/domain/formulation_calculator.dart';
import 'package:material_lab/features/formulations/domain/formulation_repository.dart';
import 'package:material_lab/features/formulations/presentation/formulations_screen.dart';

class _Repo extends Mock implements FormulationRepository {}

class _Gate extends Mock implements AuthGate {}

void main() {
  late _Repo repo;
  setUpAll(() {
    registerFallbackValue(Permission.orgRead);
    registerFallbackValue(DateTime(2026));
    registerFallbackValue(<String, dynamic>{});
  });
  setUp(() {
    AppText.useLanguage('en');
    repo = _Repo();
    final gate = _Gate();
    when(() => gate.canWrite(any())).thenReturn(true);
    when(() => repo.list(archived: any(named: 'archived'))).thenAnswer(
      (call) async => call.namedArguments[#archived] == true
          ? []
          : [
              {
                'id': 1,
                'name': 'Starter',
                'items_json':
                    '[{"material_id":1,"material_name":"Maize","quantity_kg":100,"price_per_kg":2}]',
                'parameters_json': '{"period":"day","from":"2026-01-15"}',
              },
            ],
    );
    when(repo.materials).thenAnswer(
      (_) async => [
        {'id': 1, 'material_name': 'Maize'},
      ],
    );
    when(repo.products).thenAnswer((_) async => []);
    when(repo.parameters).thenAnswer((_) async => []);
    getIt.registerSingleton<FormulationRepository>(repo);
    getIt.registerSingleton<AuthGate>(gate);
  });
  tearDown(() async {
    await getIt.reset();
    AppText.useLanguage('ar');
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 800),
        builder: (_, _) => const MaterialApp(
          home: Scaffold(body: FormulationsScreen(initialId: 1)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'an active formula deep link opens; source failure prevents stale saving',
    (tester) async {
      when(
        () => repo.receipts(any(), any(), any()),
      ).thenThrow(StateError('source failed'));
      await open(tester);
      expect(find.text('Edit formulation'), findsOneWidget);
      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, 'Save'))
            .onPressed,
        isNull,
      );
      verifyNever(() => repo.save(any(), id: any(named: 'id')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed save retains the editor and the entered formula for correction',
    (tester) async {
      when(() => repo.receipts(any(), any(), any())).thenAnswer(
        (_) async => [
          MaterialReceipt(
            materialId: 1,
            code: 'R1',
            receivedAt: DateTime(2026, 1, 15),
            source: 'inspection',
            values: const {'protein': 20},
          ),
        ],
      );
      when(
        () => repo.save(any(), id: any(named: 'id')),
      ).thenThrow(const ValidationError('Please correct the formula'));
      await open(tester);
      await tester.tap(find.widgetWithText(AppButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Edit formulation'), findsOneWidget);
      // The page beneath the dialog now carries its own AppTextField (search),
      // so the name field must be scoped to the editor window.
      final name = tester.widget<AppTextField>(
        find.descendant(
          of: find.byType(AppWindow),
          matching: find.byType(AppTextField),
        ).first,
      );
      expect(name.controller!.text, 'Starter');
      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, 'Save'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
