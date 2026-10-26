import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/core/responsive/layout_spec.dart';
import 'package:material_lab/core/responsive/responsive_scope.dart';
import 'package:material_lab/core/theme/app_theme.dart';
import 'package:material_lab/design_system/tokens/app_colors.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';
import 'package:material_lab/design_system/widgets/app_card.dart';
import 'package:material_lab/design_system/widgets/app_field.dart';
import 'package:material_lab/design_system/widgets/app_page_header.dart';
import 'package:material_lab/design_system/widgets/app_paginated_table.dart';
import 'package:material_lab/design_system/widgets/app_select_field.dart';
import 'package:material_lab/design_system/widgets/app_status_badge.dart';
import 'package:material_lab/design_system/widgets/app_text_field.dart';
import 'package:material_lab/design_system/widgets/app_window.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required bool mobile,
  Size? size,
  Brightness brightness = Brightness.light,
}) async {
  FormFactor.debugSet(mobile ? AppFormFactor.mobile : AppFormFactor.desktop);
  AppColors.brightness = brightness;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize =
      size ?? (mobile ? const Size(400, 900) : const Size(1000, 800));
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() {
    FormFactor.debugSet(null);
    AppColors.brightness = Brightness.light;
  });
  await tester.pumpWidget(
    ResponsiveScope(
      spec: mobile ? LayoutSpec.mobile : LayoutSpec.desktop,
      child: ScreenUtilInit(
        designSize: mobile ? const Size(400, 860) : const Size(1280, 720),
        builder: (_, _) => MaterialApp(
          theme: brightness == Brightness.dark
              ? AppTheme.dark()
              : AppTheme.light(),
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Scaffold(body: child),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'Cairo',
    )..addFont(rootBundle.load('assets/fonts/Cairo-Variable.ttf'))).load();
  });

  testWidgets('snapped desktop controls retain their authored size', (
    tester,
  ) async {
    await _pump(
      tester,
      AppButton(label: 'حفظ', small: true, onPressed: () {}),
      mobile: false,
      size: const Size(640, 720),
    );
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.style!.minimumSize!.resolve({})!.height, 34);
    final context = tester.element(find.byType(AppButton));
    final border =
        Theme.of(context).inputDecorationTheme.enabledBorder
            as OutlineInputBorder;
    expect(border.borderRadius, BorderRadius.circular(8));
    expect(tester.takeException(), isNull);
  });

  testWidgets('all mobile button styles retain a 48dp visual target', (
    tester,
  ) async {
    await _pump(
      tester,
      Wrap(
        children: [
          for (final style in AppButtonStyle.values)
            AppButton(
              label: 'تنفيذ',
              style: style,
              small: true,
              onPressed: () {},
            ),
        ],
      ),
      mobile: true,
    );
    for (final element
        in find
            .byWidgetPredicate((w) => w is FilledButton || w is TextButton)
            .evaluate()) {
      final button = element.widget as ButtonStyleButton;
      expect(button.style!.minimumSize!.resolve({})!.height, 48);
    }
    expect(tester.takeException(), isNull);
  });

  for (final mobile in [false, true]) {
    testWidgets(
      'dialog returns its result with ${mobile ? 'phone keyboard' : 'desktop chrome'}',
      (tester) async {
        String? result;
        await _pump(
          tester,
          Builder(
            builder: (context) => AppButton(
              label: 'افتح',
              onPressed: () async {
                result = await showAppDialog<String>(
                  context,
                  builder: (overlay) => AppDialog(
                    title: 'إعدادات التقرير وتفاصيل الفحص الطويلة',
                    icon: Icons.description_outlined,
                    leadingActions: [AppButton(label: 'مسح', onPressed: () {})],
                    actions: [
                      AppButton(
                        label: 'إلغاء التغييرات الحالية',
                        onPressed: () => Navigator.pop(overlay),
                      ),
                      AppButton(
                        label: 'حفظ وإكمال التقرير',
                        onPressed: () => Navigator.pop(overlay, 'saved'),
                      ),
                    ],
                    child: AppField(
                      label: 'ملاحظة',
                      initialValue: 'القيمة محفوظة',
                      autofocus: true,
                    ),
                  ),
                );
              },
            ),
          ),
          mobile: mobile,
          size: mobile ? const Size(320, 700) : const Size(800, 700),
        );
        if (mobile) tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        addTearDown(tester.view.resetViewInsets);
        await tester.tap(find.text('افتح'));
        await tester.pumpAndSettle();
        expect(
          find.byType(BottomSheet),
          mobile ? findsOneWidget : findsNothing,
        );
        expect(find.byType(Dialog), mobile ? findsNothing : findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('حفظ وإكمال التقرير'));
        await tester.pumpAndSettle();
        expect(result, 'saved');
      },
    );
  }

  for (final mobile in [false, true]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'shared surfaces render ${mobile ? 'mobile' : 'desktop'} ${brightness.name} in RTL',
        (tester) async {
          final capture = GlobalKey();
          await _pump(
            tester,
            RepaintBoundary(
              key: capture,
              child: _Gallery(mobile: mobile),
            ),
            mobile: mobile,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          if (const bool.fromEnvironment('CAPTURE_DESIGN_PREVIEWS')) {
            await tester.runAsync(() async {
              final boundary =
                  capture.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final shot = await boundary.toImage();
              final bytes = await shot.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final dir = Directory('.dart_tool/design_previews')
                ..createSync(recursive: true);
              File(
                '${dir.path}/${mobile ? 'mobile' : 'desktop'}_${brightness.name}.png',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
              shot.dispose();
            });
          }
        },
      );
    }
  }
}

class _Gallery extends StatelessWidget {
  const _Gallery({required this.mobile});
  final bool mobile;
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        AppPageHeader(
          title: 'سجل الفحوصات',
          subtitle: 'Material Lab · مساحة عمل موحدة',
          icon: Icons.science_outlined,
          actions: [
            AppButton(
              label: 'فحص جديد',
              icon: const Icon(Icons.add),
              onPressed: () {},
            ),
          ],
        ),
        const SizedBox(height: 20),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'بيانات العينة',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              AppField(label: 'اسم المادة', initialValue: 'قمح محلي'),
              const SizedBox(height: 16),
              AppSelectField<String>(
                initialValue: 'review',
                decoration: const InputDecoration(labelText: 'حالة الفحص'),
                items: const [
                  DropdownMenuItem(
                    value: 'review',
                    child: Text('قيد المراجعة'),
                  ),
                ],
                onChanged: (_) {},
              ),
              const SizedBox(height: 16),
              const AppTextField(
                decoration: InputDecoration(
                  labelText: 'ملاحظة',
                  hintText: 'أضف ملاحظة للفريق',
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  AppButton(label: 'حفظ الفحص', onPressed: () {}),
                  AppButton(
                    label: 'معاينة التقرير',
                    style: AppButtonStyle.secondary,
                    onPressed: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (mobile)
          const AppCard(
            child: Row(
              children: [
                Expanded(child: Text('قمح محلي · ML-1024')),
                AppStatusBadge('APPROVED'),
              ],
            ),
          )
        else
          const AppPaginatedTable(
            height: 210,
            headers: ['رقم القيد', 'المادة', 'حالة الفحص'],
            rows: [
              [Text('ML-1024'), Text('قمح محلي'), AppStatusBadge('APPROVED')],
              [Text('ML-1025'), Text('ذرة صفراء'), AppStatusBadge('PENDING')],
            ],
          ),
      ],
    ),
  );
}
