import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../app/auth_gate.dart';
import '../core/auth/app_session.dart';
import '../core/auth/permissions.dart';
import '../design_system/animations/app_animations.dart';
import '../features/audit/presentation/audit_controller.dart';
import '../features/audit/presentation/audit_screen.dart';
import '../di/service_locator.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/presentation/cubit/create_organization_cubit.dart';
import '../features/auth/presentation/cubit/login_cubit.dart';
import '../features/auth/presentation/create_organization_screen.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/auth/presentation/waiting_activation_screen.dart';

import '../features/dashboard/data/dashboard_repo.dart';
import '../features/dashboard/presentation/cubit/dashboard_cubit.dart';
import '../features/dashboard/presentation/cubit/dashboard_kpis_cubit.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/inspections/data/inspection_repo.dart';
import '../features/inspections/presentation/cubit/inspection_form_cubit.dart';
import '../features/inspections/presentation/cubit/inspections_cubit.dart';
import '../features/inspections/presentation/inspection_form_screen.dart';
import '../features/inspections/presentation/inspections_screen.dart';
import '../features/lab/presentation/cubit/lab_cubit.dart';
import '../features/lab/presentation/lab_screen.dart';
import '../features/organizations/domain/organization_repository.dart';
import '../features/members/presentation/members_screen.dart';
import '../features/reference/data/reference_repo.dart';
import '../features/reference/presentation/reference_screen.dart';
import '../features/reports/data/report_service.dart';
import '../features/reports/presentation/cubit/reports_cubit.dart';
import '../features/reports/presentation/reports_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/shell/presentation/app_shell.dart';
import '../features/sync/presentation/sync_screen.dart';

/// Route names used for navigation.
abstract final class AppRoutes {
  static const String login = '/login';
  static const String createOrganization = '/create-organization';
  static const String waitingActivation = '/waiting-activation';
  static const String dashboard = '/dashboard';
  static const String inspections = '/inspections';
  static const String inspectionNew = '/inspection-new';
  static const String reports = '/reports';
  static const String lab = '/lab';
  static const String reference = '/reference';
  static const String settings = '/settings';
  static const String members = '/members';
  static const String sync = '/sync';
  static const String audit = '/audit';
}

/// Rewritten guard (plan §8.1). It is a pure function of [AuthState]:
/// ```
/// needsBootstrap        -> /login (configuration hint)
/// signedOut             -> /login
/// noProfile             -> /create-organization
/// awaitingActivation    -> /waiting-activation
/// ready                 -> the requested page
/// ```
class AppRouter {
  AppRouter({required AuthGate authGate}) : _gate = authGate;

  final AuthGate _gate;

