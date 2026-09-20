import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';

import 'app/app_bootstrap.dart';
import 'app/auth_gate.dart';
import 'core/theme/app_theme.dart';
import 'di/service_locator.dart';
import 'router/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await appBootstrap();

  final router = AppRouter(authGate: getIt<AuthGate>()).router;
  runApp(MaterialLabApp(router: router));
}

/// MaterialLabApp — RTL Arabic-first bilingual Material app (Windows desktop).
class MaterialLabApp extends StatelessWidget {
  final GoRouter router;
  const MaterialLabApp({super.key, required this.router});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Material Lab',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.light,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}