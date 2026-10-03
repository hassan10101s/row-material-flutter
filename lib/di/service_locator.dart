import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:get_it/get_it.dart';

import '../app/auth_gate.dart';
import '../app/auto_backup_task.dart';
import '../core/app_paths.dart';
import '../core/auth/session_source.dart';
import '../core/auth/session_store.dart';
import '../core/database/database_helper.dart';
import '../core/firebase/firebase_bootstrap.dart';
import '../core/locale/locale_service.dart';
import '../core/network/connectivity_service.dart';
import '../core/platform/auto_backup_scheduler.dart';
import '../core/platform/file_delivery.dart';
import '../core/platform/file_delivery_mobile.dart';
import '../core/platform/folder_picker.dart';
import '../core/security/local_secret.dart';
import '../core/security/password_hash.dart';
import '../core/services/seed_service.dart';
import '../core/sync/audit_logger.dart';
import '../core/sync/audit_trail.dart';
import '../core/sync/conflict_resolver.dart';
import '../core/sync/device_registry.dart';
import '../core/sync/entity_registry.dart';
import '../core/sync/pull_worker.dart';
import '../core/sync/push_worker.dart';
import '../core/sync/remote/auth_remote_data_source.dart';
import '../core/sync/remote/firestore_data_source.dart';
import '../core/sync/remote/remote_data_source.dart';
import '../core/sync/sync_engine.dart';
import '../core/sync/sync_metadata.dart';
import '../core/sync/sync_queue.dart';
import '../core/theme/theme_service.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/data/offline_first_auth_repository.dart';
import '../features/audit/presentation/audit_controller.dart';
import '../features/backup/data/backup_manager.dart';
import '../features/dashboard/data/dashboard_repo.dart';
import '../features/dashboard/domain/dashboard_repository.dart';
import '../features/inspections/data/inspection_repo.dart';
import '../features/inspections/data/offline_first_inspection_repository.dart';
import '../features/inspections/domain/inspection_repository.dart';
import '../features/lab/data/lab_repo.dart';
import '../features/lab/data/offline_first_lab_repository.dart';
import '../features/lab/domain/lab_local_repository.dart';
import '../features/lab/domain/lab_result_repository.dart';
import '../features/members/domain/member_repository.dart';
import '../features/organizations/data/firestore_organization_repository.dart';
import '../features/organizations/data/member_write_guard.dart';
import '../features/organizations/domain/organization_repository.dart';
import '../features/reference/data/offline_first_reference_repository.dart';
import '../features/reference/data/reference_repo.dart';
import '../features/reference/domain/reference_repository.dart';
import '../features/reports/data/report_html_builder.dart';
import '../features/reports/data/report_service.dart';
import '../features/reports/domain/report_repository.dart';
import '../features/settings/data/settings_repo.dart';
import '../features/settings/domain/export_root_service.dart';

/// Global service locator (get_it). Registration happens once in
/// [initServiceLocator] during app bootstrap.
///
/// Order matters: Firebase first (it decides whether the app runs online or
/// degraded), then the per-organization database, then the repositories, and
/// finally the sync engine which is started only after an organization is bound.
final GetIt getIt = GetIt.instance;

