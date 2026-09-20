import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/auth_gate.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/setup_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/inspections/presentation/inspections_screen.dart';
import '../features/lab/presentation/lab_screen.dart';
import '../features/reference/presentation/reference_screen.dart';
import '../features/reports/presentation/reports_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/shell/presentation/app_shell.dart';

/// Route names used for navigation.
abstract final class AppRoutes {
  static const String setup = '/setup';
  static const String login = '/login';
  static const String dashboard = '/dashboard';
  static const String history = '/history';
  static const String inspections = '/inspections';
  static const String reports = '/reports';
  static const String lab = '/lab';
  static const String reference = '/reference';
  static const String settings = '/settings';
}

class AppRouter {
  AppRouter({required AuthGate authGate}) : _gate = authGate;

  final AuthGate _gate;

  late final GoRouter router = GoRouter(
    initialLocation: AppRoutes.login,
    refreshListenable: _gate,
    redirect: _redirect,
    routes: [
      GoRoute(path: AppRoutes.setup, builder: (c, s) => const SetupScreen()),
      GoRoute(path: AppRoutes.login, builder: (c, s) => const LoginScreen()),
      GoRoute(
        path: '/',
        builder: (c, s) => AppShell(
          child: _pageFor(s.uri.path),
        ),
        routes: [
          GoRoute(
            path: 'dashboard',
            builder: (c, s) => const DashboardScreen(),
          ),
          GoRoute(
            path: 'history',
            builder: (c, s) => const HistoryScreen(),
          ),
          GoRoute(
            path: 'inspections',
            builder: (c, s) => const InspectionsScreen(),
          ),
          GoRoute(
            path: 'reports',
            builder: (c, s) => const ReportsScreen(),
          ),
          GoRoute(
            path: 'lab',
            builder: (c, s) => const LabScreen(),
          ),
          GoRoute(
            path: 'reference',
            builder: (c, s) => const ReferenceScreen(),
          ),
          GoRoute(
            path: 'settings',
            builder: (c, s) => const SettingsScreen(),
          ),
        ],
      ),
    ],
  );

  FutureOr<String?> _redirect(BuildContext context, GoRouterState state) async {
    final user = _gate.currentUser;
    final path = state.uri.path;
    if (path == '/') return AppRoutes.login;

    final needsAdmin = user == null && await _gate.auth.needsAdminSetup();
    if (user == null) {
      if (needsAdmin) return path == AppRoutes.setup ? null : AppRoutes.setup;
      return path == AppRoutes.login ? null : AppRoutes.login;
    }
    if (path == AppRoutes.setup || path == AppRoutes.login) {
      return AppRoutes.dashboard;
    }
    final adminOnly = path == AppRoutes.settings || path == AppRoutes.reference;
    if (adminOnly && !user.canSeeSettings) return AppRoutes.dashboard;
    return null;
  }

  static Widget _pageFor(String path) {
    switch (path) {
      case AppRoutes.dashboard:
        return const DashboardScreen();
      case AppRoutes.history:
        return const HistoryScreen();
      case AppRoutes.reports:
        return const ReportsScreen();
      case AppRoutes.lab:
        return const LabScreen();
      case AppRoutes.reference:
        return const ReferenceScreen();
      case AppRoutes.settings:
        return const SettingsScreen();
      case AppRoutes.inspections:
        return const InspectionsScreen();
      default:
        return const DashboardScreen();
    }
  }
}