import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';
import 'package:material_lab/design_system/widgets/app_text_field.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/lab/presentation/analyses/analysis_editor.dart';
import 'package:material_lab/features/lab/presentation/analyses/analysis_field_config_editor.dart';

class _Config extends Mock implements LabConfigurationRepository {}

class _Stock extends Mock implements LabLocalRepository {}

class _Reference extends Mock implements ReferenceRepository {}

class _Results extends Mock implements LabResultRepository {}

void main() {
  late _Config config;
  late _Results results;
  setUp(() {
    config = _Config();
    results = _Results();
    final stock = _Stock(), reference = _Reference();
    when(() => stock.listInventory()).thenAnswer(
      (_) async => [
        {'id': 1, 'name': 'HCl', 'unit': 'mL', 'category': 'volume'},
      ],
    );
    when(() => stock.listUnitSymbols()).thenAnswer((_) async => ['mL']);
    when(() => reference.listParameters()).thenAnswer((_) async => []);
    when(
      () => results.hasCompletedResultsForAnalysis(any()),
    ).thenAnswer((_) async => false);
    getIt.registerSingleton<LabConfigurationRepository>(config);
    getIt.registerSingleton<LabResultRepository>(results);
    getIt.registerSingleton<LabLocalRepository>(stock);
    getIt.registerSingleton<ReferenceRepository>(reference);
  });
  tearDown(() async {
    FormFactor.debugSet(null);
    AppText.useLanguage('ar');
    await getIt.reset();
  });

  Future<void> host(
    WidgetTester tester,
    bool mobile, {
    bool arabic = false,
    GlobalKey<AnalysisEditorState>? key,
  }) async {
    AppText.useLanguage(arabic ? 'ar' : 'en');
    FormFactor.debugSet(mobile ? AppFormFactor.mobile : AppFormFactor.desktop);
    final size = mobile ? const Size(390, 844) : const Size(1280, 900);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: size,
        builder: (_, _) => MaterialApp(
          builder: (_, child) => Directionality(
            textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: AnalysisEditor(
                key: key,
                analysis: {
                  'id': 1,
                  'name': 'Protein',
                  'unit': '%',
                  'dynamic_fields': ['Titre'],
                  'formula': {'expression': ''},
                  'items': <Object>[],
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openList(WidgetTester tester) async {
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Value list'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Value list'));
    await tester.pumpAndSettle();
  }

  for (final mobile in [true, false]) {
    for (final arabic in [true, false]) {
      testWidgets(
        '${mobile ? 'phone' : 'desktop'} field sources share one row (${arabic ? 'Arabic' : 'English'})',
        (tester) async {
          await host(tester, mobile, arabic: arabic);
          final chips = find.byType(ChoiceChip);
          expect(chips, findsNWidgets(3));
          final rects = [
            for (var i = 0; i < 3; i++) tester.getRect(chips.at(i)),
          ];
          expect(rects[0].width, closeTo(rects[1].width, 0.1));
          expect(rects[1].width, closeTo(rects[2].width, 0.1));
          expect(rects[0].center.dy, closeTo(rects[2].center.dy, 0.1));
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '${mobile ? 'phone' : 'desktop'} lists start empty and Cancel preserves the previous values',
      (tester) async {
        await host(tester, mobile);
        await openList(tester);
        expect(find.byType(Dialog), mobile ? findsNothing : findsOneWidget);
        final inputs = find.descendant(
          of: find.byType(AnalysisFieldConfigEditor),
          matching: find.byType(InputChip),
        );
        expect(inputs, findsNothing);
        await tester.enterText(
          find.descendant(
            of: find.byType(AnalysisFieldConfigEditor),
            matching: find.byType(TextField),
          ),
          '7.5',
        );
        await tester.tap(find.widgetWithText(AppButton, 'Apply'));
        await tester.pumpAndSettle();
        expect(find.byType(AnalysisFieldConfigEditor), findsNothing);
        expect(find.text('List (1)'), findsOneWidget);
        expect(find.text('New value'), findsNothing);
        await openList(tester);
        expect(find.widgetWithText(InputChip, '7.5'), findsOneWidget);
        await tester.enterText(
          find.descendant(
            of: find.byType(AnalysisFieldConfigEditor),
            matching: find.byType(TextField),
          ),
          '9',
        );
        await tester.tap(
          find.descendant(
            of: find.byType(AnalysisFieldConfigEditor),
            matching: find.widgetWithText(AppButton, 'Add'),
          ),
        );
        await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
        await tester.pumpAndSettle();
        await openList(tester);
        expect(find.widgetWithText(InputChip, '7.5'), findsOneWidget);
        expect(find.widgetWithText(InputChip, '9'), findsNothing);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('List (1)'), findsOneWidget);
        verifyZeroInteractions(config);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${mobile ? 'phone' : 'desktop'} cancelling a different source keeps manual entry',
      (tester) async {
        await host(tester, mobile);
        await tester.ensureVisible(
          find.widgetWithText(ChoiceChip, 'Fixed value'),
        );
        await tester.tap(find.widgetWithText(ChoiceChip, 'Fixed value'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.descendant(
            of: find.byType(AnalysisFieldConfigEditor),
            matching: find.byType(TextField),
          ),
          '15',
        );
        await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widgetList<ChoiceChip>(find.byType(ChoiceChip))
              .any((chip) => chip.selected),
          isFalse,
        );
        expect(find.text('Entered manually during the test'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('adding a field with completed records offers a new analysis', (
    tester,
  ) async {
    final key = GlobalKey<AnalysisEditorState>();
    await host(tester, false, key: key);
    when(
      () => results.hasCompletedResultsForAnalysis(1),
    ).thenAnswer((_) async => true);
    when(() => config.analysisNameExists(any())).thenAnswer((_) async => false);
    when(
      () => config.createAnalysis(
        name: any(named: 'name'),
        description: any(named: 'description'),
        reference: any(named: 'reference'),
        dynamicFields: any(named: 'dynamicFields'),
        items: any(named: 'items'),
        unit: any(named: 'unit'),
        parameterId: any(named: 'parameterId'),
        formula: any(named: 'formula'),
        fieldChemicalLinks: any(named: 'fieldChemicalLinks'),
      ),
    ).thenAnswer((_) async => {});
    final newField = find.descendant(
      of: find.ancestor(
        of: find.text('Add a field...'),
        matching: find.byType(AppTextField),
      ),
      matching: find.byType(TextField),
    );
    await tester.enterText(newField, 'Moisture');
    await tester.tap(find.widgetWithText(AppButton, 'Add'));
    await tester.pumpAndSettle();
    final saving = key.currentState!.save();
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Completed test records are linked'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(AppButton, 'Create new analysis'));
    await tester.pumpAndSettle();
    await saving;
    verify(
      () => config.createAnalysis(
        name: 'Protein (copy)',
        description: '',
        reference: '',
        dynamicFields: ['Titre', 'Moisture'],
        items: any(named: 'items'),
        unit: '%',
        parameterId: null,
        formula: any(named: 'formula'),
        fieldChemicalLinks: any(named: 'fieldChemicalLinks'),
      ),
    ).called(1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renaming a field does not show the structural warning', (
    tester,
  ) async {
    final key = GlobalKey<AnalysisEditorState>();
    await host(tester, false, key: key);
    when(
      () => results.hasCompletedResultsForAnalysis(1),
    ).thenAnswer((_) async => true);
    when(
      () => config.updateAnalysis(
        analysisId: any(named: 'analysisId'),
        name: any(named: 'name'),
        description: any(named: 'description'),
        reference: any(named: 'reference'),
        dynamicFields: any(named: 'dynamicFields'),
        items: any(named: 'items'),
        unit: any(named: 'unit'),
        parameterId: any(named: 'parameterId'),
        clearParameter: any(named: 'clearParameter'),
        formula: any(named: 'formula'),
        fieldChemicalLinks: any(named: 'fieldChemicalLinks'),
      ),
    ).thenAnswer((_) async => {});
    final field = find.descendant(
      of: find.ancestor(
        of: find.text('Field name 1'),
        matching: find.byType(AppTextField),
      ),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'Titre renamed');
    await key.currentState!.save();
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Completed test records are linked'),
      findsNothing,
    );
    verify(
      () => config.updateAnalysis(
        analysisId: 1,
        name: 'Protein',
        description: '',
        reference: '',
        dynamicFields: ['Titre renamed'],
        items: any(named: 'items'),
        unit: '%',
        parameterId: null,
        clearParameter: false,
        formula: '',
        fieldChemicalLinks: any(named: 'fieldChemicalLinks'),
      ),
    ).called(1);
    expect(tester.takeException(), isNull);
  });
}
