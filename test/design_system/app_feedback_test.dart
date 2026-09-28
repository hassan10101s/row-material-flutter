import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/constants/app_strings.dart';
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

    test('the empty fallback follows the app language', () {
      final wasArabic = AppText.arabic;
      addTearDown(() => AppText.arabic = wasArabic);

      AppText.arabic = true;
      expect(AppFeedback.describeError(''), 'حدث خطأ غير متوقع');

      AppText.arabic = false;
      expect(AppFeedback.describeError(''), 'Something went wrong.');
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
    Future<void> pumpLauncher(
        WidgetTester tester, void Function(BuildContext) raise) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => raise(context),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
    }

    testWidgets('an error lingers longer than a success, then auto-dismisses',
        (tester) async {
      await pumpLauncher(
          tester, (c) => AppFeedback.error(c, 'permission denied'));

      // Still readable a full 3s in - as long as a success message survives.
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(_banner), findsOneWidget);

      // Then it goes away on its own instead of sitting on screen forever.
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();
      expect(find.byKey(_banner), findsNothing);
    });

    testWidgets('a long error message is given extra time to be read',
        (tester) async {
      final long = 'DatabaseException(SqliteException(1299): while executing '
          'statement, NOT NULL constraint failed: inspections.created_by '
          '(code 1299)) ${'x' * 120}';
      expect(long.length, greaterThan(160));

      await pumpLauncher(tester, (c) => AppFeedback.error(c, long));

      // Past the 9s an error normally gets, but still readable.
      await tester.pump(const Duration(seconds: 12));
      expect(find.byKey(_banner), findsOneWidget);

      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.byKey(_banner), findsNothing);
    });

    testWidgets('a sticky message stays until it is dismissed', (tester) async {
      await pumpLauncher(
        tester,
        (c) => AppFeedback.show(c, 'permission denied',
            isError: true, sticky: true),
      );

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
