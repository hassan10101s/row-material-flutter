import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/l10n/generated/app_localizations.dart';
import 'package:material_lab/features/dashboard/presentation/widgets/dashboard_sticky_nav_bar.dart';

Widget _pump(double textScale, void Function(String) onGo) {
  // Production harness: main.dart's MediaQuery -> ScreenUtilInit(1280x720)
  // -> MaterialApp; dashboard_screen.dart's CustomScrollView + pinned header.
  return ScreenUtilInit(
    designSize: const Size(1280, 720),
    minTextAdapt: true,
    builder: (_, _) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: DashboardStickyNavBar(
                onGo: onGo,
                topPadding: 24,
                period: '7d',
                onPeriodChange: (_) {},
                filterCount: 0,
                onOpenFilter: () {},
                onRefresh: () async {},
                refreshing: true,
                textScale: textScale,
              ),
            ),
            SliverToBoxAdapter(child: SizedBox.shrink()),
          ],
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => AppText.useLanguage('en'));

  testWidgets('measure natural row heights', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1253.2, 900);
    addTearDown(tester.view.reset);

    for (final ts in [1.0, 1.1, 1.2, 1.3]) {
      final delegate = DashboardStickyNavBar(
        onGo: (_) {},
        topPadding: 24,
        period: '7d',
        onPeriodChange: (_) {},
        filterCount: 0,
        onOpenFilter: () {},
        onRefresh: () async {},
        refreshing: true,
        textScale: ts,
      );
      // ignore: avoid_print
      print('ts=$ts contentExtent=${delegate.contentExtent}');
      await tester.pumpWidget(_pump(ts, (String _) {}));
      await tester.pump();

      final rows = find.descendant(
        of: find.byType(SliverPersistentHeader).first,
        matching: find.bySubtype<SingleChildScrollView>(),
      );
      var i = 0;
      for (final r in rows.evaluate()) {
        final size = r.size;
        // ignore: avoid_print
        print('  ts=$ts row$i h=$size');
        i++;
      }
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getSize(
              find
                  .descendant(
                    of: find.byType(SliverPersistentHeader),
                    matching: find.byType(SizedBox),
                  )
                  .first,
            )
            .height,
        delegate.contentExtent,
      );
    }
  });
}