  late final GoRouter router = GoRouter(
    initialLocation: AppRoutes.login,
    refreshListenable: _gate,
    redirect: _redirect,
    routes: [
      GoRoute(
        path: AppRoutes.login,
        pageBuilder: (c, s) => AppPage<LoginCubit>(
          name: s.uri.path,
          builder: (c) => BlocProvider(
            create: (c) =>
                LoginCubit(auth: getIt<AuthRepository>(), gate: _gate)
                  ..applyBootstrap(),
            child: const LoginScreen(),
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.createOrganization,
        pageBuilder: (c, s) => AppPage<CreateOrganizationCubit>(
          name: s.uri.path,
          builder: (c) => BlocProvider(
            create: (c) => CreateOrganizationCubit(
              auth: getIt<AuthRepository>(),
              organizations: getIt<OrganizationRepository>(),
              gate: _gate,
            ),
            child: const CreateOrganizationScreen(),
          ),
        ),
      ),
      GoRoute(
        path: AppRoutes.waitingActivation,
        pageBuilder: (c, s) => AppPage<void>(
          name: s.uri.path,
          builder: (c) => const WaitingActivationScreen(),
        ),
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.dashboard,
            pageBuilder: (c, s) => AppPage<DashboardScreen>(
              name: s.uri.path,
              builder: (c) => MultiBlocProvider(
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
          ),
          GoRoute(
            path: AppRoutes.inspectionNew,
            pageBuilder: (c, s) => AppPage<InspectionFormScreen>(
              name: s.uri.path,
              builder: (c) => BlocProvider(
                create: (c) => InspectionFormCubit(
                  repo: getIt<InspectionRepo>(),
                  reference: getIt<ReferenceRepo>(),
                )..loadMaterials(),
                child: InspectionFormScreen(
                  onSaved: () => GoRouter.of(c).go(AppRoutes.inspections),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.inspections,
            pageBuilder: (c, s) => AppPage<InspectionsScreen>(
              name: s.uri.path,
              builder: (c) => BlocProvider(
                create: (c) => InspectionsCubit(
                  repo: getIt<InspectionRepo>(),
                  reports: getIt<ReportService>(),
                )..load(),
                child: const InspectionsScreen(),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.reports,
            pageBuilder: (c, s) => AppPage<ReportsScreen>(
              name: s.uri.path,
              builder: (c) => BlocProvider(
                create: (c) => ReportsCubit(repo: getIt<ReportService>()),
                child: const ReportsScreen(),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.lab,
            pageBuilder: (c, s) => AppPage<LabScreen>(
              name: s.uri.path,
              builder: (c) => BlocProvider(
                create: (c) => LabCubit(),
                child: const LabScreen(),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.reference,
            pageBuilder: (c, s) => AppPage<ReferenceScreen>(
              name: s.uri.path,
              builder: (c) => const ReferenceScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.members,
            pageBuilder: (c, s) => AppPage<MembersScreen>(
              name: s.uri.path,
              builder: (c) => const MembersScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.sync,
            pageBuilder: (c, s) => AppPage<SyncScreen>(
              name: s.uri.path,
              builder: (c) => const SyncScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.audit,
            pageBuilder: (c, s) => AppPage<AuditScreen>(
              name: s.uri.path,
              builder: (c) => AuditScreen(controller: getIt<AuditController>()),
            ),
          ),
          GoRoute(
            path: AppRoutes.settings,
            pageBuilder: (c, s) => AppPage<SettingsScreen>(
              name: s.uri.path,
              // `/settings?tab=sync` — the sidebar no longer lists Sync or
              // Members, so the shell badge deep-links into the section instead.
              builder: (c) => SettingsScreen(
                initialTab: SettingsTab.fromKey(s.uri.queryParameters['tab']),
              ),
            ),
          ),
        ],
      ),
    ],
  );

  FutureOr<String?> _redirect(BuildContext context, GoRouterState state) async {
    final path = state.uri.path;
    if (path == '/') return AppRoutes.login;

    final authState = _gate.auth.state;
    const publicRoutes = {
      AppRoutes.login,
      AppRoutes.createOrganization,
      AppRoutes.waitingActivation,
    };
    final isPublic = publicRoutes.contains(path);

    switch (authState) {
      case AuthState.needsBootstrap:
      case AuthState.signedOut:
        return isPublic && path == AppRoutes.login ? null : AppRoutes.login;
      case AuthState.noProfile:
        if (path == AppRoutes.createOrganization) return null;
        return AppRoutes.createOrganization;
      case AuthState.awaitingActivation:
        if (path == AppRoutes.waitingActivation) return null;
        return AppRoutes.waitingActivation;
      case AuthState.ready:
        if (isPublic) return AppRoutes.dashboard;
        return _guardRoute(path);
    }
  }

  /// Role guard for the management screens. `viewer` devices are read-only
  /// dashboards (plan §14-P8.3) and never see these routes.
  String? _guardRoute(String path) => guardRoute(path, _gate.session);

  /// Pure route guard so it can be tested without any DI (plan §8.1/§14-P8.3):
  /// a `viewer`, a disabled member or a read-only device is sent back to the
  /// dashboard instead of a screen it may only read.
  ///
  /// The Rules (server) and the write guards (repository) stay the independent
  /// layers; this one only keeps the user away from a dead end.
  static String? guardRoute(String path, AppSession session) {
    switch (path) {
      case AppRoutes.members:
        if (!session.permissions.contains(Permission.usersRead)) {
          return AppRoutes.dashboard;
        }
      case AppRoutes.audit:
        // The audit trail is synced down from `auditLogs`; without the
        // permission there is nothing to show.
        if (!session.permissions.contains(Permission.auditRead)) {
          return AppRoutes.dashboard;
        }
      case AppRoutes.settings:
      case AppRoutes.reference:
        if (!session.permissions.contains(Permission.orgRead)) {
          return AppRoutes.dashboard;
        }
      case AppRoutes.inspectionNew:
        // A write form is never opened by a read-only device.
        if (!session.canWrite) return AppRoutes.dashboard;
    }
    return null;
  }
}
