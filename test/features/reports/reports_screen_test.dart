import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';
import 'package:material_lab/features/reports/data/report_service.dart';
import 'package:material_lab/features/reports/presentation/cubit/reports_cubit.dart';
import 'package:material_lab/features/reports/presentation/reports_screen.dart';

class _ReportServiceMock extends Mock implements ReportService {}

void main() {
  late _ReportServiceMock repo;
  late ReportsCubit cubit;

  setUp(() {
    // The UI strings are chosen by a global; pin them so the finders below are
    // stable.
    AppText.useLanguage('en');
    repo = _ReportServiceMock();
    cubit = ReportsCubit(repo: repo);
  });

  tearDown(() => cubit.close());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(ScreenUtilInit(
      designSize: const Size(1280, 720),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (_, _) => BlocProvider<ReportsCubit>.value(
        value: cubit,
        child: const MaterialApp(home: Scaffold(body: ReportsScreen())),
      ),
    ));
  }

  /// Text fields are addressed by their `labelText`, which is decoration data
  /// rather than a `Text` descendant.
  Finder field(String label) => find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == label,
        description: 'TextField labelled "$label"',
      );

  /// The three export buttons, in screen order: daily, monthly, yearly.
  ///
  /// Addressed by [AppButton] rather than by a Material button class. The
  /// screen owns these three controls; which of `FilledButton` /
  /// `OutlinedButton` / `TextButton` backs a given style is a detail of the
  /// design system, and pinning a test to it means a change there breaks
  /// unrelated report tests.
  Finder button(int index) => find.byType(AppButton).at(index);

  group('report period fields', () {
    testWidgets('the monthly and yearly year fields are independent',
        (tester) async {
      await pump(tester);

      // Two "Year" fields, one per card. They used to share a controller, so
      // typing in one rewrote the other.
      expect(field('Year'), findsNWidgets(2));

      await tester.enterText(field('Year').first, '2021');
      await tester.pump();

      final years = tester
          .widgetList<TextField>(find.byType(TextField))
          .where((f) => f.decoration?.labelText == 'Year')
          .map((f) => f.controller?.text)
          .toList();
      expect(years, ['2021', isNot('2021')]);
    });

    testWidgets('a non-numeric year shows an error and exports nothing',
        (tester) async {
      await pump(tester);

      await tester.enterText(field('Year').last, '20O5');
      await tester.pump();

      await tester.tap(button(2));
      await tester.pump();

      expect(find.text('Enter a valid year'), findsOneWidget);
      verifyNever(() => repo.yearlyReport(year: any(named: 'year')));
    });

    testWidgets('a valid year exports the requested year', (tester) async {
      await pump(tester);

      when(() => repo.yearlyReport(year: any(named: 'year'))).thenAnswer(
          (_) async => ReportDoc(filename: 'y.pdf', bytes: Uint8List(0)));

      await tester.enterText(field('Year').last, '2024');
      await tester.pump();

      await tester.tap(button(2));
      await tester.pumpAndSettle();

      verify(() => repo.yearlyReport(year: 2024)).called(1);
    });

    testWidgets('an out-of-range month is rejected instead of defaulting',
        (tester) async {
      await pump(tester);

      await tester.enterText(field('Month (1-12)'), '13');
      await tester.pump();

      await tester.tap(button(1));
      await tester.pump();

      expect(find.text('Enter a month between 1 and 12'), findsOneWidget);
      verifyNever(() => repo.monthlyReport(
          month: any(named: 'month'), year: any(named: 'year')));
    });

    testWidgets('a valid month and year export that exact period',
        (tester) async {
      await pump(tester);

      when(() => repo.monthlyReport(month: any(named: 'month'), year: any(named: 'year')))
          .thenAnswer(
              (_) async => ReportDoc(filename: 'm.pdf', bytes: Uint8List(0)));

      await tester.enterText(field('Month (1-12)'), '3');
      await tester.enterText(field('Year').first, '2024');
      await tester.pump();

      await tester.tap(button(1));
      await tester.pumpAndSettle();

      verify(() => repo.monthlyReport(month: 3, year: 2024)).called(1);
    });

    testWidgets('an impossible calendar date is rejected', (tester) async {
      await pump(tester);

      // 2026 is not a leap year: DateTime would silently roll Feb 31 to Mar 3.
      await tester.enterText(field('Date (YYYY-MM-DD)'), '2026-02-31');
      await tester.pump();

      await tester.tap(button(0));
      await tester.pump();

      expect(find.text('Enter a valid date as YYYY-MM-DD'), findsOneWidget);
      verifyNever(() => repo.dailyReport(any()));
    });

    testWidgets('a valid daily date is exported verbatim', (tester) async {
      await pump(tester);

      when(() => repo.dailyReport(any()))
          .thenAnswer((_) async => ReportDoc(filename: 'd.pdf', bytes: Uint8List(0)));

      await tester.enterText(field('Date (YYYY-MM-DD)'), '2026-02-28');
      await tester.pump();

      await tester.tap(button(0));
      await tester.pumpAndSettle();

      verify(() => repo.dailyReport('2026-02-28')).called(1);
    });
  });
}