/// Manual constructors because the repos need the runtime DB path resolved
/// from AppPaths (path_provider is only callable after runApp).
Future<void> initServiceLocator() async {
  getIt
    ..registerLazySingleton<AppPaths>(AppPaths.new)
    ..registerLazySingleton<ConnectivityService>(ConnectivityService.new);

  final secret = await _localSecret();
  final dbHelper = await _databaseHelper();
  final hasher = PasswordHasher(pepper: String.fromCharCodes(await secret.load()));

  // ── Firebase + identity ────────────────────────────────────────────────
  final bootstrap = await FirebaseBootstrap.initialize();
  final firestore = bootstrap.isReady ? FirebaseFirestore.instance : null;
  final firebaseAuth = bootstrap.isReady ? FirebaseAuth.instance : null;
  final remote = FirestoreDataSource(firestore: firestore, auth: firebaseAuth);
  final authRemote = AuthRemoteDataSourceImpl(
    firestore: FirestoreDataSource(firestore: firestore, auth: firebaseAuth),
    google: GoogleAuthDataSourceImpl(),
    auth: firebaseAuth,
  );
  final connectivity = getIt<ConnectivityService>();
  final metadata = SyncMetadata(dbHelper);
  final queue = SyncQueue(dbHelper);
  final sessionStore = SessionStore();

  // The gate needs the repository and the repository needs the live session
  // (audit attribution, device registry). `late final` breaks the cycle: the
  // readers below are closures, they are only *called* once the gate exists.
  late final AuthGate gate;

  // §9.7 the actor/organization/device of an audit entry is read from the live
  // session at write time, never from a value captured at startup.
  final audit = AuditLogger(queue: queue, session: () => gate.session);
  final devices = DeviceRegistry(
    remote: remote,
    metadata: metadata,
    audit: audit,
    source: SessionSource(() => gate.session),
  );

  final authRepository = OfflineFirstAuthRepository(
    remote: authRemote,
    sessionStore: sessionStore,
    dbHelper: dbHelper,
    connectivity: connectivity,
    metadata: metadata,
    bootstrap: bootstrap,
    devices: devices,
  );
  gate = AuthGate(authRepository, connectivity: connectivity);

  // Pull-based session view: the guard and the workers are registered before
  // sign-in, so they must read the session lazily on every call (plan §9.4).
  final sessionSource = SessionSource(() => gate.session);

  // The offline-first facades: one instance each, exposed under the old
  // concrete name *and* under the domain contracts, so no cubit or widget
  // changes while new code can depend on the abstraction (plan P5.4).
  OfflineFirstLabRepository? labFacade;
  OfflineFirstInspectionRepository? inspectionFacade;
  OfflineFirstReferenceRepository? referenceFacade;

  getIt
    ..registerSingleton<FirebaseBootstrapResult>(bootstrap)
    ..registerSingleton<RemoteDataSource>(remote)
    ..registerSingleton<AuthRemoteDataSource>(authRemote)
    ..registerSingleton<SessionStore>(sessionStore)
    ..registerSingleton<AuthGate>(gate)
    ..registerSingleton<SessionSource>(sessionSource)
    ..registerSingleton<AuthRepository>(gate.auth)
    ..registerSingleton<SyncMetadata>(metadata)
    ..registerSingleton<SyncQueue>(queue)
    ..registerSingleton<AuditLogger>(audit)
    ..registerSingleton<DeviceRegistry>(devices)
    // §9.4 write guard, read live so sign-in/sign-out and connectivity changes
    // are picked up without re-registering. Every local write goes through it.
    ..registerLazySingleton<WriteGuard>(
        () => SessionWriteGuard(source: sessionSource, isOnline: () => connectivity.isOnline))
    ..registerLazySingleton<PasswordHasher>(() => hasher)
    // Platform ports (PLAN_V4 phase 2.5). Registered behind their abstraction so
    // presentation asks "can this platform do it" instead of branching on
    // `Platform.is*`, and so a test can substitute a double.
    ..registerLazySingleton<FileDelivery>(() {
      if (Platform.isAndroid || Platform.isIOS) {
        return const MobileFileDelivery();
      }
      return const DesktopFileDelivery();
    })
    ..registerLazySingleton<FolderPicker>(() {
      if (Platform.isAndroid || Platform.isIOS) {
        return const UnsupportedFolderPicker();
      }
      return const DesktopFolderPicker();
    })
    ..registerLazySingleton<AutoBackupScheduler>(() {
      if (Platform.isAndroid) return const AndroidBackupScheduler();
      return const NoopBackupScheduler();
    })
    ..registerLazySingleton<SettingsRepo>(
        () => SettingsRepo(dbHelper: dbHelper, secret: secret, paths: getIt<AppPaths>()))
    ..registerLazySingleton<ExportRootService>(() => ExportRootService(
          repo: getIt<SettingsRepo>(),
          paths: getIt<AppPaths>(),
        ))
    ..registerLazySingleton<ThemeService>(
        () => ThemeService(settings: getIt<SettingsRepo>()))
    ..registerLazySingleton<LocaleService>(
        () => LocaleService(settings: getIt<SettingsRepo>()))
    // The offline-first facades are registered under the *old* concrete names,
    // so no cubit or widget changes (plan P5.4). Both are also exposed under
    // their domain contract, which is what new code should depend on.
    ..registerLazySingleton<ReferenceRepo>(
        () => referenceFacade ??= OfflineFirstReferenceRepository(
              dbHelper: dbHelper,
              guard: getIt<WriteGuard>(),
              queue: queue,
              audit: audit,
            ))
    ..registerLazySingleton<ReferenceRepository>(
        () => getIt<ReferenceRepo>() as ReferenceRepository)
    ..registerLazySingleton<LabRepo>(() => labFacade ??= OfflineFirstLabRepository(
          dbHelper: dbHelper,
          guard: getIt<WriteGuard>(),
          queue: queue,
          audit: audit,
        ))
    ..registerLazySingleton<LabResultRepository>(() => getIt<LabRepo>() as LabResultRepository)
    ..registerLazySingleton<LabConfigurationRepository>(
        () => getIt<LabRepo>() as LabConfigurationRepository)
    ..registerLazySingleton<LabLocalRepository>(
        () => getIt<LabRepo>() as LabLocalRepository)
    ..registerLazySingleton<ReportHtmlBuilder>(() => ReportHtmlBuilder(
          settingsRepo: getIt<SettingsRepo>(),
          labRepo: getIt<LabRepo>(),
          secret: secret,
        ))
    ..registerLazySingleton<InspectionRepo>(() => inspectionFacade ??=
        OfflineFirstInspectionRepository(
          dbHelper: dbHelper,
          referenceRepo: getIt<ReferenceRepo>(),
          htmlBuilder: getIt<ReportHtmlBuilder>(),
          guard: getIt<WriteGuard>(),
          queue: queue,
          audit: audit,
        ))
    ..registerLazySingleton<InspectionRepository>(
        () => getIt<InspectionRepo>() as InspectionRepository)
    ..registerLazySingleton<SampleRepository>(
        () => getIt<InspectionRepo>() as SampleRepository)
    ..registerLazySingleton<QualityCheckRepository>(
        () => getIt<InspectionRepo>() as QualityCheckRepository)
    ..registerLazySingleton<DashboardRepo>(() => DashboardRepo(dbHelper: dbHelper))
    ..registerLazySingleton<DashboardRepository>(
        () => getIt<DashboardRepo>() as DashboardRepository)
    ..registerLazySingleton<SeedService>(() => SeedService(dbHelper: dbHelper))
    ..registerLazySingleton<BackupManager>(() => BackupManager(dbHelper: dbHelper))
    ..registerLazySingleton<ReportService>(() => ReportService(
          settingsRepo: getIt<SettingsRepo>(),
          inspectionRepo: getIt<InspectionRepo>(),
          labRepo: getIt<LabRepo>(),
          dbHelper: dbHelper,
          secret: secret,
          htmlBuilder: getIt<ReportHtmlBuilder>(),
        ))
    ..registerLazySingleton<ReportRepository>(
        () => getIt<ReportService>() as ReportRepository)
    // ── Organizations / members ───────────────────────────────────────────
    ..registerLazySingleton<OrganizationRepository>(() {
      final guard = getIt<WriteGuard>();
      return FirestoreOrganizationRepository(remote: authRemote, guard: guard);
    })
    ..registerLazySingleton<MemberRepository>(
        () => getIt<OrganizationRepository>().members)
    // ── Device registry + audit trail (plan §9.7 / §14-P9) ────────────────
    ..registerLazySingleton<AuditTrail>(() => AuditTrail(
          audit: audit,
          metadata: metadata,
          devices: devices,
        ))
    ..registerFactory<AuditController>(() => AuditController(getIt<AuditTrail>()))
    // ── Sync engine ───────────────────────────────────────────────────────
    ..registerLazySingleton<ConflictResolver>(
        () => ConflictResolver(queue: queue, remote: remote))
    ..registerLazySingleton<SyncEngine>(() {
      final pushWorker = PushWorker(
        queue: queue,
        remote: remote,
        metadata: metadata,
        audit: audit,
        source: sessionSource,
      );
      final pullWorker = PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: getIt<ConflictResolver>(),
        source: sessionSource,
      );
      // The audit trail is a separate collection with a separate permission,
      // so it gets its own cursor, its own cycle and a quiet permission error.
      final auditPullWorker = PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: getIt<ConflictResolver>(),
        source: sessionSource,
        entities: [auditLogEntity],
        quietPermissionErrors: true,
        marksPullTimestamp: false,
        maxPagesPerCycle: 2,
      );
      return buildSyncEngine(
        pushWorker: pushWorker,
        pullWorker: pullWorker,
        auditPullWorker: auditPullWorker,
        trail: getIt<AuditTrail>(),
        queue: queue,
        metadata: metadata,
        audit: audit,
        connectivity: connectivity,
        conflicts: getIt<ConflictResolver>(),
        remote: remote,
      );
    });

  debugPrint('[bootstrap] service locator ready (firebase: ${bootstrap.status.name})');
}

