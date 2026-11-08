import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/app/widget_error_view.dart';

class _BrokenPart extends StatelessWidget {
  const _BrokenPart();
  @override
  Widget build(BuildContext context) =>
      throw StateError('original subtree failure');
}

void main() {
  testWidgets(
    'a build error inside a sliver has a finite inline fallback and reports the original error once',
    (tester) async {
      final original = ErrorWidget.builder;
      ErrorWidget.builder = buildAppWidgetError;
      addTearDown(() => ErrorWidget.builder = original);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [Text('Before'), _BrokenPart(), Text('After')],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.takeException(), isA<StateError>());
      expect(find.byType(AppWidgetErrorView), findsOneWidget);
      expect(
        tester.getSize(find.byType(AppWidgetErrorView)).height,
        lessThanOrEqualTo(120),
      );
      expect(find.text('After'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppWidgetErrorView),
          matching: find.byType(Navigator),
        ),
        findsNothing,
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      ErrorWidget.builder = original;
    },
  );

  testWidgets(
    'fallback also fits a tiny field without creating another overflow',
    (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.rtl,
          child: Center(
            child: SizedBox(width: 40, height: 16, child: AppWidgetErrorView()),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byType(AppWidgetErrorView)),
        const Size(40, 16),
      );
    },
  );
}
