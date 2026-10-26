import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import 'app/app_bootstrap.dart';
import 'app/auth_gate.dart';
import 'core/constants/app_strings.dart';
import 'core/locale/locale_service.dart';
import 'core/platform/app_scroll_behavior.dart';
import 'core/platform/window_chrome.dart';
import 'core/responsive/form_factor.dart';
import 'core/responsive/layout_spec.dart';
import 'core/responsive/responsive_scope.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_service.dart';
import 'design_system/animations/app_animations.dart';
import 'design_system/tokens/app_colors.dart';
import 'design_system/tokens/app_text_theme.dart';
import 'di/service_locator.dart';
import 'features/reports/data/pdf_renderer.dart';
import 'l10n/generated/app_localizations.dart';
import 'router/app_router.dart';

Future<void> main() async {
  // Desktop best-practice #1: never die with a black screen. Zone + framework
  // errors are routed to debugPrint (release: platform log) and the widget
  // tree gets an Arabic-friendly fallback instead of a grey screen.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[flutter-error] ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[platform-error] $error');
    return true;
  };
  ErrorWidget.builder = (details) => _StartupErrorView(
    message:
        'حدث خطأ غير متوقع. أعد تشغيل التطبيق.\nUnexpected error — restart the app.',
    details: kDebugMode ? '${details.exception}' : null,
    retry: null,
  );

  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // First pixels ASAP: bootstrap (Firebase init, per-org DB open, seeds,
      // backup) stays off the critical path behind a splash instead of a black
      // screen. The splash is deliberately dependency-free — no theme service,
      // no ScreenUtil, no localization — so it can paint before any of that.
      runApp(const _BootstrapSplash());
      try {
        await appBootstrap();
      } on Object catch (e) {
        // Bootstrap (DB open, Firebase, seeds) failed: swap the spinner for a
        // retry screen instead of hanging forever. Keeps MSIX/EXE + mobile
        // parity — same widget on every platform.
        debugPrint('[bootstrap] failed: $e');
        runApp(
          _StartupErrorView(
            message:
                'تعذر بدء التشغيل. تحقق من الاتصال ثم أعد المحاولة.\nStartup failed — check your connection and try again.',
            details: kDebugMode ? '$e' : null,
            retry: () => main(),
          ),
        );
        return;
      }

      final themeService = getIt<ThemeService>();
      await themeService.init();

      final localeService = getIt<LocaleService>();
      await localeService.init();
      AppText.arabic = localeService.isArabic;
      AppPageRoute.appearanceChanges = Listenable.merge([
        themeService,
        localeService,
      ]);

      final router = AppRouter(authGate: getIt<AuthGate>()).router;
      runApp(MaterialLabApp(router: router));

      // Mobile-only bell + poll scheduling after the first frame (no-op on
      // desktop): plugin init and the bell scans interleave with the first paint
      // instead of delaying it. PDF font warm-up rides along so the first export
      // skips the rootBundle + shaping jank.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(startNotifications());
        unawaited(PdfRenderer.precache());
      });
    },
    (error, stack) {
      debugPrint('[zone-error] $error');
    },
  );
}

/// Retry-capable fatal-startup view. Dependency-free like [_BootstrapSplash]
/// so it can be shown even when DI/theme/router all failed. Same on
/// MSIX, plain EXE, Android and iOS (parity).

/// Retry-capable fatal-startup view. Dependency-free like [_BootstrapSplash]
/// so it can be shown even when DI/theme/router all failed. Same on
/// MSIX, plain EXE, Android and iOS (parity).
class _StartupErrorView extends StatelessWidget {
  const _StartupErrorView({required this.message, this.details, this.retry});

