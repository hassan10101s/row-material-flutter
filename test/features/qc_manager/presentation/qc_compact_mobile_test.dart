import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_adaptive_list.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';
import 'package:material_lab/features/qc_manager/presentation/routine/routine_list_editor.dart';
import 'package:material_lab/features/qc_manager/presentation/custom_tables/qc_table_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Cairo',
    )..addFont(rootBundle.load('assets/fonts/Cairo-Variable.ttf'))).load();
  });
  tearDown(() {
    FormFactor.debugSet(null);
    AppText.useLanguage('ar');
  });
  for (final arabic in [false, true]) {
    for (final scale in [1.0, 1.5]) {
      testWidgets('quality compact rows fit phone arabic=$arabic text=$scale', (
        tester,
      ) async {
        FormFactor.debugSet(AppFormFactor.mobile);
        AppText.useLanguage(arabic ? 'ar' : 'en');
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        int? opened;
        var actions = 0;
        const preview = ValueKey('qc-mobile-preview');
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: const Size(1280, 800),
            builder: (_, _) => MaterialApp(
              theme: ThemeData(fontFamily: 'Cairo'),
              home: MediaQuery(
                data: MediaQueryData(
                  size: const Size(390, 844),
                  textScaler: TextScaler.linear(scale),
                ),
                child: Directionality(
                  textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
                  child: RepaintBoundary(
                    key: preview,
                    child: Scaffold(
                      appBar: AppBar(
                        title: Text(arabic ? 'قوائم الجودة' : 'Quality lists'),
                      ),
                      body: AppAdaptiveDataView(
                        compactMobile: true,
                        mobileTrailingColumn: 4,
                        headers: arabic
                            ? [
                                'القائمة',
                                'القسم',
                                'التكرار',
                                'الإنجاز',
                                'إجراءات',
                              ]
                            : ['List', 'Dept', 'Repeat', 'Done', 'Actions'],
                        onRowTap: (index) => opened = index,
                        rows: [
                          for (var i = 0; i < 12; i++)
                            AppDataRow(
                              cells: [
                                Text(
                                  arabic
                                      ? 'فحص نظافة منطقة الإنتاج $i'
                                      : 'Production cleanliness $i',
                                  key: ValueKey('title-$i'),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  arabic ? 'الإنتاج' : 'Production',
                                  maxLines: 1,
                                ),
                                Text(arabic ? 'يومية' : 'Daily', maxLines: 1),
                                const Text('2/10'),
                                IconButton(
                                  tooltip: 'Actions $i',
                                  onPressed: () => actions++,
                                  icon: const Icon(Icons.more_vert),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final first = tester.getRect(find.byKey(const ValueKey('title-0')));
        final second = tester.getRect(find.byKey(const ValueKey('title-1')));
        expect(second.top - first.top, lessThan(scale == 1 ? 115 : 185));
        final actionSize = tester.getSize(find.byTooltip('Actions 0'));
        expect(actionSize.width, greaterThanOrEqualTo(48));
        expect(actionSize.height, greaterThanOrEqualTo(48));
        await tester.tap(find.byKey(const ValueKey('title-0')));
        expect(opened, 0);
        await tester.tap(find.byTooltip('Actions 0'));
        expect(actions, 1);
        expect(tester.takeException(), isNull);
        if (arabic && scale == 1) {
          await tester.pump();
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(preview),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await Directory('build/qc_mobile_preview').create(recursive: true);
            await File(
              'build/qc_mobile_preview/quality_lists_ar.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      });
    }
  }

  for (final desktop in [false, true]) {
    for (final table in [false, true]) {
      testWidgets(
        'quality editor uses shared surface desktop=$desktop table=$table',
        (tester) async {
          FormFactor.debugSet(
            desktop ? AppFormFactor.desktop : AppFormFactor.mobile,
          );
          tester.view.physicalSize = desktop
              ? const Size(1280, 900)
              : const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            ScreenUtilInit(
              designSize: const Size(1280, 800),
              builder: (_, _) => MaterialApp(
                home: Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      onPressed: () => table
                          ? showQcTableEditor(context)
                          : showRoutineListEditor(context),
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await tester.pumpAndSettle();
          expect(find.byType(AppWindow), findsOneWidget);
          expect(
            tester.widget<AppWindow>(find.byType(AppWindow)).fullScreen,
            !desktop,
          );
          expect(tester.takeException(), isNull);
          if (desktop) {
            await tester.tap(find.byTooltip('Close'));
          } else {
            await tester.pageBack();
          }
          await tester.pumpAndSettle();
          expect(find.byType(AppWindow), findsNothing);
        },
      );
    }
  }
}
