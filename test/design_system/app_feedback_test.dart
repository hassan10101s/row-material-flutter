import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/design_system/feedback/app_feedback.dart';

const _banner = ValueKey('app-feedback-banner');

void main() {
  group('describeError', () {
    test('uses the AppError message', () {
      expect(AppFeedback.describeError(const ValidationError('حقل مطلوب')),
          'حقل مطلوب');
    });

    test('unwraps a DatabaseException prefix so the banner is readable', () {
      final raw = 'DatabaseException(SqliteException(1299): while executing '
          'statement, NOT NULL constraint failed: inspections.created_by '
          '(code 1299))';
      expect(AppFeedback.describeError(raw), startsWith('SqliteException(1299)'));
      expect(AppFeedback.describeError(raw), isNot(startsWith('DatabaseException')));
    });

    test('never returns an empty string', () {
      expect(AppFeedback.describeError(''), isNotEmpty);
      expect(AppFeedback.describeError(const AppError('  ')), isNotEmpty);
    });
  });

  group('placement', () {
    testWidgets('renders in the root overlay, above a pushed route', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (pageContext) => Scaffold(
                      body: Builder(
                        builder: (inner) => ElevatedButton(
                          onPressed: () => AppFeedback.error(inner, 'boom'),
                          child: const Text('fail'),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('push'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('push'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('fail'));
      await tester.pump();

      expect(find.text('boom'), findsOneWidget);
      // The banner belongs to the root overlay, not to the pushed page: it is a
      // sibling of the Navigator's route, not a descendant of the second page.
      final bannerInPushedPage = find.descendant(
        of: find.text('fail'),
        matching: find.byKey(_banner),
      );
      expect(bannerInPushedPage, findsNothing);
    });

    testWidgets('sits at the top of the screen', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(child: TextButton(
              onPressed: () => AppFeedback.info(context, 'hello'),
              child: const Text('go'),
            )),
          ),
        ),
      ));

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      final top = tester.getTopLeft(find.byKey(_banner));
      expect(top.dy, lessThan(40), reason: 'the banner must be at the top');
    });
  });

  group('dismissal', () {
    testWidgets('an error stays until it is dismissed', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => AppFeedback.error(context, 'permission denied'),
              child: const Text('go'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('go'));
      await tester.pump();

      // Well past the old four-second SnackBar duration.
      await tester.pump(const Duration(seconds: 20));
      expect(find.byKey(_banner), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byKey(_banner), findsNothing);
    });

    testWidgets('a success message auto-dismisses', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => AppFeedback.success(context, 'saved'),
              child: const Text('go'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('go'));
      await tester.pump();
      expect(find.byKey(_banner), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.byKey(_banner), findsNothing);
    });

    testWidgets('a new message replaces the current one', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ));

      AppFeedback.info(context, 'first');
      await tester.pump();
      expect(find.text('first'), findsOneWidget);

      AppFeedback.error(context, 'second');
      await tester.pumpAndSettle();
      expect(find.text('first'), findsNothing);
      expect(find.text('second'), findsOneWidget);
      expect(find.byKey(_banner), findsOneWidget);
    });

    testWidgets('an empty message shows nothing', (tester) async {
      late BuildContext context;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ));

      AppFeedback.error(context, '   ');
      await tester.pump();
      expect(find.byKey(_banner), findsNothing);
    });
  });
}
