import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:go_router/go_router.dart';

import 'app/app_bootstrap.dart';
import 'app/auth_gate.dart';
import 'core/constants/app_strings.dart';
import 'core/locale/locale_service.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_service.dart';
import 'design_system/tokens/app_colors.dart';
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
    return ScreenUtilInit(
      designSize: const Size(1280, 720),
      minTextAdapt: true,
      splitScreenMode: true,
      builder: (context, _) => ListenableBuilder(
        listenable: Listenable.merge([
          getIt<ThemeService>(),
          getIt<LocaleService>(),
        ]),
        builder: (context, _) {
          final themeService = getIt<ThemeService>();
          final localeService = getIt<LocaleService>();
          AppColors.brightness = themeService.mode == ThemeMode.dark
              ? Brightness.dark
              : Brightness.light;
          AppText.arabic = localeService.isArabic;
          return MaterialApp.router(
            title: 'Material Lab',
            debugShowCheckedModeBanner: false,
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
          );
        },
      ),
    );
  }
}