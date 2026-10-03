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
import 'design_system/tokens/app_colors.dart';
import 'design_system/tokens/app_text_theme.dart';
import 'di/service_locator.dart';
import 'l10n/generated/app_localizations.dart';
import 'router/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await appBootstrap();

  final themeService = getIt<ThemeService>();
  await themeService.init();

  final localeService = getIt<LocaleService>();
  await localeService.init();
  AppText.arabic = localeService.isArabic;

  final router = AppRouter(authGate: getIt<AuthGate>()).router;
  runApp(MaterialLabApp(router: router));
}

/// MaterialLabApp — RTL Arabic-first bilingual Material app (Windows desktop).
class MaterialLabApp extends StatefulWidget {
  final GoRouter router;
  const MaterialLabApp({super.key, required this.router});

  @override
  State<MaterialLabApp> createState() => _MaterialLabAppState();
}

class _MaterialLabAppState extends State<MaterialLabApp> {
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
            listenable: Listenable.merge([
              getIt<ThemeService>(),
              getIt<LocaleService>(),
            ]),
            builder: (context, _) {
              final themeService = getIt<ThemeService>();
              final localeService = getIt<LocaleService>();
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
              const chrome = WindowChrome();
              chrome.setTitle(AppStrings.appTitle);
              switch (themeService.mode) {
                case ThemeMode.dark:
                  chrome.setDarkMode(true);
                case ThemeMode.light:
                  chrome.setDarkMode(false);
                case ThemeMode.system:
                  // Let the OS registry value decide, so the title bar keeps
                  // tracking a system-wide theme change.
                  chrome.setDarkMode(null);
              }

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
