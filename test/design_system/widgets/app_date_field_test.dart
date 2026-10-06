import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../lib/design_system/widgets/app_date_field.dart';

void main() {
  testWidgets('supports text entry and opens the date picker', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDateField(label: 'Inspection date', controller: controller),
        ),
      ),
    );

    await tester.enterText(find.byType(TextFormField), '2026-02-01');
    expect(controller.text, '2026-02-01');

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
  });
}
