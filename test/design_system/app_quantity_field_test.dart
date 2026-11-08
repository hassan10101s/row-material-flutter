import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/design_system/widgets/app_field.dart';
import 'package:material_lab/design_system/widgets/app_quantity_field.dart';

/// Behavioural cover for the app-wide quantity input.
///
/// Quantities must never accept text: letters typed or pasted into any
/// quantity field are rejected by the shared formatter, while digits and
/// decimal separators pass through.
void main() {
  Widget harness({TextEditingController? controller}) => ScreenUtilInit(
    designSize: const Size(1280, 720),
    minTextAdapt: true,
    splitScreenMode: true,
    builder: (context, _) => MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: AppQuantityField(
            label: 'Quantity',
            controller: controller ?? TextEditingController(),
          ),
        ),
      ),
    ),
  );

  testWidgets('letters are blocked, digits and decimals pass', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(harness(controller: controller));

    await tester.enterText(find.byType(TextField), '12.5');
    await tester.enterText(find.byType(TextField), 'ab12c.5d');
    await tester.pump();

    expect(controller.text, '12.5');
  });

  testWidgets(
    'normalizes Arabic decimals and rejects malformed or negative quantities',
    (tester) async {
      final controller = TextEditingController();
      await tester.pumpWidget(harness(controller: controller));
      await tester.enterText(find.byType(TextField), '١٢٫٥');
      expect(controller.text, '12.5');
      for (final bad in ['1.2.3', '1,2,3', '-5', 'NaN', 'Infinity']) {
        await tester.enterText(find.byType(TextField), bad);
        expect(controller.text, '12.5');
      }
    },
  );

  testWidgets('uses the numeric keyboard', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.keyboardType, TextInputType.numberWithOptions(decimal: true));
    expect(field.inputFormatters, isNotEmpty);
  });

  testWidgets('empty stays valid, text-only is rejected by the validator', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    // The composed numeric validator lives on the built AppField.
    final validate =
        tester.widget<AppField>(find.byType(AppField)).validator ?? (_) => null;
    expect(validate(''), isNull);
    expect(validate('12.5'), isNull);
    expect(validate('abc'), isNotNull);
    expect(validate('NaN'), isNotNull);
    expect(validate('Infinity'), isNotNull);
    expect(validate(List.filled(400, '9').join()), isNotNull);
  });

  testWidgets('a pasted numeric overflow cannot enter the quantity field', (
    tester,
  ) async {
    final controller = TextEditingController(text: '12.5');
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(controller: controller));
    await tester.enterText(
      find.byType(TextField),
      List.filled(400, '9').join(),
    );
    expect(controller.text, '12.5');
  });
}
