import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/design_system/widgets/app_add_floating_action_button.dart';
import 'package:material_lab/design_system/widgets/app_export_button.dart';
import 'package:material_lab/features/reference/domain/reference_repository.dart';
import 'package:material_lab/features/lab/domain/lab_result_repository.dart';
import 'package:material_lab/features/reference/presentation/cubit/reference_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/reference_state.dart';
import 'package:material_lab/features/reference/presentation/cubit/products_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/products_state.dart';
import 'package:material_lab/features/reference/presentation/cubit/params_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/params_state.dart';
import 'package:material_lab/features/reference/presentation/cubit/units_cubit.dart';
import 'package:material_lab/features/reference/presentation/cubit/units_state.dart';
import 'package:material_lab/features/reference/presentation/materials/mobile/materials_tab.dart';
import 'package:material_lab/features/reference/presentation/materials/desktop/materials_tab.dart';
import 'package:material_lab/features/reference/presentation/products/mobile/products_tab.dart';
import 'package:material_lab/features/reference/presentation/params/mobile/params_tab.dart';
import 'package:material_lab/features/reference/presentation/units/mobile/units_tab.dart';

class _Materials extends Mock implements ReferenceCubit {}

class _Products extends Mock implements ProductsCubit {}

class _Params extends Mock implements ParamsCubit {}

class _Units extends Mock implements UnitsCubit {}

class _Reference extends Mock implements ReferenceRepository {}

class _Lab extends Mock implements LabConfigurationRepository {}

void main() {
  testWidgets(
    'desktop searches beyond the loaded page and discards stale pages',
    (tester) async {
      AppText.useLanguage('en');
      addTearDown(() => AppText.useLanguage('ar'));
      const size = Size(1280, 800);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _Reference();
      final oldPage = Completer<List<Map<String, dynamic>>>();
      when(
        () => repo.listMaterialsPaged(query: '', limit: 1, offset: 0),
      ).thenAnswer(
        (_) async => [
          {'id': 1, 'material_name': 'First material'},
        ],
      );
      when(
        () => repo.listMaterialsPaged(query: '', limit: 1, offset: 1),
      ).thenAnswer((_) => oldPage.future);
      when(() => repo.countMaterials(query: '')).thenAnswer((_) async => 3);
      when(
        () => repo.listMaterialsPaged(query: '9687', limit: 1, offset: 0),
      ).thenAnswer(
        (_) async => [
          {
            'id': 3,
            'material_name': 'Unloaded material',
            'material_code': '9687',
          },
        ],
      );
      when(() => repo.countMaterials(query: '9687')).thenAnswer((_) async => 1);
      final cubit = ReferenceCubit(repo: repo, pageSize: 1);
      addTearDown(cubit.close);
      await cubit.load();
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: size,
          builder: (_, _) => MaterialApp(
            home: Scaffold(
              body: BlocProvider.value(
                value: cubit,
                child: DesktopMaterialsTab(refRepo: repo, labConfig: _Lab()),
              ),
            ),
          ),
        ),
      );
      expect(find.text('First material'), findsOneWidget);
      final pending = cubit.loadMore();
      await tester.enterText(find.byType(EditableText), '9687');
      await tester.pumpAndSettle(const Duration(milliseconds: 400));
      expect(find.text('Unloaded material'), findsOneWidget);
      oldPage.complete([
        {'id': 2, 'material_name': 'Unrelated old page'},
      ]);
      await pending;
      await tester.pumpAndSettle();
      expect(find.text('Unrelated old page'), findsNothing);
      expect(cubit.state.loadingMore, isFalse);
    },
  );

  for (final direction in TextDirection.values) {
    for (final tab in [
      'materials',
      'products',
      'chemical',
      'physical',
      'units',
    ]) {
      testWidgets(
        '$tab places export beside search with a shared floating plus ($direction)',
        (tester) async {
          AppText.useLanguage(direction == TextDirection.rtl ? 'ar' : 'en');
          addTearDown(() => AppText.useLanguage('ar'));
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          late Widget page;
          late Future<void> Function(String) setQuery;
          if (tab == 'materials') {
            final cubit = _Materials();
            when(
              () => cubit.state,
            ).thenReturn(const ReferenceState(loading: false));
            when(
              () => cubit.stream,
            ).thenAnswer((_) => const Stream<ReferenceState>.empty());
            when(() => cubit.setQuery(any())).thenAnswer((_) async {});
            setQuery = cubit.setQuery;
            page = BlocProvider<ReferenceCubit>.value(
              value: cubit,
              child: MobileMaterialsTab(
                refRepo: _Reference(),
                labConfig: _Lab(),
              ),
            );
          } else if (tab == 'products') {
            final cubit = _Products();
            when(
              () => cubit.state,
            ).thenReturn(const ProductsState(loading: false));
            when(
              () => cubit.stream,
            ).thenAnswer((_) => const Stream<ProductsState>.empty());
            when(() => cubit.setQuery(any())).thenAnswer((_) async {});
            setQuery = cubit.setQuery;
            page = BlocProvider<ProductsCubit>.value(
              value: cubit,
              child: const MobileProductsTab(),
            );
          } else if (tab == 'units') {
            final cubit = _Units();
            when(
              () => cubit.state,
            ).thenReturn(const UnitsState(loading: false));
            when(
              () => cubit.stream,
            ).thenAnswer((_) => const Stream<UnitsState>.empty());
            when(() => cubit.setQuery(any())).thenAnswer((_) async {});
            setQuery = cubit.setQuery;
            page = BlocProvider<UnitsCubit>.value(
              value: cubit,
              child: const MobileUnitsTab(),
            );
          } else {
            final cubit = _Params();
            when(
              () => cubit.state,
            ).thenReturn(const ParamsState(loading: false));
            when(
              () => cubit.stream,
            ).thenAnswer((_) => const Stream<ParamsState>.empty());
            when(() => cubit.setQuery(any())).thenAnswer((_) async {});
            setQuery = cubit.setQuery;
            page = BlocProvider<ParamsCubit>.value(
              value: cubit,
              child: MobileParamsTab(parameterType: tab),
            );
          }
          await tester.pumpWidget(
            ScreenUtilInit(
              designSize: const Size(390, 844),
              builder: (_, _) => MaterialApp(
                home: Directionality(
                  textDirection: direction,
                  child: Scaffold(
                    body: Padding(
                      padding: const EdgeInsets.all(16),
                      child: page,
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(AppSearchRow), findsOneWidget);
          expect(find.byType(AppAddFloatingActionButton), findsOneWidget);
          expect(find.byType(FloatingActionButton), findsOneWidget);
          final search = tester.getRect(find.byType(TextField));
          final export = tester.getRect(find.byType(AppExportIconButton));
          expect((search.center.dy - export.center.dy).abs(), lessThan(2));
          expect(
            export.top,
            lessThan(40),
            reason: 'Export must not reserve a separate header row',
          );
          expect(
            tester
                .widget<AppExportIconButton>(find.byType(AppExportIconButton))
                .onPressed,
            isNull,
          );
          expect(
            tester
                .widget<FloatingActionButton>(find.byType(FloatingActionButton))
                .heroTag,
            isNull,
          );
          await tester.enterText(find.byType(TextField), 'protein');
          await tester.pump(const Duration(milliseconds: 400));
          verify(() => setQuery('protein')).called(1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
