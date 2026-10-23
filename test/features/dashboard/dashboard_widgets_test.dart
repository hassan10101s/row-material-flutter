import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/features/dashboard/domain/dashboard_kpis.dart';
import 'package:material_lab/features/dashboard/presentation/cubit/dashboard_kpis_state.dart';
import 'package:material_lab/features/dashboard/presentation/sections/ncr_section.dart';
import 'package:material_lab/features/dashboard/presentation/sections/supplier_scorecard_section.dart';
import 'package:material_lab/features/dashboard/presentation/widgets/dashboard_result_line.dart';

Widget _pump(Widget child) {
  // .sp / .r / .spMax helpers need a ScreenUtil design size.
  return ScreenUtilInit(
    designSize: const Size(1280, 800),
    minTextAdapt: true,
    builder: (_, __) => MaterialApp(
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppText.useLanguage('en'));

  group('DashboardResultLine', () {
    testWidgets('zero results with active filters offer a clear CTA',
        (tester) async {
      var cleared = 0;
      await tester.pumpWidget(_pump(
        DashboardResultLine(
          summary: const {
            'filtered_count': 0,
            'latest': {'label': 'Wheat', 'date': '2026-10-01'},
          },
          filtersActive: true,
          onClearFilters: () => cleared++,
        ),
      ));

      expect(find.text('No matches with the current filters'), findsOneWidget);
      expect(find.text('Clear filters'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      expect(cleared, 1);
    });

    testWidgets(
        'zero results without filters keep the count line (no clear CTA)',
        (tester) async {
      await tester.pumpWidget(_pump(
        DashboardResultLine(summary: const {'filtered_count': 0}),
      ));

      expect(find.text('0 inspections in period'), findsOneWidget);
      expect(find.text('Clear filters'), findsNothing);
    });

    testWidgets('non-empty period shows the result line only', (tester) async {
      await tester.pumpWidget(_pump(
        DashboardResultLine(
          summary: const {'filtered_count': 12},
          filtersActive: true,
          onClearFilters: () {},
        ),
      ));

      expect(find.text('12 inspections in period'), findsOneWidget);
      expect(find.text('No matches with the current filters'), findsNothing);
    });
  });

  group('SupplierRow drill-down', () {
    testWidgets('tapping the row fires the supplied callback', (tester) async {
      var opened = 0;
      await tester.pumpWidget(_pump(
        SupplierRow(
          score: const SupplierScore(
            name: 'Acme',
            total: 10,
            approvalRate: 90,
            tier: 'A',
            score: 92,
          ),
          maxScore: 100,
          rank: 1,
          onTap: () => opened++,
        ),
      ));

      await tester.tap(find.text('Acme').last);
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('without a callback the row stays inert', (tester) async {
      await tester.pumpWidget(_pump(
        SupplierRow(
          score: const SupplierScore(
            name: 'Bloor',
            total: 5,
            tier: 'B',
            score: 60,
          ),
          maxScore: 100,
          rank: 2,
        ),
      ));

      await tester.tap(find.text('Bloor').last);
      await tester.pump();
      // No exceptions: a null onTap is always allowed to be tapped.
      expect(find.text('Bloor'), findsWidgets);
    });
  });

  group('NcrSection', () {
    testWidgets('hidden entirely when the NCR bundle is empty', (tester) async {
      await tester.pumpWidget(
        _pump(NcrSection(kpi: const DashboardKpisState())),
      );

      expect(find.text('Issues & fixes'), findsNothing);
    });

    testWidgets('Open and Overdue cards render for a non-empty bundle',
        (tester) async {
      await tester.pumpWidget(
        _pump(
          NcrSection(
            kpi: const DashboardKpisState(
              bundle: DashboardBundle(
                ncr: NcrKpisSummary(
                  total: 9,
                  open: 4,
                  overdue: 2,
                  overduePct: 22.2,
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Issues & fixes'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Overdue'), findsOneWidget);
    });
  });
}
