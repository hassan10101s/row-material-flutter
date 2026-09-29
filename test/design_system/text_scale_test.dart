import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/theme/app_theme.dart';
import 'package:material_lab/design_system/tokens/app_text_theme.dart';

/// Cover for the app-wide text-scale cap.
///
/// The app builds its font sizes with ScreenUtil's `sp`, which multiplies the
/// design size by the platform text scale. Left unbounded, a user at a 200%
/// system font got `RenderFlex` / `RenderParagraph` overflows out of the
/// fixed-height row slots in the reference and lab tables. `main.dart` clamps
/// the scale in two places because the two text-size sources read it from
/// different places.
void main() {
  group('AppTextTheme.clamp', () {
    test('leaves a normal scale untouched', () {
      expect(AppTextTheme.clamp(TextScaler.noScaling).scale(10), 10);
      expect(AppTextTheme.clamp(const TextScaler.linear(1.0)).scale(10), 10);
    });

    test('caps growth at the documented maximum', () {
      expect(
        AppTextTheme.clamp(const TextScaler.linear(2.0)).scale(10),
        closeTo(10 * AppTextTheme.maxTextScaleFactor, 1e-9),
      );
    });

    test('a 400% scale hits the same cap, not something larger', () {
      expect(
        AppTextTheme.clamp(const TextScaler.linear(4.0)).scale(10),
        closeTo(10 * AppTextTheme.maxTextScaleFactor, 1e-9),
      );
    });

    test('allows a slight shrink for dense tables', () {
      expect(
        AppTextTheme.clamp(const TextScaler.linear(0.8)).scale(10),
        closeTo(10 * AppTextTheme.minTextScaleFactor, 1e-9),
      );
    });

    test('is monotonic in the system scale', () {
      double scaledAt(double s) =>
          AppTextTheme.clamp(TextScaler.linear(s)).scale(10);
      var previous = 0.0;
      for (final s in [0.5, 0.8, 0.9, 1.0, 1.2, 1.3, 1.6, 2.0, 4.0]) {
        final current = scaledAt(s);
        expect(
          current,
          greaterThanOrEqualTo(previous),
          reason: 'not monotonic at $s',
        );
        previous = current;
      }
    });
  });

  group('main.dart applies the clamp in both places', () {
    /// Reproduces main.dart's nesting: MediaQuery -> ScreenUtilInit ->
    /// MaterialApp -> builder MediaQuery.
    Widget harness(TextScaler systemScale) => MediaQuery(
      data: MediaQueryData(textScaler: systemScale),
      child: ScreenUtilInit(
        designSize: const Size(1280, 720),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (context, _) => MediaQuery(
          // Above MaterialApp, for the sp-derived theme sizes.
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: AppTextTheme.clampScaler(context)),
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery(
              // Below MaterialApp, for the body text and every overlay.
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: AppTextTheme.clampScaler(context)),
              child: child!,
            ),
            home: const Scaffold(body: Center(child: Text('Material Lab'))),
          ),
        ),
      ),
    );

    testWidgets('a 200% system font is capped in the body text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 720);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(const TextScaler.linear(2.0)));
      await tester.pump();

      final context = tester.element(find.text('Material Lab'));
      expect(
        MediaQuery.textScalerOf(context).scale(16),
        closeTo(16 * AppTextTheme.maxTextScaleFactor, 1e-6),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the theme scales by the same clamped factor as the body', (
      tester,
    ) async {
      // Guards the reason the clamp sits above ScreenUtilInit: clamping only
      // below MaterialApp left the sp-derived theme at the raw 2.0 while the
      // body text used 1.3, so headers and their rows disagreed.
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 720);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(const TextScaler.linear(2.0)));
      await tester.pump();

      final bodyLarge = Theme.of(
        tester.element(find.text('Material Lab')),
      ).textTheme.bodyLarge!;
      expect(
        bodyLarge.fontSize! * AppTextTheme.maxTextScaleFactor,
        greaterThan(bodyLarge.fontSize!),
        reason: 'theme sizes are scaled by ScreenUtil from the clamped factor',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a normal system font is left alone', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 720);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(const TextScaler.linear(1.0)));
      await tester.pump();

      final context = tester.element(find.text('Material Lab'));
      expect(MediaQuery.textScalerOf(context).scale(16), closeTo(16, 1e-6));
    });
  });
}
