import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/design_system/widgets/app_dropdown.dart';

/// The crash class this widget exists to kill:
///
/// ```text
/// There should be exactly one item with [DropdownButton]'s value: 14.
/// ```
///
/// Reference rows outlive the parameters they point at, so a stored id can
/// dangle. A plain dropdown explodes the whole editor on open; [AppDropdown]
/// shows the stale reference as a disabled row instead.
void main() {
  Future<void> pumpDropdown(
    WidgetTester tester, {
    required int? value,
    required List<AppDropdownItem<int?>> items,
  }) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        minTextAdapt: true,
        builder: (_, _) => MaterialApp(
          home: Scaffold(
            body: AppDropdown<int?>(
              value: value,
              hintText: 'Choose…',
              items: items,
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<AppDropdownItem<int?>> options() => const [
        AppDropdownItem(value: 1, label: 'One'),
        AppDropdownItem(value: 2, label: 'Two'),
      ];

  testWidgets('a value present in the options renders normally',
      (tester) async {
    await pumpDropdown(tester, value: 1, items: options());

    expect(find.text('One'), findsWidgets);
    expect(find.textContaining('Deleted item'), findsNothing);
  });

  testWidgets('a dangling value renders a disabled row instead of throwing',
      (tester) async {
    await pumpDropdown(tester, value: 14, items: options());

    // No exception during layout: the regression is the crash itself.
    expect(tester.takeException(), isNull);
    // The stale reference stays visible once the menu opens.
    await tester.tap(find.byType(DropdownButtonFormField<int?>));
    await tester.pumpAndSettle();
    expect(find.textContaining('14'), findsWidgets);
  });

  testWidgets('duplicate option values collapse to the first occurrence',
      (tester) async {
    await pumpDropdown(tester, value: 1, items: [
      ...options(),
      const AppDropdownItem(value: 1, label: 'One again'),
    ]);

    expect(tester.takeException(), isNull);
    await tester.tap(find.byType(DropdownButtonFormField<int?>));
    await tester.pumpAndSettle();
    expect(find.text('One again'), findsNothing);
  });

  testWidgets('a null value shows the hint', (tester) async {
    await pumpDropdown(tester, value: null, items: options());

    expect(tester.takeException(), isNull);
    expect(find.text('Choose…'), findsOneWidget);
  });
}
