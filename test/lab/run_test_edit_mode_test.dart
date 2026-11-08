import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';
import 'package:material_lab/design_system/widgets/app_entity_autocomplete.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/run_test_cubit.dart';
import 'package:material_lab/features/lab/presentation/run_test/run_test_tab.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/design_system/widgets/app_text_field.dart';

class _WarningGate extends Mock implements AuthGate {}

class _MockConfig extends Mock implements LabConfigurationRepository {}

class _MockLocal extends Mock implements LabLocalRepository {}

class _MockResults extends Mock implements LabResultRepository {}

/// Regression test for the request: editing a test from the history must use
/// the *same* field widgets as the add form — list fields become dropdowns,
/// fixed-value fields become read-only, and the analysis/source stay fixed
/// (only the sample remains editable).
void main() {
  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'phone product' : 'desktop raw'} lab result warns using its own upper bound and still saves',
      (tester) async {
        AppText.useLanguage('en');
        FormFactor.debugSet(
          mobile ? AppFormFactor.mobile : AppFormFactor.desktop,
        );
        addTearDown(() => FormFactor.debugSet(null));
        final gate = _WarningGate();
        when(() => gate.currentUser).thenReturn(null);
        getIt.registerSingleton<AuthGate>(gate);
        addTearDown(() => getIt.unregister<AuthGate>());
        final size = mobile ? const Size(390, 844) : const Size(1280, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final config = _MockConfig(),
            local = _MockLocal(),
            results = _MockResults();
        when(config.listAnalyses).thenAnswer(
          (_) async => [
            {'id': 5, 'name': 'Moisture', 'unit': '%'},
          ],
        );
        when(config.listProducts).thenAnswer((_) async => []);
        when(local.listInspectionMaterials).thenAnswer((_) async => []);
        final records = <Map<String, dynamic>>[
          {
            'id': 22,
            'entry_code': 'EC-22',
            'material_name': 'Target',
            'sample_names': ['S1'],
            'chemical_reference_json': '{"Moisture":{"max":14}}',
          },
        ];
        when(
          () => local.listInspectionRecords(4),
        ).thenAnswer((_) async => records);
        when(
          () => local.listProductInspectionRecords(4),
        ).thenAnswer((_) async => records);
        when(
          () => results.updateSampleTest(
            1,
            sampleName: any(named: 'sampleName'),
            resultText: any(named: 'resultText'),
            dynamicValues: any(named: 'dynamicValues'),
            user: any(named: 'user'),
          ),
        ).thenAnswer((_) async => {});
        final row = <String, dynamic>{
          'id': 1,
          'analysis_id': 5,
          'source_type': mobile ? 'product' : 'raw_material',
          'source_ref_id': 4,
          'source_name': 'Target',
          'sample_name': 'S1',
          'result_text': '6.5',
          'entry_code': 'EC-22',
        };
        final cubit = RunTestCubit(
          config: config,
          results: results,
          local: local,
          editRow: row,
        );
        addTearDown(cubit.close);
        await cubit.load();
        var saved = false;
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: size,
            builder: (_, _) => MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => AppButton(
                    label: 'Open result',
                    onPressed: () => showAppContent<bool>(
                      context,
                      title: 'Result editor',
                      height: 780,
                      builder: (_, _) => BlocProvider.value(
                        value: cubit,
                        child: SingleChildScrollView(
                          child: RunTestTab(
                            editRow: row,
                            onTestRun: () => saved = true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open result'));
        await tester.pumpAndSettle();
        final input = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Result',
        );
        await tester.ensureVisible(input);
        await tester.enterText(input, '28');
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Are you sure about Moisture:'),
          findsNothing,
        );
        final result = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Result',
        );
        await tester.enterText(result, '30');
        await tester.pumpAndSettle();
        expect(find.text('Are you sure about Moisture: 30?'), findsOneWidget);
        final save = find.widgetWithText(AppButton, 'Save changes');
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        verify(
          () => results.updateSampleTest(
            1,
            sampleName: 'S1',
            resultText: '30',
            dynamicValues: any(named: 'dynamicValues'),
            user: any(named: 'user'),
          ),
        ).called(1);
        expect(saved, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'new analysis is empty; failure toggle keeps numeric quantities',
    (tester) async {
      AppText.useLanguage('en');
      FormFactor.debugSet(AppFormFactor.desktop);
      addTearDown(() => FormFactor.debugSet(null));
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final config = _MockConfig(),
          local = _MockLocal(),
          results = _MockResults();
      when(() => config.listAnalyses()).thenAnswer(
        (_) async => [
          {
            'id': 5,
            'name': 'Weight test',
            'unit': '%',
            'formula': {'expression': 'Weight / Volume'},
            'dynamic_fields': ['Weight', 'Volume'],
          },
        ],
      );
      when(() => config.listProducts()).thenAnswer((_) async => []);
      when(() => local.listInspectionMaterials()).thenAnswer((_) async => []);
      final cubit = RunTestCubit(
        config: config,
        results: results,
        local: local,
      );
      addTearDown(cubit.close);
      await cubit.load();
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(1280, 1000),
          builder: (_, _) => MaterialApp(
            home: Scaffold(
              body: BlocProvider.value(
                value: cubit,
                child: SingleChildScrollView(
                  child: RunTestTab(onTestRun: () {}),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(cubit.state.analysisId, isNull);
      expect(
        tester
            .widget<AppEntityAutocomplete>(
              find.byType(AppEntityAutocomplete).first,
            )
            .selectedId,
        isNull,
      );
      cubit.selectAnalysis(5);
      await tester.pumpAndSettle();
      final weight = find.byWidgetPredicate(
        (w) =>
            w is AppTextField &&
            w.decoration.labelText == 'Dynamic value: Weight',
      );
      await tester.ensureVisible(weight);
      await tester.enterText(weight, '٣٫٥');
      await tester.enterText(weight, 'bad');
      expect(tester.widget<AppTextField>(weight).controller!.text, '3.5');
      final toggle = find.byKey(const ValueKey('failed-sample-toggle'));
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('failed-result-label')), findsOneWidget);
      expect(find.text('Failure'), findsNWidgets(2));
      expect(tester.widget<AppTextField>(weight).controller!.text, '3.5');
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'phone back' : 'desktop close'} protects edited test values and never saves discarded data',
      (tester) async {
        AppText.useLanguage('en');
        FormFactor.debugSet(
          mobile ? AppFormFactor.mobile : AppFormFactor.desktop,
        );
        addTearDown(() => FormFactor.debugSet(null));
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final config = _MockConfig(),
            local = _MockLocal(),
            results = _MockResults();
        when(() => config.listAnalyses()).thenAnswer(
          (_) async => [
            {'id': 5, 'name': 'pH', 'unit': 'pH'},
          ],
        );
        when(() => config.listProducts()).thenAnswer((_) async => []);
        when(() => local.listInspectionMaterials()).thenAnswer((_) async => []);
        when(() => local.listInspectionRecords(4)).thenAnswer((_) async => []);
        final row = <String, dynamic>{
          'id': 1,
          'analysis_id': 5,
          'source_type': 'raw_material',
          'source_ref_id': 4,
          'source_name': 'Raw sugar',
          'sample_name': 'S1',
          'result_text': '6.5',
        };
        final cubit = RunTestCubit(
          config: config,
          results: results,
          local: local,
          editRow: row,
        );
        await cubit.load();
        addTearDown(cubit.close);
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: mobile ? const Size(390, 844) : const Size(1280, 900),
            builder: (_, _) => MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    child: const Text('open'),
                    onPressed: () => showAppContent<bool>(
                      context,
                      title: 'Test editor',
                      maxWidth: 1040,
                      height: 780,
                      builder: (_, _) => BlocProvider.value(
                        value: cubit,
                        child: SingleChildScrollView(
                          child: RunTestTab(editRow: row, onTestRun: () {}),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final input = find.byType(AppTextField).last;
        await tester.ensureVisible(input);
        await tester.enterText(input, '7.25');
        await tester.pump();
        Future<void> back() async {
          await tester.tap(
            mobile ? find.byType(BackButton) : find.byIcon(Icons.close).first,
          );
          await tester.pumpAndSettle();
        }

        await back();
        expect(find.text('Discard changes?'), findsOneWidget);
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        expect(find.text('7.25'), findsOneWidget);
        await back();
        await tester.tap(find.text('Discard and leave'));
        await tester.pumpAndSettle();
        expect(find.text('Test editor'), findsNothing);
        expect(tester.takeException(), isNull);
        verifyNoMoreInteractions(results);
      },
    );
  }
  testWidgets('edit mode reuses the add fields with fixed analysis/source', (
    tester,
  ) async {
    AppText.arabic = true;
    final config = _MockConfig();
    final local = _MockLocal();
    final results = _MockResults();
    when(() => config.listAnalyses()).thenAnswer(
      (_) async => [
        {
          'id': 5,
          'name': 'pH',
          'unit': 'pH',
          'dynamic_fields': ['Brix', 'Color', 'Moisture'],
          'field_chemical_links': [
            {'dynamic_field': 'Brix', 'kind': 'value', 'fixed_value': 5},
            {
              'dynamic_field': 'Color',
              'kind': 'list',
              'list_values': ['Red', 'Green'],
            },
            {'dynamic_field': 'Moisture', 'kind': 'link'},
          ],
        },
      ],
    );
    when(() => config.listProducts()).thenAnswer((_) async => []);
    when(() => local.listInspectionMaterials()).thenAnswer((_) async => []);
    when(() => local.listInspectionRecords(4)).thenAnswer(
      (_) async => [
        {
          'id': 22,
          'entry_code': 'EC-22',
          'material_id': 4,
          'material_name': 'Raw sugar',
          'sample_names': ['S1', 'S2'],
        },
      ],
    );

    final editRow = <String, dynamic>{
      'id': 1,
      'analysis_id': 5,
      'source_type': 'raw_material',
      'source_ref_id': 4,
      'source_name': 'Raw sugar',
      'sample_name': 'S2',
      'result_text': '6.5',
      'entry_code': 'EC-22',
      'dynamic_values': {'Color': 'Green', 'Moisture': '12'},
    };
    final cubit = RunTestCubit(
      config: config,
      results: results,
      local: local,
      editRow: editRow,
    );
    await cubit.load();

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 800),
        builder: (context, _) => MaterialApp(
          home: Scaffold(
            body: BlocProvider.value(
              value: cubit,
              child: SingleChildScrollView(
                child: RunTestTab(onTestRun: () {}, editRow: editRow),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Analysis/material/record pickers are gone — only the sample picker
    // stays (analysis and source are history while editing).
    expect(find.byType(AppEntityAutocomplete), findsOneWidget);
    // The list field is a dropdown; the fixed-value field has no input.
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    // The source is shown fixed (not an editable picker).
    expect(find.textContaining('Raw sugar'), findsWidgets);
    // Stored list selection and fixed value both render.
    expect(find.text('Green'), findsWidgets);
    // Fixed values are shown to at most 3 decimals, trailing zeros trimmed.
    expect(find.text('5'), findsWidgets);
    // The sample stays editable and shows the stored value.
    expect(find.text('S2'), findsWidgets);

    await cubit.close();
  });
}