/// Wires the "organization bound" side effects (defaults → seeds → lab defaults
/// → auto backup → `org_bound_at` → device registry). Kept here so the
/// repository never imports a feature module.
Future<void> registerOrganizationBinder(AuthRepository auth) async {
  if (auth is OfflineFirstAuthRepository) {
    auth.onOrganizationBound = (organizationId) async {
      await getIt<SettingsRepo>().ensureDefaults();
      await getIt<SeedService>().ensureInitialImport();
      await getIt<LabRepo>().ensureDefaultAnalyses();
      await getIt<LabRepo>().syncReferenceAnalyses();
      await getIt<BackupManager>().autoBackup();
      await getIt<SyncMetadata>().markOrgBound(DateTime.now());
      // Register this device once per organization (plan §8.5 step 4) and then
      // let the engine start: the queue is now bound to the right database.
      try {
        await getIt<DeviceRegistry>().ensureRegistered(force: true);
      } on Object catch (e) {
        debugPrint('[bootstrap] device registration skipped: $e');
      }
      getIt<SyncEngine>().start();
      debugPrint('[bootstrap] organization $organizationId bound');
    };
  }
}

Future<LocalSecret> _localSecret() async {
  final paths = AppPaths();
  final dir = await paths.appSupportRoot();
  return LocalSecret(dir.path);
}

Future<DatabaseHelper> _databaseHelper() async {
  final paths = AppPaths();
  DatabaseHelper.ensureDesktopFactory();
  return DatabaseHelper(paths);
}
