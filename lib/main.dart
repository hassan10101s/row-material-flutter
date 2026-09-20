import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'app/app_bootstrap.dart';
import 'app/auth_gate.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_service.dart';
import 'design_system/tokens/app_colors.dart';
import 'di/service_locator.dart';
import 'router/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await appBootstrap();

  final themeService = getIt<ThemeService>();
  await themeService.init();

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
    return ListenableBuilder(
      listenable: getIt<ThemeService>(),
      builder: (context, _) {
        final themeService = getIt<ThemeService>();
        AppColors.brightness = themeService.mode == ThemeMode.dark
            ? Brightness.dark
            : Brightness.light;
        return MaterialApp.router(
          title: 'Material Lab',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: themeService.mode,
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          routerConfig: widget.router,
        );
      },
    );
  }
}