import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/design_system/widgets/app_window.dart';

/// The unified window chrome: one look for every dialog in the program.
void main() {
  Future<void> pumpTrigger(
    WidgetTester tester,
    Future<void> Function(BuildContext context) open,
  ) async {
    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(1280, 720),
        minTextAdapt: true,
        builder: (_, _) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => open(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('showAppWindow renders title, body and pops the result',
      (tester) async {
    await pumpTrigger(
      tester,
      (context) => showAppWindow<String>(
        context,
        title: 'Edit thing',
        icon: Icons.edit_outlined,
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('saved'),
            child: const Text('Save'),
          ),
        ],
        child: const Text('body content'),
      ),
    );

    expect(find.text('Edit thing'), findsOneWidget);
    expect(find.text('body content'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    // The window chrome carries a close button.
    expect(find.byIcon(Icons.close), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('body content'), findsNothing);
  });

  testWidgets('showAppOverlay uses the window chrome on wide screens',
      (tester) async {
    await pumpTrigger(
      tester,
      (context) => showAppOverlay<String>(
        context,
        title: 'Filters',
        icon: Icons.filter_alt_outlined,
        builder: (context, close) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('filter body'),
            TextButton(
              onPressed: () => close('applied'),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );

    // 1280dp wide: the desktop branch, so the window header shows.
    expect(find.text('Filters'), findsOneWidget);
    expect(find.text('filter body'), findsOneWidget);

    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.text('filter body'), findsNothing);
  });
}
