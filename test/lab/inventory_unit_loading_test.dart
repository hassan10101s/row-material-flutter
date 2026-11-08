import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/design_system/widgets/app_unit_field.dart';
import 'package:material_lab/features/lab/domain/lab_local_repository.dart';
import 'package:material_lab/features/lab/presentation/inventory/inventory_forms.dart';

class _Repo extends Mock implements LabLocalRepository {}

void main() {
  for (final dialog in [false, true]) {
    group(dialog ? 'inventory dialog' : 'inventory form', () {
      late Completer<List<String>> pending;
      setUp(() async {
        await getIt.reset();
        final repo = _Repo();
        when(() => repo.listUnitSymbols()).thenAnswer((_) => pending.future);
        getIt.registerSingleton<LabLocalRepository>(repo);
      });
      tearDown(() => getIt.reset());

      Future<void> mount(WidgetTester tester) async {
        // The completer must belong to this widget test's fake-async zone.
        pending = Completer<List<String>>();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: const Size(1280, 720),
            builder: (_, _) => MaterialApp(
              home: Scaffold(
                body: Center(
                  child: dialog
                      ? const InventoryItemDialog()
                      : const InventoryItemForm(),
                ),
              ),
            ),
          ),
        );
      }

      testWidgets('an asynchronous unit query failure remains nonfatal', (
        tester,
      ) async {
        await mount(tester);
        pending.completeError(StateError('database unavailable'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byType(AppUnitField), findsOneWidget);
      });

      testWidgets('a late failure after disposal is handled', (tester) async {
        await mount(tester);
        await tester.pumpWidget(const SizedBox());
        pending.completeError(StateError('closed connection'));
        await tester.pump();
        expect(tester.takeException(), isNull);
      });

      testWidgets('a completed unit query supplies the picker', (tester) async {
        await mount(tester);
        pending.complete(['mL', 'L']);
        await tester.pump();
        expect(tester.widget<AppUnitField>(find.byType(AppUnitField)).symbols, [
          'mL',
          'L',
        ]);
      });
    });
  }
}
