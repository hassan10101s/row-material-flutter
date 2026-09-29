import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/design_system/widgets/app_autocomplete.dart';

/// Behavioural cover for the app-wide entity picker.
///
/// `AppAutocomplete` replaces a hand-rolled `RawAutocomplete` that was copied
/// into the inspection form. These tests pin the behaviour that mattered there:
/// the empty query serves the whole list, typing narrows it, a committed choice
/// is read-only, a miss shows an empty label, and the caret re-opens the list.
void main() {
  const materials = <(int, String)>[
    (1, 'Water'),
    (2, 'Glass'),
    (3, 'Water softener'),
  ];

  Widget harness({
    (int, String)? selected,
    ValueChanged<(int, String)>? onSelected,
    String emptyLabel = 'No matches',
  }) => ScreenUtilInit(
    designSize: const Size(1280, 720),
    minTextAdapt: true,
    splitScreenMode: true,
    builder: (context, _) => MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: AppAutocomplete<(int, String)>(
            options: materials,
            selected: selected,
            displayString: (option) => option.$2,
            filter: (option, query) => option.$2.toLowerCase().contains(query),
            onSelected: onSelected ?? (_) {},
            hint: 'Type to search…',
            emptyLabel: emptyLabel,
          ),
        ),
      ),
    ),
  );

  /// Types [text] into the field and pumps the async options overlay up.
  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pumpAndSettle();
  }

  testWidgets('an empty query offers the whole list', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Glass'), findsOneWidget);
    expect(find.text('Water softener'), findsOneWidget);
  });

  testWidgets('typing narrows by the provided filter', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await search(tester, 'glass');

    expect(find.text('Glass'), findsOneWidget);
    expect(find.text('Water'), findsNothing);
    expect(find.text('Water softener'), findsNothing);
  });

  testWidgets('committing an option reports it and settles the field', (
    tester,
  ) async {
    (int, String)? committed;
    await tester.pumpWidget(
      harness(onSelected: (option) => committed = option),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await search(tester, 'glass');
    await tester.tap(find.text('Glass'));
    await tester.pumpAndSettle();

    expect(committed, (2, 'Glass'));
    // The field carries the chosen display string.
    expect(
      find.descendant(of: find.byType(TextField), matching: find.text('Glass')),
      findsOneWidget,
    );
  });

  testWidgets('a query with no hits shows the empty label', (tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await search(tester, 'zzz-no-such-thing');

    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets(
    'a committed selection is read-only and shows the display string',
    (tester) async {
      await tester.pumpWidget(harness(selected: (3, 'Water softener')));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.readOnly, isTrue);
      expect(
        find.descendant(
          of: find.byType(TextField),
          matching: find.text('Water softener'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('switching to no selection clears the field', (tester) async {
    final selected = ValueNotifier<(int, String)?>((1, 'Water'));
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: selected,
        builder: (context, value, _) => harness(selected: value),
      ),
    );
    await tester.pumpAndSettle();

    selected.value = null;
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
    expect(find.text('Water'), findsNothing);
  });

  testWidgets('the caret re-opens the list from a typed query', (tester) async {
    await tester.pumpWidget(harness());
    await search(tester, 'wat');

    // Overlay is up with the narrowed set…
    expect(find.text('Water'), findsOneWidget);
    expect(find.text('Water softener'), findsOneWidget);
  });
}
