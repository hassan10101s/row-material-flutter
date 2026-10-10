import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/reference/presentation/cubit/products_cubit.dart';
import 'package:material_lab/features/reference/presentation/materials/material_editor.dart';
import 'package:material_lab/features/reference/presentation/products/products_tab.dart';

class _LabConfigMock extends Mock implements LabConfigurationRepository {}

class _ReferenceMock extends Mock implements ReferenceRepository {}

const _physicalParams = [
  {
    'id': 1,
    'parameter_name': 'Moisture',
    'unit': '%',
    'parameter_type': 'physical',
  },
];

Future<void> _pumpWide(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(1280, 900),
      builder: (_, _) => MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late _LabConfigMock labConfig;
  late _ReferenceMock reference;

  setUp(() {
    AppText.useLanguage('ar');
    labConfig = _LabConfigMock();
    reference = _ReferenceMock();
    when(() => labConfig.listProducts()).thenAnswer((_) async => []);
    when(() => labConfig.listAnalyses()).thenAnswer((_) async => []);
    when(() => reference.listParameters())
        .thenAnswer((_) async => List<Map<String, dynamic>>.from(
              _physicalParams.map(Map<String, dynamic>.from),
            ));
    getIt.registerSingleton<ReferenceRepository>(reference);
  });

  tearDown(() async {
    FormFactor.debugSet(null);
    await getIt.reset();
  });

  Widget host(ProductsCubit cubit) => BlocProvider.value(
        value: cubit,
        child: const ProductsTab(),
      );

  group('product editor mirrors the material editor', () {
    testWidgets('desktop dialog can add a physical row', (tester) async {
      FormFactor.debugSet(AppFormFactor.desktop);
      final cubit = ProductsCubit(repo: labConfig);
      addTearDown(cubit.close);
      await cubit.load();
      await _pumpWide(tester, host(cubit));

      await tester.tap(find.text('منتج جديد'));
      await tester.pumpAndSettle();
      expect(find.byType(AppWindow), findsOneWidget);

      await tester.tap(find.text('إضافة بارامتر'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('اختر بارامتراً ظاهرياً…'), findsOneWidget);
    });

    testWidgets('mobile route can add a physical row', (tester) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      final cubit = ProductsCubit(repo: labConfig);
      addTearDown(cubit.close);
      await cubit.load();
      await _pumpWide(tester, host(cubit));

      await tester.tap(find.text('منتج جديد'));
      await tester.pumpAndSettle();
      expect(find.byType(AppWindow), findsNothing);

      await tester.tap(find.text('إضافة بارامتر'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('اختر بارامتراً ظاهرياً…'), findsOneWidget);
    });

    testWidgets('material editor compact row does not nest Expanded',
        (tester) async {
      await _pumpWide(
        tester,
        MaterialEditor(
          refRepo: reference,
          labConfig: labConfig,
          layout: MaterialEditorLayout.compact,
        ),
      );

      await tester.tap(find.text('إضافة بارامتر'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('اختر بارامتراً ظاهرياً…'), findsOneWidget);
    });
  });
}
