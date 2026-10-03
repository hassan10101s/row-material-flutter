import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/lab/presentation/cubit/constants_cubit.dart';
import 'package:material_lab/features/lab/presentation/constants_tab.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/reference/presentation/cubit/params_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/reference_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/units_cubit.dart';
import 'package:material_lab/features/reference/presentation/materials_tab.dart';
import 'package:material_lab/features/reference/presentation/params_tab.dart';
import 'package:material_lab/features/reference/presentation/units_tab.dart';

class _LocalMock extends Mock implements LabLocalRepository {}

class _ReferenceMock extends Mock implements ReferenceRepository {}

class _LabConfigMock extends Mock implements LabConfigurationRepository {}

/// The two authoring grids from PLAN_V4.
const desktopGrid = Size(1280, 720);
const mobileGrid = Size(400, 860);

/// What the constants editor must store for the input [saveConstant] types.
///
/// Written out here rather than compared against the other variant's write:
/// a payload that both variants got wrong the same way would otherwise pass.
Map<String, dynamic> expectedConstant() => <String, dynamic>{
  'name': 'Carbon',
  'symbol': 'C',
  'unit': '',
  'description': '',
  'is_expression': false,
  'expression': '',
  'value_text': '',
};

void main() {
  late _LocalMock local;
  late _ReferenceMock reference;
  late _LabConfigMock labConfig;
  late ConstantsCubit constants;
  late ParamsCubit chemical;
  late UnitsCubit units;
  late ReferenceCubit referenceCubit;

  /// Every payload the constants editor asked to store, in order.
  late List<Map<String, dynamic>> constantWrites;

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

    local = _LocalMock();
    reference = _ReferenceMock();
    labConfig = _LabConfigMock();
    constantWrites = [];
    paramWrites = [];
    unitWrites = [];

    when(() => local.listGlobalConstants()).thenAnswer(
      (_) async => <Map<String, dynamic>>[
        {'id': 1, 'name': 'Carbon', 'symbol': 'C', 'value_text': '0.5'},
      ],
    );
    // Captured rather than verified: the assertions below hold both variants
    // to a payload written out independently of either of them, and a verified
    // call would have to be re-stubbed between the two.
    when(() => local.upsertGlobalConstant(any())).thenAnswer((inv) async {
      constantWrites.add(inv.positionalArguments.first as Map<String, dynamic>);
      return <String, dynamic>{};
    });
    when(
      () => local.deleteGlobalConstant(any()),
    ).thenAnswer((_) async => <String, dynamic>{});

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

    constants = ConstantsCubit(repo: local);
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
    await constants.load();
    await chemical.load();
    await units.load();
    await referenceCubit.load();
  });

  tearDown(() async {
    await constants.close();
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

  Widget constantsHost() => BlocProvider<ConstantsCubit>.value(
    value: constants,
    child: ConstantsTab(repo: local),
  );

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

  group('the host dispatches on the platform, not the window', () {
    testWidgets('desktop form factor builds the desktop variant', (
      tester,
    ) async {
      await pumpAs(tester, AppFormFactor.desktop, constantsHost());

      expect(find.byType(DataTable), findsOneWidget);
    });

    testWidgets('mobile form factor builds the mobile variant', (tester) async {
      await pumpAs(tester, AppFormFactor.mobile, constantsHost());

      expect(find.byType(DataTable), findsNothing);
      // The card list, not a table: a DataTable at 400dp would be six
      // ellipsised columns behind a horizontal scrollbar.
      expect(find.text('Carbon'), findsOneWidget);
    });
  });

  group('a table on desktop becomes a card list on a phone', () {
    testWidgets('constants', (tester) async {
      await pumpAs(tester, AppFormFactor.desktop, constantsHost());
      expect(find.byType(DataTable), findsOneWidget);

      await pumpAs(tester, AppFormFactor.mobile, constantsHost());
      expect(find.byType(DataTable), findsNothing);
      expect(find.text('Carbon'), findsOneWidget);
    });

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

    /// Opens the constant editor, fills it and saves.
    Future<void> saveConstant(WidgetTester tester) async {
      await tester.tap(find.text('Add constant'));
      await tester.pumpAndSettle();

      // Indexed rather than looked up by label: the editor shows a value field
      // or an expression field depending on the switch, so the field count
      // moves. Name and symbol are always the first two.
      await tester.enterText(find.byType(TextField).at(0), 'Carbon');
      await tester.enterText(find.byType(TextField).at(1), 'C');
      await tester.pump();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
    }

    /// Opens the parameter editor, fills it and saves.
    Future<void> saveParam(WidgetTester tester) async {
      await tester.tap(find.text('New Parameter'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'Carbon');
      await tester.enterText(find.byType(TextField).at(1), '%');
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

    testWidgets('the desktop editor is a dialog', (tester) async {
      await pumpAs(tester, AppFormFactor.desktop, constantsHost());
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('Add constant'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(constantWrites, isEmpty, reason: 'cancelling must not save');
    });

    testWidgets('the phone editor is a full-screen route, not a dialog', (
      tester,
    ) async {
      await pumpAs(tester, AppFormFactor.mobile, constantsHost());
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('Add constant'));
      await tester.pumpAndSettle();
      // A route with its own Scaffold and app bar, replacing the tab rather
      // than floating over it - which is what makes the system back gesture
      // and the keyboard-inset behave. The tab's own Scaffold is offstage
      // behind the opaque route, hence one and not two.
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      // The route's title, not the button behind it.
      expect(find.text('Add constant'), findsOneWidget);
    });

    testWidgets('both constant variants store the canonical payload', (
      tester,
    ) async {
      for (final factor in AppFormFactor.values) {
        constantWrites.clear();
        await pumpAs(tester, factor, constantsHost());
        await saveConstant(tester);
        expect(constantWrites, [expectedConstant()], reason: '$factor');
      }
    });

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

    testWidgets('a physical parameter has no unit field on either experience', (
      tester,
    ) async {
      // Physical rows are unit-less by design, so the field must be absent
      // rather than disabled - and absent on both.
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

        final unitFields = tester
            .widgetList<TextField>(find.byType(TextField))
            .where((f) => f.decoration?.labelText == 'Unit')
            .length;
        expect(unitFields, 0, reason: '$factor');

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
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('New Unit'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(unitWrites, isEmpty, reason: 'cancelling must not save');
    });

    testWidgets('the phone unit editor is a full-screen route', (tester) async {
      await pumpAs(tester, AppFormFactor.mobile, unitsHost());
      expect(find.byType(AlertDialog), findsNothing);

      await tester.tap(find.text('New Unit'));
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
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
