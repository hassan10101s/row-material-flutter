import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/theme/app_theme.dart';
import 'package:material_lab/design_system/tokens/app_palette.dart';

/// Both themes are built in the same pass, so nothing that *builds* a theme may
/// resolve a color through the mutable `AppColors.brightness` static.
void main() {
  // The theme scales text with ScreenUtil, which only initializes inside a
  // `ScreenUtilInit`; the app gets that from `main.dart`.
  Future<void> pumpApp(
    WidgetTester tester, {
    required ThemeMode mode,
  }) =>
      tester.pumpWidget(ScreenUtilInit(
        designSize: const Size(1280, 720),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (_, _) => MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          home: const Scaffold(body: Text('hello')),
        ),
      ));

  testWidgets('the dark theme keeps dark text on the dark surface',
      (tester) async {
    // Whatever the ambient mode happens to be, each theme must carry its own
    // text color.
    await pumpApp(tester, mode: ThemeMode.light);

    final light = AppTheme.light();
    final dark = AppTheme.dark();

    expect(light.textTheme.bodyMedium?.color, AppPalette.light.textStrong);
    expect(dark.textTheme.bodyMedium?.color, AppPalette.dark.textStrong);
    expect(dark.textTheme.bodyLarge?.color, AppPalette.dark.textStrong);
    expect(dark.textTheme.titleLarge?.color, AppPalette.dark.textStrong);
  });

  testWidgets('a dark-themed Text renders light text, whatever the ambient mode',
      (tester) async {
    // The regression: with `AppColors.brightness` left at light (the default),
    // the old text theme handed the dark theme the *light* text color.
    await pumpApp(tester, mode: ThemeMode.dark);

    final resolved =
        DefaultTextStyle.of(tester.element(find.text('hello'))).style.color;
    expect(resolved, AppPalette.dark.textStrong);
  });

  testWidgets('the light theme still renders dark text in light mode',
      (tester) async {
    await pumpApp(tester, mode: ThemeMode.light);

    final resolved =
        DefaultTextStyle.of(tester.element(find.text('hello'))).style.color;
    expect(resolved, AppPalette.light.textStrong);
  });
}

