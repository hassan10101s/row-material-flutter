import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';
import 'package:material_lab/features/qc_manager/domain/qc_custom_table.dart';
import 'package:material_lab/features/qc_manager/presentation/custom_tables/qc_table_editor.dart';

void main() {
  for (final formFactor in [AppFormFactor.mobile, AppFormFactor.desktop]) {
    testWidgets(
      '$formFactor disables the tenth column and re-enables after removal',
      (tester) async {
        AppText.useLanguage('en');
        FormFactor.debugSet(formFactor);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 1600);
        addTearDown(() {
          tester.view.reset();
          FormFactor.debugSet(AppFormFactor.desktop);
        });
        const now = '2026-10-29';
        final fields = List.generate(
          8,
          (i) => QcCustomTableField(
            fieldId: i + 1,
            label: 'Column $i',
            colType: QcCustomColType.text,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: const Size(1280, 900),
            builder: (_, child) => MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showQcTableEditor(context, (
                      table: const QcCustomTable(
                        title: 'Nine columns',
                        createdAt: now,
                        updatedAt: now,
                      ),
                      fields: fields,
                    )),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final add = find.widgetWithText(AppButton, 'Add column');
        await tester.ensureVisible(add);
        expect(tester.widget<AppButton>(add).onPressed, isNotNull);
        await tester.tap(add);
        await tester.pumpAndSettle();
        expect(tester.widget<AppButton>(add).onPressed, isNull);
        expect(find.text('9 of 9 columns maximum'), findsOneWidget);
        final remove = find.byIcon(Icons.remove_circle_outline).last;
        await tester.ensureVisible(remove);
        await tester.tap(remove);
        await tester.pumpAndSettle();
        expect(tester.widget<AppButton>(add).onPressed, isNotNull);
        expect(find.text('8 of 9 columns maximum'), findsOneWidget);
      },
    );
  }
}
