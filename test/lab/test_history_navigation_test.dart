import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:material_lab/app/auth_gate.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/core/responsive/form_factor.dart';
import 'package:material_lab/di/service_locator.dart';
import 'package:material_lab/features/lab/presentation/test_history/test_history_detail_screen.dart';

class _Gate extends Mock implements AuthGate {}

void main() {
  setUpAll(() => registerFallbackValue(Permission.labResultsUpdate));
  tearDown(() async {
    FormFactor.debugSet(null);
    AppText.useLanguage('ar');
    await getIt.reset();
  });
  for (final mobile in [true, false]) {
    testWidgets(
      '${mobile ? 'phone' : 'desktop'} test details retain read-only permissions and return to history',
      (tester) async {
        FormFactor.debugSet(
          mobile ? AppFormFactor.mobile : AppFormFactor.desktop,
        );
        AppText.useLanguage('en');
        final gate = _Gate();
        when(() => gate.canWrite(any())).thenReturn(false);
        getIt.registerSingleton<AuthGate>(gate);
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(1280, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        bool? edited;
        await tester.pumpWidget(
          ScreenUtilInit(
            designSize: mobile ? const Size(390, 844) : const Size(1280, 900),
            builder: (_, _) => MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async =>
                        edited = await TestHistoryDetailScreen.open(context, {
                          'id': 1,
                          'analysis_name': 'pH',
                          'sample_name': 'S1',
                          'result_text': '6.5',
                        }),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), mobile ? findsNothing : findsOneWidget);
        expect(find.text('Test details'), findsOneWidget);
        expect(
          find.text('Read-only — editing lab results requires permission.'),
          findsOneWidget,
        );
        expect(find.text('Save changes'), findsNothing);
        await tester.tap(
          mobile ? find.byType(BackButton) : find.byIcon(Icons.close),
        );
        await tester.pumpAndSettle();
        expect(edited, false);
        expect(find.text('open'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
