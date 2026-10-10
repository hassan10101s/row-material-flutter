import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/reference/presentation/cubit/params_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/reference_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/units_cubit.dart';
import 'package:material_lab/features/reference/presentation/materials/materials_tab.dart';
import 'package:material_lab/features/reference/presentation/params/params_tab.dart';
import 'package:material_lab/features/reference/presentation/units/units_tab.dart';

class _ReferenceMock extends Mock implements ReferenceRepository {}

class _LabConfigMock extends Mock implements LabConfigurationRepository {}

/// The two authoring grids from PLAN_V4.
const desktopGrid = Size(1280, 720);
const mobileGrid = Size(400, 860);

void main() {
  late _ReferenceMock reference;
  late _LabConfigMock labConfig;
  late ParamsCubit chemical;
  late UnitsCubit units;
  late ReferenceCubit referenceCubit;

  /// Every `(name, unit)` the parameter editor upserted, in order.
  late List<(String, String)> paramWrites;

  /// Every `(symbol, name, dimension)` the unit editor upserted, in order.
  late List<(String, String, String)> unitWrites;

  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  setUp(() async {
    // The UI strings are chosen by a global; pin them so the finders below are
    // stable whichever language the previous test left behind.
    AppText.useLanguage('en');

    reference = _ReferenceMock();
    labConfig = _LabConfigMock();
    paramWrites = [];
    unitWrites = [];

    when(
      () =>
          reference.listParameters(parameterType: any(named: 'parameterType')),
    ).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {'parameter_name': 'Carbon', 'unit': '%'},
      ],
    );
    when(
      () => reference.upsertParameter(
        any(),
        any(),
        parameterType: any(named: 'parameterType'),
      ),
    ).thenAnswer((inv) async {
      paramWrites.add((
        inv.positionalArguments[0] as String,
        inv.positionalArguments[1] as String,
      ));
    });

    when(() => reference.listUnits()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {'symbol': '%', 'name': 'Percent', 'dimension': 'concentration'},
      ],
    );
    when(
      () => reference.upsertUnit(
        any(),
        name: any(named: 'name'),
        dimension: any(named: 'dimension'),
      ),
    ).thenAnswer((inv) async {
      unitWrites.add((
        inv.positionalArguments[0] as String,
        inv.namedArguments[#name] as String,
        inv.namedArguments[#dimension] as String,
      ));
    });

    chemical = ParamsCubit.chemical(repo: reference);
    units = UnitsCubit(repo: reference);
    referenceCubit = ReferenceCubit(repo: reference);

    // The material editor loads these on open, from the repositories the host
    // injects rather than from `getIt` - the editor sits in a dialog on
    // desktop, so it cannot read a provider off the screen.
    when(() => reference.listParameters()).thenAnswer((_) async => []);
    when(() => reference.listAllMaterials()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {'id': 1, 'material_name': 'Apple Pomace', 'material_code': 'APL'},
      ],
    );

    // Loaded up front rather than per test: an unloaded cubit renders a
    // shimmering skeleton, and `pumpAndSettle` never settles against a
    // repeating animation.
    await chemical.load();
    await units.load();
    await referenceCubit.load();
  });

  tearDown(() async {
    await chemical.close();
    await units.close();
    await referenceCubit.close();
    // FormFactor memoises, so a test that pinned it must not leak into the
    // next one.
    FormFactor.debugSet(null);
  });

  /// Pumps [child] on the grid its experience was authored against.
  ///
  /// The surface is resized as well as the design size: a mobile variant is
  /// full of `Expanded` and `ListView`, which throw on an unbounded height, so
  /// testing the phone layout against the default 800x600 desktop surface
  /// would fail for a reason that has nothing to do with the split.
  Future<void> pumpOn(
    WidgetTester tester,
    Widget child, {
    required Size grid,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = grid;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: grid,
        builder: (_, _) => MaterialApp(home: Scaffold(body: child)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget paramsHost() => BlocProvider<ParamsCubit>.value(
    value: chemical,
    child: const ParamsTab(parameterType: 'chemical'),
  );

  Widget unitsHost() =>
      BlocProvider<UnitsCubit>.value(value: units, child: const UnitsTab());

  Widget materialsHost() => BlocProvider<ReferenceCubit>.value(
    value: referenceCubit,
    child: MaterialsTab(refRepo: reference, labConfig: labConfig),
  );

  /// Pins the form factor and lays the screen out on the grid it was authored
  /// against.
  ///
  /// [FormFactor.debugSet] is used rather than letting it resolve from the
  /// platform because the form factor must be asserted from both sides in one
  /// test file, and `defaultTargetPlatform` in a widget test is not a knob the
  /// test can turn per case.
  Future<void> pumpAs(
    WidgetTester tester,
    AppFormFactor factor,
    Widget child,
  ) async {
    FormFactor.debugSet(factor);
    await pumpOn(
      tester,
      child,
      grid: factor.isMobile ? mobileGrid : desktopGrid,
    );
  }

  group('a table on desktop becomes a card list on a phone', () {
    testWidgets('chemical parameters', (tester) async {
      await pumpAs(tester, AppFormFactor.desktop, paramsHost());
      expect(find.byType(DataTable), findsOneWidget);

      await pumpAs(tester, AppFormFactor.mobile, paramsHost());
      expect(find.byType(DataTable), findsNothing);
      expect(find.text('Carbon'), findsOneWidget);
    });

    testWidgets('units', (tester) async {
      await pumpAs(tester, AppFormFactor.desktop, unitsHost());
      expect(find.byType(DataTable), findsOneWidget);

      await pumpAs(tester, AppFormFactor.mobile, unitsHost());
      expect(find.byType(DataTable), findsNothing);
      expect(find.text('Percent'), findsOneWidget);
    });

    testWidgets('materials list renders on both experiences', (tester) async {
      // The materials list is a list on desktop too, so this is not a
      // table/card flip - it pins that the split did not lose the rows.
      for (final factor in AppFormFactor.values) {
        await pumpAs(tester, factor, materialsHost());
        expect(find.text('Apple Pomace'), findsOneWidget, reason: '$factor');
        expect(find.text('APL'), findsOneWidget, reason: '$factor');
      }
    });
  });

  group('both variants write the same payload', () {
    // The point of extracting the editor instead of copying it: a copy would
    // let the phone start saving a different payload and nothing would notice,
    // because each copy would still pass its own tests. Both variants are held
    // here to a payload written out independently of either of them.

    /// Opens the parameter editor, fills it and saves.
    Future<void> saveParam(WidgetTester tester) async {
      await tester.tap(find.text('New Parameter'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Carbon');
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('%').last);
      await tester.pumpAndSettle();
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    /// Opens the unit editor, fills it and saves.
    Future<void> saveUnit(WidgetTester tester) async {
      await tester.tap(find.text('New Unit'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'mg/kg');
      await tester.enterText(find.byType(TextField).at(1), 'Mass');
      await tester.enterText(find.byType(TextField).at(2), 'mass');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    // The unified window chrome, not a bare AlertDialog: every desktop
    // editor inherits AppWindow.

    testWidgets('both parameter variants upsert the same name and unit', (
      tester,
    ) async {
      for (final factor in AppFormFactor.values) {
        paramWrites.clear();
        await pumpAs(tester, factor, paramsHost());
        await saveParam(tester);
        expect(paramWrites, [('Carbon', '%')], reason: '$factor');
      }
    });

    testWidgets('a physical parameter uses the shared reference unit field', (
      tester,
    ) async {
      final physical = ParamsCubit.physical(repo: reference);
      addTearDown(physical.close);
      await physical.load();

      Widget host() => BlocProvider<ParamsCubit>.value(
        value: physical,
        child: const ParamsTab(parameterType: 'physical'),
      );

      for (final factor in AppFormFactor.values) {
        await pumpAs(tester, factor, host());

        await tester.tap(find.text('New Parameter'));
        await tester.pumpAndSettle();

        expect(find.text('Reference unit'), findsOneWidget, reason: '$factor');
        expect(
          find.byType(DropdownButtonFormField<String>),
          findsOneWidget,
          reason: '$factor',
        );

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets(
      'both unit variants upsert the same symbol, name and dimension',
      (tester) async {
        for (final factor in AppFormFactor.values) {
          unitWrites.clear();
          await pumpAs(tester, factor, unitsHost());
          await saveUnit(tester);
          expect(unitWrites, [('mg/kg', 'Mass', 'mass')], reason: '$factor');
        }
      },
    );

    testWidgets('the desktop unit editor is a dialog', (tester) async {
      await pumpAs(tester, AppFormFactor.desktop, unitsHost());
      expect(find.byType(AppWindow), findsNothing);

      await tester.tap(find.text('New Unit'));
      await tester.pumpAndSettle();
      expect(find.byType(AppWindow), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(unitWrites, isEmpty, reason: 'cancelling must not save');
    });

    testWidgets('the phone unit editor is a full-screen route', (tester) async {
      await pumpAs(tester, AppFormFactor.mobile, unitsHost());
      expect(find.byType(AppWindow), findsNothing);

      await tester.tap(find.text('New Unit'));
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(AppWindow), findsNothing);
    });

    testWidgets(
      'the unit editor refuses an empty symbol on either experience',
      (tester) async {
        // The symbol is the unit's primary key, so an empty one is rejected
        // before the save rather than after it.
        for (final factor in AppFormFactor.values) {
          await pumpAs(tester, factor, unitsHost());

          await tester.tap(find.text('New Unit'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).at(0), '   ');
          await tester.pump();
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();

          expect(unitWrites, isEmpty, reason: '$factor');
          expect(
            find.text('Symbol is required.'),
            findsOneWidget,
            reason: '$factor',
          );

          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
        }
      },
    );

    testWidgets('the desktop material editor is a dialog', (tester) async {
      // A bare `Dialog`, not an `AlertDialog`: the editor is an 880x680 sheet
      // with its own header and footer, which is what it has always been.
      await pumpAs(tester, AppFormFactor.desktop, materialsHost());
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(find.text('Add New Material'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
    });

    testWidgets('the phone material editor is a full-screen route', (
      tester,
    ) async {
      await pumpAs(tester, AppFormFactor.mobile, materialsHost());
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(find.text('Add New Material'));
      await tester.pumpAndSettle();
      // An 880x680 dialog cannot be made usable at 400dp, so the phone gets a
      // route - and no dialog, which is the whole point.
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
    });

    testWidgets('the material editor loads through injected repositories', (
      tester,
    ) async {
      // The editor used to reach for `getIt` in its field initialisers. That
      // works by accident inside a dialog and by luck inside a route; the host
      // injects both repositories instead. Asserting the injected one is the one
      // consulted pins that, and no `getIt` registration is set up in this file
      // at all - an unresolved lookup would throw rather than silently pass.
      await pumpAs(tester, AppFormFactor.desktop, materialsHost());
      await tester.tap(find.text('Add New Material'));
      await tester.pumpAndSettle();

      verify(() => reference.listParameters()).called(1);
    });
  });
}
