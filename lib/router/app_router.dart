import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../app/auth_gate.dart';
import '../di/service_locator.dart';
import '../features/auth/data/auth_repo.dart';
import '../features/auth/presentation/cubit/login_cubit.dart';
import '../features/auth/presentation/cubit/setup_cubit.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/setup_screen.dart';
import '../features/dashboard/data/dashboard_repo.dart';
import '../features/dashboard/presentation/cubit/dashboard_cubit.dart';
import '../features/dashboard/presentation/cubit/dashboard_kpis_cubit.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/history/presentation/cubit/history_cubit.dart';
import '../features/history/presentation/history_screen.dart';
import '../features/inspections/data/inspection_repo.dart';
import '../features/inspections/presentation/cubit/inspections_cubit.dart';
import '../features/inspections/presentation/inspections_screen.dart';
import '../features/lab/presentation/cubit/lab_cubit.dart';
import '../features/lab/presentation/lab_screen.dart';
import '../features/reference/data/reference_repo.dart';
import '../features/reference/presentation/cubit/reference_cubit.dart';
import '../features/reference/presentation/reference_screen.dart';
import '../features/reports/data/report_service.dart';
import '../features/reports/presentation/cubit/reports_cubit.dart';
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
      GoRoute(
        path: AppRoutes.setup,
        builder: (c, s) => BlocProvider(
          create: (c) => SetupCubit(auth: getIt<AuthRepo>(), gate: _gate),
          child: const SetupScreen(),
        ),
      ),
      GoRoute(
        path: AppRoutes.login,
        builder: (c, s) => BlocProvider(
          create: (c) => LoginCubit(auth: getIt<AuthRepo>(), gate: _gate),
          child: const LoginScreen(),
        ),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.dashboard,
            builder: (c, s) => MultiBlocProvider(
              providers: [
                BlocProvider(create: (c) => DashboardKpisCubit()),
                BlocProvider(
                  create: (c) => DashboardCubit(
                    repo: getIt<DashboardRepo>(),
                    kpis: c.read<DashboardKpisCubit>(),
                  )..load(),
                ),
              ],
              child: const DashboardScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.history,
            builder: (c, s) => BlocProvider(
              create: (c) =>
                  HistoryCubit(repo: getIt<InspectionRepo>())..load(),
              child: const HistoryScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.inspections,
            builder: (c, s) => BlocProvider(
              create: (c) => InspectionsCubit(
                repo: getIt<InspectionRepo>(),
                reports: getIt<ReportService>(),
              )..load(),
              child: const InspectionsScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.reports,
            builder: (c, s) => BlocProvider(
              create: (c) => ReportsCubit(repo: getIt<ReportService>()),
              child: const ReportsScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.lab,
            builder: (c, s) => BlocProvider(
              create: (c) => LabCubit(),
              child: const LabScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.reference,
            builder: (c, s) => BlocProvider(
              create: (c) => ReferenceCubit(repo: getIt<ReferenceRepo>())
                ..load(),
              child: const ReferenceScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.settings,
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
}