  final String message;
  final String? details;
  final Future<void> Function()? retry;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF3F6FB),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    size: 48,
                    color: Color(0xFFB91C1C),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.rtl,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  if (details != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      details!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                  if (retry != null) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: () => retry!(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('إعادة المحاولة / Retry'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dependency-free launch splash: paints before Firebase, the database and
/// the theme service are ready, so a slow cold start keeps the same field and
/// logo as the native Android launch theme instead of a black screen. No
/// spinner — the launch screen simply lasts until the first real frame.
/// Replaced by [MaterialLabApp] once bootstrap finishes.
class _BootstrapSplash extends StatelessWidget {
  const _BootstrapSplash();

  @override
  Widget build(BuildContext context) {
    // Matches the native splash exactly (F3F6FB field, launch_image at ~48%
    // screen width, centered). Deliberately dependency-free — no theme
    // service, no ScreenUtil, no localization; Image.asset only needs the
    // binding, which is already initialized before runApp.
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(
        color: Color(0xFFF3F6FB),
        child: Center(
          child: Image(
            image: AssetImage('assets/images/Material-Lab.png'),
            width: 200,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}

/// MaterialLabApp — RTL Arabic-first bilingual Material app (Windows desktop).
class MaterialLabApp extends StatefulWidget {
  final GoRouter router;
  const MaterialLabApp({super.key, required this.router});

  @override
  State<MaterialLabApp> createState() => _MaterialLabAppState();
}

class _MaterialLabAppState extends State<MaterialLabApp> {
  // Perf: cache singletons once instead of getIt<> on every rebuild.
  // Instances are registered before runApp; live values are still read
  // per-build from the same objects.
  late final ThemeService _themeService = getIt<ThemeService>();
  late final LocaleService _localeService = getIt<LocaleService>();
  late final Listenable _themeLocaleListenable = Listenable.merge([
    _themeService,
    _localeService,
  ]);
  static const _chrome = WindowChrome();
  String? _lastChromeTitle;
  bool? _lastChromeDark;
  bool _chromeDarkSet = false;

  /// Perf: WindowChrome is a platform channel — only hit it when the resolved
  /// title/brightness actually changes, not on every theme/locale rebuild.
  /// Failures stay fire-and-forget (cosmetic only, see WindowChrome).
  void _syncChrome(String title, bool? dark) {
    if (_lastChromeTitle != title) {
      _lastChromeTitle = title;
      unawaited(_chrome.setTitle(title));
    }
    if (!_chromeDarkSet || _lastChromeDark != dark) {
      _chromeDarkSet = true;
      _lastChromeDark = dark;
      unawaited(_chrome.setDarkMode(dark));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Applied *above* ScreenUtilInit on purpose: ScreenUtil latches its text
    // scale during initState, so a clamp placed only inside MaterialApp would
    // leave the sp-derived theme sizes scaling by the raw system factor while
    // the body text used the capped one.
    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: AppTextTheme.clampScaler(context)),
      child: ScreenUtilInit(
        // Chosen from the **platform**, once, before `runApp`.
        //
        // Desktop keeps the 1280x720 grid the ~400 `.w`/`.h`/`.spMax` call
        // sites were authored against, so the desktop build does not move.
        //
        // Mobile authors against 400x860. At that ratio on a 360x800dp phone
        // `scaleWidth` is 0.90 and `scaleHeight` is 0.93, which means `.w`
        // becomes "fraction of a 400dp reference" (correct for a phone), `.r`
        // lands near 1.0 so authored radii survive, and `.spMax` floors text
        // at its authored size.
        //
        // This must never be derived from the window width: `designSize` is a
        // process-wide singleton, and a width-derived value would hand a
        // snapped desktop window the phone grid - a 280dp sidebar becoming
        // 672dp. See `FormFactor.resolve`.
        designSize: FormFactor.current.isMobile
            ? const Size(400, 860)
            : const Size(1280, 720),
        minTextAdapt: true,
        splitScreenMode: true,
        builder: (context, _) {
          // Read here (outside the ListenableBuilder) so the subtree holds a
          // dependency on the OS brightness: under ThemeMode.system a system-wide
          // theme change must rebuild, not just an explicit toggle.
          final platformBrightness = MediaQuery.platformBrightnessOf(context);
          return ListenableBuilder(
            listenable: _themeLocaleListenable,
            builder: (context, _) {
              final themeService = _themeService;
              final localeService = _localeService;
              // `AppColors.brightness` must name the brightness the scheme
              // actually resolves. Inferring "not dark => light" silently
              // disagreed with MaterialApp whenever mode was ThemeMode.system
              // on a machine set to dark.
              AppColors.brightness = switch (themeService.mode) {
                ThemeMode.dark => Brightness.dark,
                ThemeMode.light => Brightness.light,
                ThemeMode.system => platformBrightness,
              };
              AppText.arabic = localeService.isArabic;

              // Push the resolved language and brightness to the native window
              // chrome. Fire-and-forget on purpose: a retitle that fails is
              // cosmetic and must not gate the first frame.
              // Perf: _syncChrome dedupes the platform-channel calls so
              // unrelated rebuilds don't re-hit the OS. Under ThemeMode.system
              // null hands control back to the OS registry value.
              final chromeDark = switch (themeService.mode) {
                ThemeMode.dark => true,
                ThemeMode.light => false,
                ThemeMode.system => null,
              };
              _syncChrome(AppStrings.appTitle, chromeDark);

              return ResponsiveScope(
                spec: LayoutSpec.of(FormFactor.current),
                // Above `MaterialApp` on purpose: `Dialog`, `Menu` and the
                // other overlays are inserted into the navigator's own subtree
                // rather than inheriting the caller's scope, so a scope placed
                // inside the navigator would leave every dialog resolving the
                // wrong form factor.
                child: MaterialApp.router(
                  title: AppStrings.appTitle,
                  debugShowCheckedModeBanner: false,
                  scrollBehavior: const AppScrollBehavior(),
                  theme: AppTheme.light(),
                  darkTheme: AppTheme.dark(),
                  themeMode: themeService.mode,
                  locale: localeService.locale,
                  supportedLocales: LocaleService.supportedLocales,
                  localizationsDelegates: const [
                    AppLocalizations.delegate,
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  routerConfig: widget.router,
                  // The second half of the clamp. `MaterialApp` builds its own
                  // MediaQuery from the view instead of inheriting the ambient
                  // one, so the wrapper above is dropped here and has to be
                  // reapplied below the navigator — otherwise dialogs, menus
                  // and overlays, which are inserted into this subtree, would
                  // read the raw unbounded system scale.
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(
                      context,
                    ).copyWith(textScaler: AppTextTheme.clampScaler(context)),
                    child: child!,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
