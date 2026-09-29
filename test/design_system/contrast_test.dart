import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/theme/app_theme.dart';
import 'package:material_lab/design_system/tokens/app_colors.dart';
import 'package:material_lab/design_system/tokens/app_contrast.dart';
import 'package:material_lab/design_system/tokens/app_palette.dart';
import 'package:material_lab/design_system/widgets/app_button.dart';

/// Regression cover for the contrast defects the theme used to carry.
///
/// `AppTheme` built its `ColorScheme` with `ColorScheme.fromSeed` and then
/// overrode `primary` / `secondary` / `surface` / `error` by hand. The `on*`
/// roles stayed as `fromSeed` derived them, so they described the seed, not the
/// colors actually painted. `AppButton` sidestepped them entirely and hardcoded
/// `Colors.white` on all five filled variants, which is 2.14:1 on the dark
/// palette's primary and 4.09:1 on the light palette's — both below the WCAG AA
/// 4.5:1 floor for normal text.
void main() {
  /// Builds a pumped tree with the app theme already applied.
  ///
  /// The child is a builder rather than a widget on purpose: `AppTheme`
  /// scales its text with ScreenUtil, and ScreenUtil only initializes inside
  /// `ScreenUtilInit`. Constructing the theme as an *argument* would evaluate
  /// it before the init ran and throw
  /// `LateInitializationError: Field '_minTextAdapt' has not been
  /// initialized`.
  Widget harness(Widget Function(ThemeData theme) build) => ScreenUtilInit(
        designSize: const Size(1280, 720),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (_, _) {
          final theme = AppTheme.light();
          return MaterialApp(
            theme: theme,
            home: Scaffold(body: Center(child: build(theme))),
          );
        },
      );

  group('AppContrast', () {
    test('matches the known WCAG reference values', () {
      expect(AppContrast.ratio(Colors.white, Colors.black), closeTo(21, 0.01));
      expect(AppContrast.ratio(Colors.white, Colors.white), closeTo(1, 0.01));
    });

    test('is order independent', () {
      const a = Color(0xFF0284C7);
      const b = Color(0xFFF3F6FB);
      expect(AppContrast.ratio(a, b), closeTo(AppContrast.ratio(b, a), 1e-9));
    });

    test('on() always returns a foreground that clears AA', () {
      for (final palette in [AppPalette.light, AppPalette.dark]) {
        for (final background in <Color>[
          palette.primary,
          palette.primaryDeep,
          palette.accent,
          palette.success,
          palette.warning,
          palette.partial,
          palette.danger,
          palette.info,
          palette.whatsapp,
          palette.pdf,
        ]) {
          final fg = AppContrast.on(background);
          expect(
            AppContrast.passes(fg, background),
            isTrue,
            reason: 'on($background) = $fg is only '
                '${AppContrast.ratio(fg, background).toStringAsFixed(2)}:1',
          );
        }
      }
    });

    test('reproduces the dark-mode primary failure it was written for', () {
      // Documents why this exists: white on the dark primary is 2.14:1.
      const darkPrimary = Color(0xFF38BDF8);
      expect(
        AppContrast.ratio(Colors.white, darkPrimary),
        lessThan(AppContrast.aa),
      );
      expect(AppContrast.on(darkPrimary), isNot(Colors.white));
    });
  });

  group('ColorScheme on* roles are derived, not inherited from the seed', () {
    /// Asserts the given scheme roles clear AA against the background they
    /// actually paint on, in both brightnesses.
    void expectClearsAa(
      Color Function(ColorScheme) foreground,
      Color Function(ColorScheme) background,
      String what,
    ) {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final fg = foreground(theme.colorScheme);
        final bg = background(theme.colorScheme);
        expect(
          AppContrast.passes(fg, bg),
          isTrue,
          reason: '${theme.brightness} $what is only '
              '${AppContrast.ratio(fg, bg).toStringAsFixed(2)}:1',
        );
      }
    }

    testWidgets('onPrimary clears AA against the overridden primary',
        (tester) async {
      await tester.pumpWidget(harness((_) => const SizedBox()));
      expectClearsAa(
        (cs) => cs.onPrimary,
        (cs) => cs.primary,
        'onPrimary',
      );
    });

    testWidgets('onSecondary clears AA against the overridden secondary',
        (tester) async {
      await tester.pumpWidget(harness((_) => const SizedBox()));
      expectClearsAa(
        (cs) => cs.onSecondary,
        (cs) => cs.secondary,
        'onSecondary',
      );
    });

    testWidgets('onError clears AA against the overridden error',
        (tester) async {
      await tester.pumpWidget(harness((_) => const SizedBox()));
      expectClearsAa((cs) => cs.onError, (cs) => cs.error, 'onError');
    });

    testWidgets('onSurface clears AA against the overridden surface',
        (tester) async {
      await tester.pumpWidget(harness((_) => const SizedBox()));
      expectClearsAa(
        (cs) => cs.onSurface,
        (cs) => cs.surface,
        'onSurface',
      );
    });
  });

  group('AppButton', () {
    testWidgets('renders every style without error', (tester) async {
      _setBrightness(Brightness.light);
      for (final style in AppButtonStyle.values) {
        await tester.pumpWidget(
          harness((_) => AppButton(
            label: style.name,
            style: style,
            onPressed: () {},
          )),
        );
        await tester.pump();
        expect(tester.takeException(), isNull, reason: style.name);
      }
    });

    testWidgets('the filled foreground clears AA over its own background',
        (tester) async {
      await tester.pumpWidget(harness((_) => const SizedBox()));
      for (final brightness in Brightness.values) {
        final palette = AppPalette.of(brightness);
        // This is the exact pairing the old implementation hardcoded to
        // Colors.white, and the reason dark mode was unreadable.
        expect(
          AppContrast.passes(AppContrast.on(palette.primary), palette.primary),
          isTrue,
          reason: '$brightness filled button label',
        );
      }
    });

    testWidgets('keeps its label while loading instead of showing a bare spinner',
        (tester) async {
      _setBrightness(Brightness.light);
      await tester.pumpWidget(
        harness((_) => const AppButton(
          label: 'حفظ',
          loading: true,
          onPressed: null,
        )),
      );
      await tester.pump();

      // The previous implementation replaced the whole child, so the label
      // vanished and the tap target collapsed to the 18px spinner.
      expect(find.text('حفظ'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
    });

    testWidgets('is disabled while loading', (tester) async {
      _setBrightness(Brightness.light);
      var taps = 0;
      await tester.pumpWidget(
        harness((_) => AppButton(
          label: 'حفظ',
          loading: true,
          onPressed: () => taps++,
        )),
      );
      await tester.pump();

      await tester.tap(find.byType(FilledButton));
      expect(taps, 0);
    });

    testWidgets('exposes button semantics', (tester) async {
      _setBrightness(Brightness.light);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        harness((_) => AppButton(label: 'حفظ', onPressed: () {})),
      );
      await tester.pump();

      expect(
        tester.getSemantics(find.byType(AppButton).first),
        isSemantics(isButton: true, isEnabled: true, label: 'حفظ'),
      );
      handle.dispose();
    });

    testWidgets('is reachable and activatable by keyboard', (tester) async {
      _setBrightness(Brightness.light);
      var taps = 0;
      await tester.pumpWidget(
        harness((_) => AppButton(label: 'حفظ', onPressed: () => taps++)),
      );
      await tester.pump();

      // The previous MouseRegion + AnimatedScale version had no focus handling
      // and no keyboard activation path at all.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(taps, 1);
    });
  });
}

/// Test-only shim: the app sets `AppColors.brightness` from `main.dart` before
/// building the tree. Widget tests that pump a theme directly have to do the
/// same, since `AppButton` reads the `AppColors.*` getters.
void _setBrightness(Brightness brightness) =>
    AppColors.brightness = brightness;
