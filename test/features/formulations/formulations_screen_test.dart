import 'dart:convert';
import 'dart:io';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/features/formulations/presentation/formulation_view_prefs.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/commands/central_authoring_gateway.dart';
import 'package:material_lab/core/sync/sync_data_changes.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';
import 'package:material_lab/design_system/widgets/app_text_field.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/design_system/widgets/app_info_button.dart';
import 'package:material_lab/design_system/tokens/app_colors.dart';
import 'package:material_lab/design_system/widgets/app_summary_card.dart';
import 'package:material_lab/design_system/widgets/app_select_field.dart';
import 'dart:async';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/formulations/domain/formulation_calculator.dart';
import 'package:material_lab/features/formulations/domain/formulation_timeline.dart';
import 'package:material_lab/features/formulations/domain/formulation_repository.dart';
import 'package:material_lab/features/formulations/presentation/formulations_screen.dart';

class _ViewPaths extends AppPaths {
  _ViewPaths(this.directory);
  final Directory directory;
  @override
  Future<Directory> orgRoot(String? orgId) async => directory;
}

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
    when(
      () => repo.materialIdsWithReceipts(any()),
    ).thenAnswer((_) async => {1});
    getIt.registerSingleton<FormulationRepository>(repo);
    getIt.registerSingleton<AuthGate>(gate);
  });
  tearDown(() async {
    AppColors.brightness = Brightness.light;
    FormFactor.debugSet(null);
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

  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'phone' : 'desktop'} adds existing analyses from a fresh searchable catalogue',
      (tester) async {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('parameter_picker_'),
        ))!;
        getIt.registerSingleton<AppPaths>(_ViewPaths(directory));
        Future<void> flushPreferences() async {
          var finished = false;
          unawaited(FormulationViewPrefs.load(1).then((_) => finished = true));
          for (var attempt = 0; attempt < 500 && !finished; attempt++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          expect(finished, isTrue);
        }

        FormFactor.debugSet(
          mobile ? AppFormFactor.mobile : AppFormFactor.desktop,
        );
        final size = mobile ? const Size(390, 844) : const Size(1280, 900);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var catalogue = <Map<String, dynamic>>[];
        when(repo.parameters).thenAnswer((_) async => catalogue);
        when(() => repo.receipts(any(), any(), any())).thenAnswer(
          (_) async => [
            MaterialReceipt(
              materialId: 1,
              code: 'R1',
              receivedAt: DateTime(2026, 1, 15),
              source: 'inspection',
              values: const {'protein': 30, 'ash': 7, 'density': 1},
              physicalKeys: const {'density'},
            ),
          ],
        );
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: size,
            builder: (_, _) => const MaterialApp(
              home: Scaffold(body: FormulationsScreen(initialId: 1)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          mobile ? find.byType(BackButton) : find.byTooltip('Close'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.query_stats));
        await tester.pumpAndSettle();
        await flushPreferences();
        await tester.pumpAndSettle();
        // These definitions appeared after the graph had already opened.
        catalogue = [
          {'parameter_name': 'Ash'},
          {'parameter_name': 'Calcium'},
          {'parameter_name': 'Density'},
        ];
        Future<void> settings() async {
          final button = find.widgetWithText(AppButton, 'Analysis settings');
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pumpAndSettle();
        }

        Finder option(String key) =>
            find.byKey(ValueKey('formulation-parameter-$key'));
        await settings();
        expect(option('density'), findsNothing);
        expect(option('ash'), findsOneWidget);
        expect(
          find.descendant(
            of: option('ash'),
            matching: find.text('No complete points for the current period'),
          ),
          findsNothing,
        );
        expect(
          find.descendant(
            of: option('calcium'),
            matching: find.text('No complete points for the current period'),
          ),
          findsOneWidget,
        );
        final search = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == 'Search analyses',
        );
        await tester.enterText(search, 'Calcium');
        await tester.pumpAndSettle(const Duration(milliseconds: 400));
        expect(option('ash'), findsNothing);
        await tester.tap(option('calcium'));
        await tester.tap(find.widgetWithText(AppButton, 'Apply'));
        await tester.pumpAndSettle();
        await settings();
        expect(
          tester.widget<CheckboxListTile>(option('calcium')).value,
          isTrue,
        );
        await tester.tap(option('calcium'));
        await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
        await tester.pumpAndSettle();
        await settings();
        expect(
          tester.widget<CheckboxListTile>(option('calcium')).value,
          isTrue,
        );
        await tester.tap(option('ash'));
        await tester.tap(find.widgetWithText(AppButton, 'Apply'));
        await tester.pumpAndSettle();
        final chart = tester.widget<LineChart>(find.byType(LineChart));
        expect(
          chart.data.lineBarsData.any(
            (bar) => bar.spots.any((spot) => spot.y == 7),
          ),
          isTrue,
        );
        verifyNever(() => repo.save(any(), id: any(named: 'id')));
        expect(tester.takeException(), isNull);
        await tester.tap(
          mobile ? find.byType(BackButton) : find.byTooltip('Close'),
        );
        await tester.pumpAndSettle();
        await flushPreferences();
        final prefs = await tester.runAsync(() => FormulationViewPrefs.load(1));
        expect(prefs?['graph'], containsAll(['protein', 'ash', 'calcium']));
        await tester.runAsync(() => directory.delete(recursive: true));
      },
    );
  }

  testWidgets('graph filters survive reopening without a business save', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.desktop);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('graph_view_'),
    ))!;
    getIt.registerSingleton<AppPaths>(_ViewPaths(directory));
    when(() => repo.receipts(any(), any(), any())).thenAnswer(
      (_) async => [
        MaterialReceipt(
          materialId: 1,
          code: 'R1',
          receivedAt: DateTime(2026, 1, 15),
          source: 'inspection',
          values: const {'protein': 30, 'fat': 12},
        ),
      ],
    );
    await open(tester);
    expect(find.byType(LineChart), findsNothing);
    expect(find.text('Period'), findsNothing);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();

    Future<void> flushPreferences() async {
      var finished = false;
      unawaited(FormulationViewPrefs.load(1).then((_) => finished = true));
      for (var attempt = 0; attempt < 500 && !finished; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(finished, isTrue, reason: 'View preferences should finish saving');
    }

    Future<void> openGraph() async {
      await tester.tap(find.byIcon(Icons.query_stats));
      await tester.pumpAndSettle();
      await flushPreferences();
      await tester.pumpAndSettle();
    }

    await openGraph();
    expect(find.widgetWithText(AppButton, 'Save'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppWindow),
        matching: find.byType(AppTextField),
      ),
      findsNothing,
    );
    expect(find.byTooltip('Formulation ingredients'), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byTooltip('Zoom in'), findsNothing);
    expect(find.byTooltip('Zoom out'), findsNothing);
    await tester.ensureVisible(find.text('Max'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Max'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsNothing);
    await openGraph();
    expect(
      tester
          .widget<SegmentedButton<FormulationAggregation>>(
            find.byType(SegmentedButton<FormulationAggregation>),
          )
          .selected,
      {FormulationAggregation.maximum},
    );
    verifyNever(() => repo.save(any(), id: any(named: 'id')));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await flushPreferences();
    await tester.runAsync(() => directory.delete(recursive: true));
  });

  testWidgets(
    'phone delete asks for confirmation and only deletes the selected formula',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      when(() => repo.delete(1)).thenAnswer((_) async {});
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(400, 860),
          builder: (_, _) =>
              const MaterialApp(home: Scaffold(body: FormulationsScreen())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Delete formulation'));
      await tester.pumpAndSettle();
      expect(find.text('Delete formulation?'), findsOneWidget);
      verifyNever(() => repo.delete(any()));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(() => repo.delete(any()));
      await tester.tap(find.byTooltip('Delete formulation'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      verify(() => repo.delete(1)).called(1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone daily lab-only graph opens, switches sources and handles chart taps',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      when(() => repo.list(archived: any(named: 'archived'))).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'name': 'Daily lab only',
            'items_json':
                '[{"material_id":1,"material_name":"Maize","quantity_kg":100}]',
            'parameters_json':
                '{"period":"month","from":"2026-01-01","chart_interval":"day","data_source":"lab"}',
            'graph_parameters_json': '["protein","fat"]',
          },
        ],
      );
      var reads = 0;
      when(() => repo.receipts(any(), any(), any())).thenAnswer((_) async {
        reads++;
        return [
          MaterialReceipt(
            materialId: 1,
            code: 'R1',
            receivedAt: DateTime(2026, 1, 1),
            source: 'lab',
            values: const {'protein': 12},
            inspectionValues: const {'protein': 10, 'fat': 5},
            labHistory: {
              'protein': [
                ParameterObservation(
                  sample: 'A',
                  at: DateTime(2026, 1, 10),
                  value: 12,
                ),
                ParameterObservation(
                  sample: 'A',
                  at: DateTime(2026, 1, 15),
                  value: null,
                ),
                ParameterObservation(
                  sample: 'A',
                  at: DateTime(2026, 1, 20),
                  value: 14,
                ),
              ],
            },
          ),
        ];
      });
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(400, 860),
          builder: (_, _) =>
              const MaterialApp(home: Scaffold(body: FormulationsScreen())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open the graph'));
      await tester.pump();
      Future<void> finishTracking() async {
        for (var attempt = 0; attempt < 500; attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        }
        await tester.pumpAndSettle();
      }

      await finishTracking();
      expect(find.byType(LineChart), findsOneWidget);
      final readsAtOpen = reads;
      for (final source in [
        FormulationDataSource.all,
        FormulationDataSource.lab,
        FormulationDataSource.nir,
        FormulationDataSource.lab,
      ]) {
        tester
            .widget<AppSelectField<FormulationDataSource>>(
              find.byKey(const ValueKey('formulation-data-source')),
            )
            .onChanged!(source);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        await finishTracking();
        final chart = find.byType(LineChart);
        await tester.ensureVisible(chart);
        await tester.tap(chart);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      expect(reads, readsAtOpen);
      verifyNever(() => repo.save(any(), id: any(named: 'id')));
    },
  );

  testWidgets('rapid daily Min and Max changes keep the newest worker result', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.desktop);
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    when(() => repo.list(archived: any(named: 'archived'))).thenAnswer(
      (_) async => [
        {
          'id': 1,
          'name': 'Daily stress',
          'items_json':
              '[{"material_id":1,"material_name":"Maize","quantity_kg":100}]',
          'parameters_json':
              '{"period":"year","from":"2026-01-01","chart_interval":"day"}',
          'graph_parameters_json': '["protein"]',
        },
      ],
    );
    var reads = 0;
    when(() => repo.receipts(any(), any(), any())).thenAnswer((_) async {
      reads++;
      return [
        for (var i = 0; i < 300; i++)
          MaterialReceipt(
            materialId: 1,
            code: 'R$i',
            receivedAt: DateTime(2025, 1, i + 1),
            source: 'inspection',
            values: {'protein': 10 + (i % 30).toDouble()},
          ),
      ];
    });
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 1000),
        builder: (_, _) =>
            const MaterialApp(home: Scaffold(body: FormulationsScreen())),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.query_stats));
    await tester.pump();
    await tester.pump();
    await tester.ensureVisible(find.text('Min'));
    await tester.tap(find.text('Min'));
    await tester.pump();
    await tester.tap(find.text('Max'));
    await tester.pump();
    expect(
      tester
          .widget<SegmentedButton<FormulationAggregation>>(
            find.byType(SegmentedButton<FormulationAggregation>),
          )
          .selected,
      {FormulationAggregation.maximum},
    );

    Future<void> finishWorker() async {
      for (var i = 0; i < 500; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      }
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpAndSettle();
    }

    await finishWorker();
    List<double> values() => tester
        .widget<LineChart>(find.byType(LineChart))
        .data
        .lineBarsData
        .first
        .spots
        .map((spot) => spot.y)
        .toList();
    expect(values().length, greaterThan(30));
    expect(
      tester.widget<LineChart>(find.byType(LineChart)).duration,
      Duration.zero,
    );
    expect(values().every((value) => value == 39), true);
    final readsAfterLoad = reads;
    for (final label in ['Min', 'Max', 'Min', 'Max']) {
      await tester.tap(find.text(label));
      await tester.pump();
      await finishWorker();
      expect(
        values().every((value) => value == (label == 'Max' ? 39 : 10)),
        true,
      );
    }
    expect(reads, readsAfterLoad);
    verifyNever(() => repo.save(any(), id: any(named: 'id')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a later maize source fills every historical chart bucket with marked provenance',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.desktop);
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      when(() => repo.list(archived: any(named: 'archived'))).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'name': 'Historical maize',
            'items_json':
                '[{"material_id":1,"material_name":"Maize","quantity_kg":50},{"material_id":2,"material_name":"Soy","quantity_kg":50}]',
            'parameters_json':
                '{"period":"month","from":"2020-01-15","chart_interval":"day"}',
            'graph_parameters_json': '["protein"]',
          },
        ],
      );
      when(() => repo.receipts(any(), any(), any())).thenAnswer((call) async {
        final through = call.positionalArguments[2] as DateTime;
        return [
          MaterialReceipt(
            materialId: 2,
            code: 'SOY',
            receivedAt: DateTime(2019, 12, 1),
            source: 'inspection',
            values: const {'protein': 40},
          ),
          if (!through.isBefore(DateTime(2020, 2, 10)))
            MaterialReceipt(
              materialId: 1,
              code: 'MAIZE-LATER',
              receivedAt: DateTime(2020, 2, 10),
              source: 'inspection',
              values: const {'protein': 10},
            ),
        ];
      });
      await open(tester);
      // The chart lives on the read-only graph page now: leave the editing
      // window and open the graph view of the same formulation.
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.query_stats));
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(
            of: find.byType(AppWindow),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byType(LineChart),
        180,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      final chart = tester.widget<LineChart>(find.byType(LineChart));
      expect(chart.data.lineBarsData.first.spots, hasLength(31));
      expect(
        chart.data.lineBarsData.first.spots.every(
          (spot) => !spot.isNull() && spot.y == 25,
        ),
        isTrue,
      );
      final bar = chart.data.lineBarsData.first;
      final tooltip = chart.data.lineTouchData.touchTooltipData.getTooltipItems(
        [LineBarSpot(bar, 0, bar.spots.first)],
      ).first!;
      expect(tooltip.text, isNot(contains('Nearest later fallback')));
      expect(tooltip.text, isNot(contains('MAIZE-LATER')));
      expect(tooltip.text, contains('25'));
      verifyNever(() => repo.save(any(), id: any(named: 'id')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('phone shows one floating create plus and opens the editor', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.mobile);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(390, 844),
        builder: (_, _) => const MaterialApp(home: FormulationsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'New formulation'), findsNothing);
    await tester.tap(find.byTooltip('New formulation'));
    await tester.pumpAndSettle();
    expect(find.text('New formulation'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(BackButton), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'phone $width uses available field width and two compact metrics',
      (tester) async {
        FormFactor.debugSet(AppFormFactor.mobile);
        final size = Size(width, 844);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: size,
            builder: (_, _) => const MaterialApp(home: FormulationsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('New formulation'));
        await tester.pumpAndSettle();
        final fields = find.descendant(
          of: find.byType(AppWindow),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is AppSelectField &&
                widget is! AppSelectField<FormulationChartInterval> &&
                widget is! AppSelectField<FormulationDataSource>,
          ),
        );
        expect(fields, findsOneWidget);
        for (final field in fields.evaluate()) {
          expect(
            tester.getSize(find.byWidget(field.widget)).width,
            closeTo(width - 32, 1),
          );
        }
        await tester.scrollUntilVisible(
          find.byWidgetPredicate(
            (widget) => widget is AppSummaryCard && widget.label == 'Weight',
          ),
          180,
          scrollable: find
              .descendant(
                of: find.byType(AppWindow),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        final cards = find.byType(AppSummaryCard);
        expect(
          tester
              .widgetList<AppSummaryCard>(cards)
              .every((card) => card.compact),
          isTrue,
        );
        expect(
          tester.getTopLeft(cards.at(0)).dy,
          closeTo(tester.getTopLeft(cards.at(1)).dy, 1),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'phone $width card fits the long unavailable-reference pill it displays',
      (tester) async {
        FormFactor.debugSet(AppFormFactor.mobile);
        final size = Size(width, 844);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        when(
          () => repo.list(archived: any(named: 'archived')),
        ).thenAnswer((call) async {
          if (call.namedArguments[#archived] == true) return <Map<String, dynamic>>[];
          return [
            {
              'id': 2,
              'name': 'Long label regression',
              'items_json': jsonEncode(
                List.generate(12, (index) => {'material_id': index + 2}),
              ),
              'parameters_json': '{"period":"day"}',
              '_missing_references': true,
              'calculation_json': '{"total_kg":1234.5,"cost_per_kg":12.345}',
              'updated_at': '2026-01-15 10:00',
            },
          ];
        });
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: size,
            builder: (_, _) => const MaterialApp(home: FormulationsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        // The card truly displays both pills: the long unavailable-reference
        // label and the twelve-ingredient count.
        expect(
          find.text('A material or product is unavailable on this device'),
          findsOneWidget,
        );
        expect(find.text('12 ingredients'), findsOneWidget);
        final longPill = tester.widget<Text>(
          find.text('A material or product is unavailable on this device'),
        );
        expect(longPill.maxLines, 1);
        expect(longPill.overflow, TextOverflow.ellipsis);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'save waits for receipt then uses shared feedback above the page',
    (tester) async {
      when(() => repo.receipts(any(), any(), any())).thenAnswer(
        (_) async => [
          MaterialReceipt(
            materialId: 1,
            code: 'R1',
            receivedAt: DateTime(2026, 1, 15),
            source: 'inspection',
            values: const {'protein': 30},
          ),
        ],
      );
      final saved = Completer<int>();
      when(
        () => repo.save(any(), id: any(named: 'id')),
      ).thenAnswer((_) => saved.future);
      await open(tester);
      await tester.tap(find.widgetWithText(AppButton, 'Save'));
      await tester.pump();
      expect(find.text('Formulation saved'), findsNothing);
      saved.complete(1);
      await tester.pumpAndSettle();
      expect(find.text('Formulation saved'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(
        tester.getTopLeft(find.text('Formulation saved')).dy,
        lessThan(200),
      );
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'phone' : 'desktop'} protects a changed formulation on back and keeps input on cancel',
      (tester) async {
        FormFactor.debugSet(
          mobile ? AppFormFactor.mobile : AppFormFactor.desktop,
        );
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: mobile ? const Size(390, 844) : const Size(1280, 900),
            builder: (_, _) =>
                const MaterialApp(home: Scaffold(body: FormulationsScreen())),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          mobile
              ? find.byTooltip('New formulation')
              : find.widgetWithText(AppButton, 'New formulation'),
        );
        await tester.pumpAndSettle();
        final name = find
            .descendant(
              of: find.byType(AppWindow),
              matching: find.byType(AppTextField),
            )
            .first;
        await tester.enterText(name, 'Unsaved formulation');
        await tester.pump();
        Future<void> back() async {
          if (mobile) {
            await tester.tap(find.byType(BackButton));
          } else {
            await tester.tap(find.byIcon(Icons.close).first);
          }
          await tester.pumpAndSettle();
        }

        await back();
        expect(find.text('Discard changes?'), findsOneWidget);
        await tester.tap(find.text('Keep editing'));
        await tester.pumpAndSettle();
        expect(find.text('Unsaved formulation'), findsOneWidget);
        await back();
        await tester.tap(find.text('Discard and leave'));
        await tester.pumpAndSettle();
        expect(find.text('Unsaved formulation'), findsNothing);
        verifyNever(() => repo.save(any(), id: any(named: 'id')));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'phone ingredient analyses open on tap and material picker is a pushed page',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      when(repo.materials).thenAnswer(
        (_) async => [
          {'id': 1, 'material_name': 'Maize'},
          {'id': 2, 'material_name': 'Wheat'},
        ],
      );
      when(
        () => repo.receipts(any(), any(), any()),
      ).thenAnswer((_) async => []);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester);
      final info = find.byType(AppInfoButton);
      await tester.scrollUntilVisible(
        info,
        250,
        scrollable: find
            .descendant(
              of: find.byType(AppWindow),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await Scrollable.ensureVisible(tester.element(info), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(info);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.text('No valid analysis in this period', findRichText: true),
        findsOneWidget,
      );
      Tooltip.dismissAllToolTips();
      await tester.pumpAndSettle();
      final add = find.byIcon(Icons.add_circle_outline);
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('Choose raw material'), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Edit formulation'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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
        find
            .descendant(
              of: find.byType(AppWindow),
              matching: find.byType(AppTextField),
            )
            .first,
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

  testWidgets('hover shows the name and value beside each line', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.desktop);
    when(() => repo.receipts(any(), any(), any())).thenAnswer(
      (_) async => [
        MaterialReceipt(
          materialId: 1,
          code: 'R1',
          receivedAt: DateTime(2026, 1, 15),
          source: 'inspection',
          values: const {'protein': 30, 'fat': 12},
        ),
      ],
    );
    await open(tester);
    // Hover is a graph-page interaction: switch to the read-only view.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.query_stats));
    await tester.pumpAndSettle();
    final original = tester.widget<LineChart>(find.byType(LineChart));
    final bars = original.data.lineBarsData;
    expect(bars, hasLength(2));
    original.data.lineTouchData.touchCallback!(
      const FlPointerHoverEvent(PointerHoverEvent()),
      LineTouchResponse([
        for (var i = 0; i < bars.length; i++)
          TouchLineBarSpot(bars[i], i, bars[i].spots.first, 0),
      ]),
    );
    await tester.pump();
    final updated = tester.widget<LineChart>(find.byType(LineChart)).data;
    expect(updated.showingTooltipIndicators, hasLength(1));
    final labels = [
      for (final indicator in updated.showingTooltipIndicators)
        ...updated.lineTouchData.touchTooltipData
            .getTooltipItems(indicator.showingSpots)
            .map((item) => item!.text),
    ];
    expect(labels, containsAll(['Protein: 30', 'Fat: 12']));
    expect(tester.takeException(), isNull);
  });

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'phone ${brightness.name} keeps point values beside the chart and restores Mode plus weekly grouping',
      (tester) async {
        FormFactor.debugSet(AppFormFactor.mobile);
        AppColors.brightness = brightness;
        AppText.useLanguage('ar');
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        when(() => repo.list(archived: any(named: 'archived'))).thenAnswer(
          (_) async => [
            {
              'id': 1,
              'name': 'Starter',
              'items_json':
                  '[{"material_id":1,"material_name":"Maize","quantity_kg":100}]',
              'parameters_json':
                  '{"period":"month","from":"2026-01-15","aggregation":"mode","chart_interval":"week"}',
            },
          ],
        );
        when(() => repo.receipts(any(), any(), any())).thenAnswer(
          (_) async => [
            MaterialReceipt(
              materialId: 1,
              code: 'R1',
              receivedAt: DateTime(2026, 1, 10),
              source: 'inspection',
              values: const {'protein': 30, 'fat': 30.1},
            ),
          ],
        );
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: const Size(390, 900),
            builder: (_, _) => MaterialApp(
              theme: brightness == Brightness.dark
                  ? ThemeData.dark()
                  : ThemeData.light(),
              home: const Scaffold(body: FormulationsScreen(initialId: 1)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // The editing page no longer shows the chart: open the graph view.
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.byIcon(Icons.query_stats));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byType(LineChart),
          160,
          scrollable: find
              .descendant(
                of: find.byType(AppWindow),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        final chart = tester.widget<LineChart>(find.byType(LineChart));
        expect(chart.data.lineBarsData.first.spots, hasLength(6));
        expect(find.text('Mean'), findsOneWidget);
        expect(find.text('Min'), findsOneWidget);
        expect(find.text('Max'), findsOneWidget);
        expect(find.text('Mode'), findsOneWidget);
        expect(
          tester
              .widget<SegmentedButton<FormulationAggregation>>(
                find.byType(SegmentedButton<FormulationAggregation>),
              )
              .selected,
          {FormulationAggregation.mode},
        );
        final interval = tester
            .widget<AppSelectField<FormulationChartInterval>>(
              find.byKey(const ValueKey('formulation-chart-interval')),
            );
        expect(interval.initialValue, FormulationChartInterval.week);
        final bars = chart.data.lineBarsData;
        final index = bars.first.spots.indexWhere((spot) => !spot.isNull());
        chart.data.lineTouchData.touchCallback!(
          const FlPointerHoverEvent(PointerHoverEvent()),
          LineTouchResponse([
            for (var i = 0; i < bars.length; i++)
              TouchLineBarSpot(
                bars[i],
                i,
                bars[i].spots[index],
                index.toDouble(),
              ),
          ]),
        );
        await tester.pump();
        final updated = tester.widget<LineChart>(find.byType(LineChart));
        expect(updated.data.showingTooltipIndicators, isEmpty);
        final panel = find.byKey(const ValueKey('formulation-chart-readout'));
        expect(
          tester
              .getRect(panel)
              .overlaps(tester.getRect(find.byType(LineChart))),
          isFalse,
        );
        expect(
          find.descendant(of: panel, matching: find.text('30')),
          findsOneWidget,
        );
        final value = tester.widget<Text>(
          find.descendant(of: panel, matching: find.text('30')),
        );
        expect(value.style!.color, AppColors.textStrong);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a staged central request is shown as pending and cannot be submitted twice',
    (tester) async {
      when(() => repo.receipts(any(), any(), any())).thenAnswer(
        (_) async => [
          MaterialReceipt(
            materialId: 1,
            code: 'R1',
            receivedAt: DateTime(2026, 1, 15),
            source: 'inspection',
            values: const {'protein': 30},
          ),
        ],
      );
      when(
        () => repo.save(any(), id: any(named: 'id')),
      ).thenThrow(CentralDraftPending('draft-1'));
      await open(tester);
      await tester.tap(find.widgetWithText(AppButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('بانتظار تأكيد نتيجة العملية'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<AppButton>(find.widgetWithText(AppButton, 'Save'))
            .onPressed,
        isNull,
      );
      verify(() => repo.save(any(), id: 1)).called(1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a completed sync refreshes the list without closing the editor',
    (tester) async {
      when(() => repo.receipts(any(), any(), any())).thenAnswer(
        (_) async => [
          MaterialReceipt(
            materialId: 1,
            code: 'R1',
            receivedAt: DateTime(2026, 1, 15),
            source: 'inspection',
            values: const {'protein': 30},
          ),
        ],
      );
      await open(tester);
      clearInteractions(repo);
      SyncDataChanges.notify();
      await tester.pump();
      await tester.pumpAndSettle();
      verify(() => repo.list(archived: false)).called(1);
      expect(find.text('Edit formulation'), findsOneWidget);
    },
  );

  testWidgets(
    'ingredient picker opens before receipt loading and All stays usable',
    (tester) async {
      when(repo.materials).thenAnswer(
        (_) async => [
          {'id': 1, 'material_name': 'Maize'},
          {'id': 2, 'material_name': 'Soybeans'},
        ],
      );
      when(
        () => repo.receipts(any(), any(), any()),
      ).thenAnswer((_) async => []);
      final ids = Completer<Set<int>>();
      when(
        () => repo.materialIdsWithReceipts(any()),
      ).thenAnswer((_) => ids.future);
      await open(tester);
      clearInteractions(repo);
      final add = find.byIcon(Icons.add_circle_outline);
      await tester.ensureVisible(add);
      await tester.tap(add);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Choose raw material'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      await tester.tap(find.widgetWithText(AppButton, 'All'));
      await tester.pump();
      expect(find.widgetWithText(ListTile, 'Soybeans'), findsOneWidget);
      verifyNever(() => repo.receipts(any(), any(), any()));
      await tester.tap(find.widgetWithText(ListTile, 'Soybeans'));
      await tester.pump();
      ids.complete({1, 2});
      await tester.pumpAndSettle();
      expect(find.text('Choose raw material'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing product cannot be silently unlinked and material global identity survives editing',
    (tester) async {
      when(() => repo.list(archived: any(named: 'archived'))).thenAnswer(
        (_) async => [
          {
            'id': 1,
            'name': 'Starter',
            'product_id': null,
            'items_json':
                '[{"material_id":1,"material_name":"Maize","quantity_kg":100,"_material_remote_id":"original-maize"}]',
            'parameters_json':
                '{"_product_reference":{"remote_id":"missing-product","name":"Old product"}}',
          },
        ],
      );
      when(
        () => repo.receipts(any(), any(), any()),
      ).thenAnswer((_) async => []);
      when(
        () => repo.save(any(), id: any(named: 'id')),
      ).thenAnswer((_) async => 1);
      await open(tester);
      final save = find.widgetWithText(AppButton, 'Save');
      expect(tester.widget<AppButton>(save).onPressed, isNull);
      final unlink = find.text('Unlink missing product');
      await tester.ensureVisible(unlink);
      await tester.tap(unlink);
      await tester.pumpAndSettle();
      expect(tester.widget<AppButton>(save).onPressed, isNotNull);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final submitted =
          verify(() => repo.save(captureAny(), id: 1)).captured.single as Map;
      expect(submitted['_allow_product_unlink'], isTrue);
      expect(
        submitted['items'].single['_material_remote_id'],
        'original-maize',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
