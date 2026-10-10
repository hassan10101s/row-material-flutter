import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/design_system/widgets/app_dialogs.dart';

/// Regression test: `showAppConfirm` action buttons must dismiss the dialog,
/// never the page underneath.
///
/// Shell branch navigators hold routes typed by their screen (e.g.
/// `AppPage<LabScreen>`). The buttons used to pop with the *caller's*
/// context, which resolves to the branch navigator — closing the page
/// itself with a bool result (`bool is not a subtype of LabScreen?`).
/// They now pop with the dialog's own context via `Builder`.
class _BranchPage extends StatelessWidget {
  const _BranchPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () async {
            final confirmed = await showAppConfirm(
              context,
              title: 'Delete?',
              message: 'Sure?',
              confirmLabel: 'Confirm',
              cancelLabel: 'Cancel',
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('result=$confirmed')),
              );
            }
          },
          child: const Text('open confirm'),
        ),
      ),
    );
  }
}

Future<void> _pumpNested(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ScreenUtilInit(
      designSize: const Size(1280, 1600),
      builder: (_, _) => MaterialApp(
        home: Scaffold(
          body: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute<_BranchPage>(
              builder: (_) => const _BranchPage(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('showAppConfirm inside a nested (branch) navigator', () {
    testWidgets('Confirm dismisses the dialog and resolves true',
        (tester) async {
      await _pumpNested(tester);
      await tester.tap(find.text('open confirm'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The branch page survived; only the dialog closed.
      expect(find.byType(_BranchPage), findsOneWidget);
      expect(find.text('result=true'), findsOneWidget);
    });

    testWidgets('Cancel dismisses the dialog and resolves false',
        (tester) async {
      await _pumpNested(tester);
      await tester.tap(find.text('open confirm'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(_BranchPage), findsOneWidget);
      expect(find.text('result=false'), findsOneWidget);
    });
  });
}
