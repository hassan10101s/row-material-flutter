import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/design_system/widgets/app_delete_confirm.dart';
import 'package:material_lab/design_system/widgets/app_search_field.dart';
import 'package:material_lab/design_system/widgets/app_status_badge.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/features/inspections/presentation/detail/widgets/inspection_widgets.dart';

/// Mobile behavior fixes: debounced ledger search and adaptive delete
/// confirmation (bottom sheet on phones, dialog on wide screens).
void main() {
  group('DebouncedSearchField', () {
    testWidgets('collapses a burst of keystrokes into one query',
        (tester) async {
      final queries = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DebouncedSearchField(
              debounce: const Duration(milliseconds: 100),
              onChanged: queries.add,
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pump(const Duration(milliseconds: 30));
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pump(const Duration(milliseconds: 30));
      await tester.enterText(find.byType(TextField), 'abc');
      // Still within the debounce window: nothing fired yet.
      expect(queries, isEmpty);
      await tester.pump(const Duration(milliseconds: 150));
      expect(queries, ['abc']);
    });

    testWidgets('fires immediately per pause, not per character',
        (tester) async {
      final queries = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DebouncedSearchField(
              debounce: const Duration(milliseconds: 50),
              onChanged: queries.add,
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'x');
      await tester.pump(const Duration(milliseconds: 80));
      await tester.enterText(find.byType(TextField), 'xy');
      await tester.pump(const Duration(milliseconds: 80));
      expect(queries, ['x', 'xy']);
    });
  });

  group('text overflow guards (400dp phone)', () {
    Future<void> pumpNarrow(
      WidgetTester tester,
      Widget child, {
      double width = 400,
    }) async {
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: const Size(400, 860),
          builder: (_, _) => MaterialApp(home: Scaffold(body: child)),
        ),
      );
      await tester.pumpAndSettle();
      // A RenderFlex overflow fails the test via the framework error
      // handler, so reaching here means nothing clipped.
      expect(tester.takeException(), isNull);
    }

    testWidgets('InfoItem caps long values inside a Wrap', (tester) async {
      const longValue =
          'مورد طويل جدا جدا جدا للاختبار مع نص عربي ممتد يفوق عرض الشاشة بكثير '
          'ويستمر في الامتداد حتى يختبر حد الالتفاف الكامل للنص الطويل';
      await pumpNarrow(
        tester,
        const Padding(
          padding: EdgeInsets.all(16),
          child: Wrap(
            spacing: 24,
            runSpacing: 8,
            children: [
              InfoItem(label: 'المورد', value: longValue),
              InfoItem(label: 'آخذ العينة', value: longValue),
            ],
          ),
        ),
      );
      expect(find.textContaining('مورد طويل'), findsWidgets);
    });

    testWidgets('status badge ellipsizes a long status in a tight cell',
        (tester) async {
      await pumpNarrow(
        tester,
        const Padding(
          padding: EdgeInsets.all(16),
          child: SizedBox(
            width: 120,
            child: AppStatusBadge(
              'حالة طويلة جدا لا تنتهي وتفوق عرض العمود المخصص لها',
            ),
          ),
        ),
      );
    });

    testWidgets('trace-style icon+text wraps instead of clipping',
        (tester) async {
      await pumpNarrow(
        tester,
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 24,
            runSpacing: 4,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    const WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: Icon(Icons.qr_code_2, size: 15),
                    ),
                    const TextSpan(
                      text:
                          ' رقم المحضر: PPRO-20260927-001-EXTRA-LONG-SUFFIX-THAT-OVERFLOWS',
                    ),
                  ],
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    });
  });

  group('AppDeleteConfirmDialog.show', () {
    Future<void> pumpSized(WidgetTester tester, double width) async {
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: Size(width, 1600),
          builder: (_, _) =>
              const MaterialApp(home: Scaffold(body: SizedBox())),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<bool?> showConfirm(WidgetTester tester) {
      return AppDeleteConfirmDialog.show(
        tester.element(find.byType(Scaffold)),
        title: 'Delete item',
        name: 'row',
      );
    }

    testWidgets('renders a bottom sheet on phone widths', (tester) async {
      await pumpSized(tester, 400);
      final future = showConfirm(tester);
      await tester.pumpAndSettle();
      // Bottom-sheet chrome on narrow screens, no centered dialog.
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(AppWindow), findsNothing);
      await tester.tap(find.text(AppStrings.delete));
      await tester.pumpAndSettle();
      expect(await future, isTrue);
    });

    testWidgets('renders a dialog on wide screens', (tester) async {
      await pumpSized(tester, 1280);
      final future = showConfirm(tester);
      await tester.pumpAndSettle();
      expect(find.byType(AppWindow), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.tap(find.text(AppStrings.delete));
      await tester.pumpAndSettle();
      expect(await future, isTrue);
    });
  });
}
