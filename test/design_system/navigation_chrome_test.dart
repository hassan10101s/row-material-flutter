import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_top_app_bar.dart';

void main() {
  tearDown(() => FormFactor.debugSet(null));
  for (final mobile in [true, false]) {
    final sizes = mobile
        ? [const Size(390, 844), const Size(844, 420)]
        : [const Size(1280, 900), const Size(540, 720)];
    for (final size in sizes) {
      for (final direction in TextDirection.values) {
        testWidgets(
          '${mobile ? 'phone' : 'Windows'} ${size.width} $direction keeps compact back geometry',
          (tester) async {
            FormFactor.debugSet(
              mobile ? AppFormFactor.mobile : AppFormFactor.desktop,
            );
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              ScreenUtilInit(
                designSize: mobile
                    ? const Size(400, 860)
                    : const Size(1280, 720),
                minTextAdapt: true,
                builder: (_, _) => MaterialApp(
                  builder: (_, child) =>
                      Directionality(textDirection: direction, child: child!),
                  home: Builder(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        child: const Text('open'),
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => Scaffold(
                              appBar: const AppTopAppBar(title: 'Editor'),
                              body: const Text('Content'),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.tap(find.text('open'));
            await tester.pumpAndSettle();
            final bar = tester.widget<AppBar>(find.byType(AppBar));
            expect(
              tester.getSize(find.byType(AppBar)).height,
              mobile ? 48 : 56,
            );
            expect(bar.centerTitle, !mobile);
            if (mobile) {
              expect(tester.getSize(find.byType(BackButton)).width, 48);
              expect(
                tester.widget<Text>(find.text('Editor')).style!.fontSize,
                18,
              );
            }
            expect(tester.getRect(find.text('Content')).top, mobile ? 48 : 56);
            await tester.tap(find.byType(BackButton));
            await tester.pumpAndSettle();
            expect(find.text('open'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
