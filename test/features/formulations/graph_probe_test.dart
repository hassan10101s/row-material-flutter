import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/design_system/tokens/app_colors.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/formulations/domain/formulation_repository.dart';
import 'package:material_lab/features/formulations/presentation/formulations_screen.dart';

class _Repo extends Mock implements FormulationRepository {}

class _Gate extends Mock implements AuthGate {}

void main() {
  setUpAll(() {
    registerFallbackValue(Permission.orgRead);
    registerFallbackValue(<String, dynamic>{});
  });
  setUp(() {
    AppText.useLanguage('en');
    final repo = _Repo();
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
                'parameters_json':
                    '{"period":"month","from":"2026-01-15","aggregation":"mode","chart_interval":"week"}',
              },
            ],
    );
    when(repo.materials).thenAnswer((_) async => []);
    when(repo.products).thenAnswer((_) async => []);
    when(repo.parameters).thenAnswer((_) async => []);
    getIt.registerSingleton<FormulationRepository>(repo);
    getIt.registerSingleton<AuthGate>(gate);
  });
  tearDown(() async {
    AppColors.brightness = Brightness.light;
    FormFactor.debugSet(null);
    await getIt.reset();
    AppText.useLanguage('ar');
  });

  testWidgets(
    'the phone opens a saved formulation graph after leaving the editor',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(390, 900),
          builder: (_, _) => const MaterialApp(
            home: Scaffold(body: FormulationsScreen(initialId: 1)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Starter'), findsOneWidget);
      final graph = find.byTooltip('Open the graph');
      expect(graph, findsOneWidget);
      await tester.ensureVisible(graph);
      await tester.tap(graph);
      await tester.pumpAndSettle();
      expect(find.text('Formulation graph'), findsOneWidget);
    },
  );
}
