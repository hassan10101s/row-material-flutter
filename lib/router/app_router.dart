import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../app/auth_gate.dart';
import '../core/auth/app_session.dart';
import '../core/auth/permissions.dart';
import '../core/locale/locale_service.dart';
import '../core/network/connectivity_service.dart';
import '../core/responsive/form_factor.dart';
import '../core/sync/sync_metadata.dart';
import '../core/sync/sync_queue.dart';
import '../core/theme/theme_service.dart';
import '../design_system/animations/app_animations.dart';
import '../design_system/widgets/app_page_size.dart' show kMobileMaxPageSize;
import '../di/platform_ports.dart';
import '../di/service_locator.dart';
import '../features/auth/domain/auth_repository.dart';
import '../features/auth/presentation/cubit/create_organization_cubit.dart';
import '../features/auth/presentation/cubit/login_cubit.dart';
import '../features/auth/presentation/create_organization/create_organization_screen.dart';
import '../features/auth/presentation/login/login_screen.dart';
import '../features/auth/presentation/waiting_activation/waiting_activation_screen.dart';

import '../features/dashboard/domain/dashboard_repository.dart';
import '../features/dashboard/presentation/cubit/dashboard_cubit.dart';
import '../features/dashboard/presentation/cubit/daily_tasks_cubit.dart';
import '../features/dashboard/presentation/cubit/dashboard_kpis_cubit.dart';
import '../features/dashboard/presentation/dashboard/dashboard_screen.dart';
import '../features/inspections/domain/inspection_repository.dart';
import '../features/inspections/presentation/cubit/inspection_form_cubit.dart';
import '../features/inspections/presentation/cubit/inspections_cubit.dart';
import '../features/inspections/presentation/center/inspection_center_screen.dart';
import '../features/inspections/presentation/form/inspection_form_screen.dart';
import '../features/lab/presentation/cubit/lab_cubit.dart';
import '../features/lab/presentation/lab_screen.dart';
import '../features/organizations/domain/organization_repository.dart';
import '../features/qc_manager/presentation/cubit/qc_ncr_cubit.dart';
import '../features/qc_manager/domain/ncr_filters.dart';
import '../features/qc_manager/presentation/cubit/qc_sops_cubit.dart';
import '../features/qc_manager/presentation/routine/routine_lists_cubit.dart';
import '../features/qc_manager/presentation/routine/routine_lists_screen.dart';
import '../features/qc_manager/presentation/routine/routine_sheet_cubit.dart';
import '../features/qc_manager/presentation/routine/routine_sheet_screen.dart';
import '../features/qc_manager/presentation/ncr/qc_ncr_dashboard_screen.dart';
import '../features/qc_manager/presentation/ncr/qc_ncr_detail_screen.dart';
import '../features/qc_manager/presentation/ncr/qc_ncr_list_screen.dart';
import '../features/qc_manager/presentation/management/qc_management_screen.dart';
import '../features/qc_manager/presentation/sops/qc_sops_screen.dart';
import '../features/members/presentation/members/members_screen.dart';
import '../features/reference/domain/reference_repository.dart';
import '../features/reference/presentation/reference_screen.dart';
import '../features/reports/domain/report_repository.dart';
import '../features/reports/presentation/cubit/reports_cubit.dart';
import '../features/settings/domain/export_root_service.dart';
import '../features/settings/presentation/settings/settings_screen.dart';
import '../features/shell/presentation/app_shell.dart';
import '../features/sync/presentation/sync/sync_screen.dart';

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

  /// QC Manager (plan V6_ENHANCED §22.7, §12.2).
  static const String qcNcr = '/qc-ncr';
  static const String qcManagement = '/quality-management';

  /// The table behind the dashboard. Not named by the plan, which gives one path
  /// for the whole report; the dashboard and the table are separate screens
  /// sharing one filter scope, so they need separate routes to push between.
  static const String qcNcrList = '/qc-ncr/list';
  static const String qcNcrDetail = '/qc-ncr/detail';

  /// The inspection register, and one executed sheet in full.
  ///
  /// The sheet resolves its own cubit rather than borrowing the register's:
  /// answering an item rewrites the score, so the register's filtered page and
  /// the sheet's tree are two different queries over two different tables.
  static const String qcInspections = '/qc-inspections';
  static const String qcInspectionDetail = '/qc-inspections/detail';

  /// The SOP register. One route, not two: a procedure's detail needs the
  /// register's cubit to stay in sync behind it, so it is pushed onto the same
  /// navigator stack rather than resolved as an independent route.
  static const String qcSops = '/qc-sops';
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
        builder: (context, state, child) => AppShell(
          // The shell is the one widget that needs the whole graph, so the
          // router - the app's composition root - is where it is resolved.
          // Everything below the shell receives its dependencies as parameters.
          gate: _gate,
          locale: getIt<LocaleService>(),
          theme: getIt<ThemeService>(),
          syncQueue: getIt<SyncQueue>(),
          syncMetadata: getIt<SyncMetadata>(),
          connectivity: getIt<ConnectivityService>(),
          exportRoot: getIt<ExportRootService>(),
          fileDelivery: fileDelivery(),
          folderPicker: folderPicker(),
          child: child,
        ),
        routes: [
          GoRoute(
            path: AppRoutes.dashboard,
            pageBuilder: (c, s) => AppPage<DashboardScreen>(
              name: s.uri.path,
              builder: (c) => MultiBlocProvider(
                providers: [
                  BlocProvider(create: (c) => DashboardKpisCubit()),
                  BlocProvider(create: (c) => DailyTasksCubit()..load()),
                  BlocProvider(
                    create: (c) => DashboardCubit(
                      repo: getIt<DashboardRepository>(),
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
                  repo: getIt<InspectionRepository>(),
                  reference: getIt<ReferenceRepository>(),
                )..loadMaterials(),
                // Stepped wizard on phones, full design-system form on
                // desktop (router is a form-factor authority).
                child: InspectionFormScreen(
                  wizard: FormFactor.current.isMobile,
                  onSaved: () => GoRouter.of(c).go(AppRoutes.inspections),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.inspections,
            pageBuilder: (c, s) => AppPage<InspectionCenterScreen>(
              name: s.uri.path,
              builder: (c) => MultiBlocProvider(
                providers: [
                  BlocProvider(
                    create: (c) => InspectionsCubit(
                      repo: getIt<InspectionRepository>(),
                      reports: getIt<ReportRepository>(),
                      // Phones page through cards, not a table: cap at 50.
                      initialPageSize: FormFactor.current.isMobile
                          ? kMobileMaxPageSize
                          : 200,
                      // Dashboard drill-down seeds: `?status&supplier&material`
                      // (id) `&materialName&from&to`. Bad values are inert.
                      initialStatus: (s.uri.queryParameters['status'] ?? '')
                          .trim(),
                      initialSupplier:
                          (s.uri.queryParameters['supplier'] ?? '').trim(),
                      initialMaterialId: () {
                        final v = int.tryParse(
                          s.uri.queryParameters['material'] ?? '',
                        );
                        return (v == null || v <= 0) ? null : v;
                      }(),
                      initialMaterialName:
                          (s.uri.queryParameters['materialName'] ?? '')
                              .trim(),
                      initialDateFrom:
                          (s.uri.queryParameters['from'] ?? '').trim(),
                      initialDateTo:
                          (s.uri.queryParameters['to'] ?? '').trim(),
                    )..load(),
                  ),
                  BlocProvider(
                    create: (c) =>
                        ReportsCubit(repo: getIt<ReportRepository>()),
                  ),
                ],
                // `?highlight=<localId>` from a notification tap.
                child: InspectionCenterScreen(
                  highlightId: s.uri.queryParameters['highlight'],
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.reports,
            pageBuilder: (c, s) => AppPage<InspectionCenterScreen>(
              name: s.uri.path,
              builder: (c) => MultiBlocProvider(
                providers: [
                  BlocProvider(
                    create: (c) => InspectionsCubit(
                      repo: getIt<InspectionRepository>(),
                      reports: getIt<ReportRepository>(),
                      // Same mobile cap as the inspections route above.
                      initialPageSize: FormFactor.current.isMobile
                          ? kMobileMaxPageSize
                          : 200,
                    )..load(),
                  ),
                  BlocProvider(
                    create: (c) =>
                        ReportsCubit(repo: getIt<ReportRepository>()),
                  ),
                ],
                child: const InspectionCenterScreen(initialReportsTab: true),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.lab,
            pageBuilder: (c, s) => AppPage<LabScreen>(
              name: s.uri.path,
            // `?tab=0&highlight=<localId>` from a notification tap:
            // test-history tab + banner. Unknown tab values fall back to 0.
            // The LabScreen clamps against its real tab count so a stale
            // notification can never index an `IndexedStack` out of range.
            builder: (c) {
              final tab =
                  int.tryParse(s.uri.queryParameters['tab'] ?? '0') ?? 0;
              return BlocProvider(
                create: (c) => LabCubit()..setTab(tab),
                child: LabScreen(
                    highlightId: s.uri.queryParameters['highlight'],
                  ),
                );
              },
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
          GoRoute(
            path: AppRoutes.qcManagement,
            pageBuilder: (c, s) => AppPage<QcManagementScreen>(
              name: s.uri.path,
              builder: (c) => const QcManagementScreen(),
            ),
          ),
          GoRoute(
            path: AppRoutes.qcNcr,
            pageBuilder: (c, s) => AppPage<QcNcrDashboardScreen>(
              name: s.uri.path,
              // `create` so the router's scope closes the cubit on pop; the
              // cubit holds the active filter and page, and a leaked one would
              // hand the next visitor a report already filtered for someone else.
              builder: (context) => BlocProvider(
                create: (_) => getIt<QcNcrCubit>()
                  ..loadOptions()
                  ..load(),
                child: QcNcrDashboardScreen(
                  onOpenList: () => context.push(AppRoutes.qcNcrList),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.qcNcrList,
            pageBuilder: (c, s) => AppPage<QcNcrListScreen>(
              name: s.uri.path,
              builder: (context) => BlocProvider(
                create: (_) {
                  final cubit = getIt<QcNcrCubit>();
                  // Dashboard drill-down seeds: `?status=Open&overdue=1`.
                  // Unrecognised values are inert (an unknown status simply
                  // matches nothing until the auditor resets).
                  final q = s.uri.queryParameters;
                  final status = (q['status'] ?? '').trim();
                  final overdue = (q['overdue'] ?? '').trim() == '1';
                  final from = (q['from'] ?? '').trim();
                  final to = (q['to'] ?? '').trim();
                  if (status.isNotEmpty || overdue || from.isNotEmpty ||
                      to.isNotEmpty) {
                    cubit.seedFilters(
                      NcrFilters(
                        statuses: {if (status.isNotEmpty) status},
                        onlyOverdue: overdue,
                        from: from,
                        to: to,
                      ),
                    );
                  }
                  return cubit
                    ..loadOptions()
                    ..load();
                },
                child: QcNcrListScreen(
                  onOpenFinding: (id) =>
                      context.push('${AppRoutes.qcNcrDetail}?findingId=$id'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.qcNcrDetail,
            pageBuilder: (c, s) => AppPage<QcNcrDetailScreen>(
              name: s.uri.path,
              builder: (context) {
                final id = int.tryParse(
                  s.uri.queryParameters['findingId'] ?? '',
                );
                return BlocProvider(
                  create: (_) => getIt<QcNcrCubit>(),
                  child: QcNcrDetailScreen(findingId: id),
                );
              },
            ),
          ),
          // ── QC routine lists (daily/monthly checklists) ────────────────────
          GoRoute(
            path: AppRoutes.qcInspections,
            pageBuilder: (c, s) => AppPage<RoutineListsScreen>(
              name: s.uri.path,
              // The hub cubit carries the list scope, created per visit and
              // closed by the router's scope on pop.
              builder: (context) => BlocProvider(
                create: (_) => getIt<RoutineListsCubit>()..load(),
                child: const RoutineListsScreen(),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.qcInspectionDetail,
            pageBuilder: (c, s) => AppPage<RoutineSheetScreen>(
              name: s.uri.path,
              builder: (context) {
                final id = int.tryParse(
                  s.uri.queryParameters['inspectionId'] ?? '',
                );
                if (id == null) {
                  return const SizedBox.shrink();
                }
                return BlocProvider(
                  create: (_) =>
                      getIt<RoutineSheetCubit>(param1: id)..load(),
                  child: RoutineSheetScreen(inspectionId: id),
                );
              },
            ),
          ),
          // ── QC SOPs (plan V6_ENHANCED P5) ────────────────────────────────
          GoRoute(
            path: AppRoutes.qcSops,
            pageBuilder: (c, s) => AppPage<QcSopsScreen>(
              name: s.uri.path,
              // The register cubit carries the filter scope and is also what the
              // detail screen pushes a lifecycle change through, so it is created
              // per visit and closed with the route.
              builder: (context) => BlocProvider(
                create: (_) => getIt<QcSopsCubit>()..load(),
                child: const QcSopsScreen(),
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
      case AppRoutes.settings:
      case AppRoutes.reference:
        if (!session.permissions.contains(Permission.orgRead)) {
          return AppRoutes.dashboard;
        }
      case AppRoutes.inspectionNew:
        // A write form is never opened by a read-only device.
        if (!session.canWrite) return AppRoutes.dashboard;
      case AppRoutes.qcNcr:
      case AppRoutes.qcManagement:
      case AppRoutes.qcNcrList:
      case AppRoutes.qcNcrDetail:
      case AppRoutes.qcInspections:
      case AppRoutes.qcInspectionDetail:
      case AppRoutes.qcSops:
        // The NCR report, the SOP register and the routine
        // lists are all QC
        // destinations gated on `qcRead`: the pages themselves are readable, and
        // the write paths (create, edit, check) are refused by the
        // repository when the session lacks `qcWrite`.
        if (!session.permissions.contains(Permission.qcRead)) {
          return AppRoutes.dashboard;
        }
    }
    return null;
  }
}
