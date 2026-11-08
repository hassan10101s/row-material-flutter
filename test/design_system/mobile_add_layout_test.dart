import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_mobile_add_layout.dart';

void main() {
  tearDown(() => FormFactor.debugSet(null));
  testWidgets('phone create action is one floating plus at the bottom', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.mobile);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppMobileAddLayout(
          floating: true,
          tooltip: 'New item',
          onAdd: () => calls++,
          child: const Center(child: Text('Register')),
        ),
      ),
    );
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(
      tester.getCenter(find.byType(FloatingActionButton)).dy,
      greaterThan(450),
    );
    await tester.tap(find.byTooltip('New item'));
    expect(calls, 1);
  });
  testWidgets('desktop keeps its inline content and has no floating plus', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.desktop);
    await tester.pumpWidget(
      MaterialApp(
        home: AppMobileAddLayout(
          floating: false,
          tooltip: 'New item',
          onAdd: () {},
          child: const Text('Inline action'),
        ),
      ),
    );
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('Inline action'), findsOneWidget);
  });
  testWidgets('a missing create permission exposes no floating action', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.mobile);
    await tester.pumpWidget(
      const MaterialApp(
        home: AppMobileAddLayout(
          floating: true,
          tooltip: 'New item',
          child: Text('Read only'),
        ),
      ),
    );
    expect(find.byType(FloatingActionButton), findsNothing);
  });
}
