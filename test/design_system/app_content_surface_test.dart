import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_info_button.dart';
import 'package:material_lab/design_system/widgets/app_info_hint.dart';
import 'package:material_lab/design_system/widgets/app_scroll_to_error.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';

void main() {
  tearDown(() => FormFactor.debugSet(null));

  Future<Future<void> Function()> pumpHost(
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
              builder: (tapContext) => Center(
                child: ElevatedButton(
                  onPressed: () => open(tapContext),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return () async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    };
  }

  testWidgets(
    'showAppContent desktop default: unified window dialog that pops result',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.desktop);
      String? result;
      final open = await pumpHost(tester, (context) async {
        result = await showAppContent<String>(
          context,
          title: 'Editor',
          builder: (context, close) => Column(
            children: [
              const Text('body'),
              TextButton(
                onPressed: () => close('saved'),
                child: const Text('save'),
              ),
            ],
          ),
        );
      });
      await open();

      expect(find.text('Editor'), findsOneWidget);
      expect(find.text('body'), findsOneWidget);

      await tester.tap(find.text('save'));
      await tester.pumpAndSettle();
      expect(find.text('body'), findsNothing);
      expect(result, 'saved');
    },
  );

  testWidgets(
    'showAppContent mobile default: pushed full page with back navigation',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      String? result;
      final open = await pumpHost(tester, (context) async {
        result = await showAppContent<String>(
          context,
          title: 'Editor',
          builder: (context, close) => Column(
            children: [
              const Text('body'),
              TextButton(
                onPressed: () => close('saved'),
                child: const Text('save'),
              ),
            ],
          ),
        );
      });
      await open();

      // Full page: the title lives in the app bar, no dialog chrome close X.
      expect(find.text('Editor'), findsOneWidget);
      expect(find.text('body'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.tap(find.text('save'));
      await tester.pumpAndSettle();
      expect(find.text('body'), findsNothing);
      expect(result, 'saved');
    },
  );

  testWidgets(
    'showAppContent explicit fullScreen on desktop pushes a page too',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.desktop);
      final open = await pumpHost(tester, (context) {
        return showAppContent<String>(
          context,
          title: 'Wide flow',
          fullScreen: true,
          builder: (context, close) => const Text('large content'),
        );
      });
      await open();
      expect(find.text('large content'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);
    },
  );

  testWidgets('guard: canClose=true pops directly, no confirmation', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.desktop);
    var confirmCalls = 0;
    final guard = AppContentGuard(
      confirmDiscard: () async {
        confirmCalls++;
        return true;
      },
    );
    final open = await pumpHost(tester, (context) {
      return showAppContent<String>(
        context,
        title: 'Editor',
        guard: guard,
        builder: (context, close) => const Text('body'),
      );
    });
    await open();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('body'), findsNothing);
    expect(confirmCalls, 0);
  });

  testWidgets(
    'guard: unsaved input + confirmed discard pops through the close button',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.desktop);
      var confirmCalls = 0;
      final guard = AppContentGuard(
        confirmDiscard: () async {
          confirmCalls++;
          return true;
        },
      );
      guard.canClose = false;
      final open = await pumpHost(tester, (context) {
        return showAppContent<String>(
          context,
          title: 'Editor',
          guard: guard,
          builder: (context, close) => const Text('body'),
        );
      });
      await open();

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.text('body'), findsNothing);
      expect(confirmCalls, 1);
    },
  );

  testWidgets('guard: cancelled confirmation keeps the surface open', (
    tester,
  ) async {
    FormFactor.debugSet(AppFormFactor.desktop);
    final guard = AppContentGuard(confirmDiscard: () async => false);
    guard.canClose = false;
    final open = await pumpHost(tester, (context) {
      return showAppContent<String>(
        context,
        title: 'Editor',
        guard: guard,
        builder: (context, close) => const Text('body'),
      );
    });
    await open();

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('body'), findsOneWidget);
  });

  testWidgets(
    'guard: mobile full page, system back blocked then discard pops',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      final guard = AppContentGuard(confirmDiscard: () async => true);
      guard.canClose = false;
      final open = await pumpHost(tester, (context) {
        return showAppContent<String>(
          context,
          title: 'Editor',
          guard: guard,
          builder: (context, close) => const Text('body'),
        );
      });
      await open();

      final navigatorState = tester
          .stateList<NavigatorState>(find.byType(Navigator))
          .first;
      final popped = await navigatorState.maybePop();
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      expect(find.text('body'), findsNothing);
    },
  );

  testWidgets(
    'guard: mobile full page, cancelled confirmation stays on the page',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.mobile);
      final guard = AppContentGuard(confirmDiscard: () async => false);
      guard.canClose = false;
      final open = await pumpHost(tester, (context) {
        return showAppContent<String>(
          context,
          title: 'Editor',
          guard: guard,
          builder: (context, close) => const Text('body'),
        );
      });
      await open();

      final navigatorState = tester
          .stateList<NavigatorState>(find.byType(Navigator))
          .first;
      await navigatorState.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('body'), findsOneWidget);
    },
  );

  testWidgets(
    'AppInfoHint: desktop shows the tooltip affordance, phone a tap button',
    (tester) async {
      FormFactor.debugSet(AppFormFactor.desktop);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppInfoHint(
              message: 'ingredient analysis',
              label: 'analysis',
            ),
          ),
        ),
      );
      final tooltips = tester.widgetList<Tooltip>(find.byType(Tooltip));
      expect(tooltips.any((t) => t.message == 'ingredient analysis'), isTrue);

      FormFactor.debugSet(AppFormFactor.mobile);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppInfoHint(
              message: 'ingredient analysis',
              label: 'analysis',
            ),
          ),
        ),
      );
      expect(find.byType(AppInfoButton), findsOneWidget);
      final phoneTooltips = tester.widgetList<Tooltip>(find.byType(Tooltip));
      expect(
        phoneTooltips.any((t) => t.message == 'ingredient analysis'),
        isTrue,
      );
    },
  );

  testWidgets(
    'AppFieldScrollRegistry scrolls the first errored field into view',
    (tester) async {
      final registry = AppFieldScrollRegistry();
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                captured = context;
                return SingleChildScrollView(
                  child: Column(
                    children: [
                      AppErrorAnchor(
                        registry: registry,
                        field: 'first',
                        child: const Text('field first'),
                      ),
                      const SizedBox(height: 800),
                      AppErrorAnchor(
                        registry: registry,
                        field: 'second',
                        child: const Text('field second'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );

      final scrollFuture = registry.scrollToError(captured, {
        'second': 'required',
        'first': 'bad',
      });
      await tester.pumpAndSettle();
      final scrolledField = await scrollFuture;

      expect(scrolledField, 'second');
      final rect = tester.getRect(find.text('field second'));
      expect(rect.top, greaterThanOrEqualTo(0));
    },
  );
}
