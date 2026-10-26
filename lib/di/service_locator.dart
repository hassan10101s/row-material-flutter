import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:get_it/get_it.dart';

import '../core/commands/command_outbox.dart';
import '../core/commands/central_authoring_gateway.dart';
import '../core/commands/central_projection.dart';
import '../core/commands/central_sync_driver.dart';
import '../core/commands/central_sync_transport.dart';
import '../core/commands/command_contract.dart';
import '../core/commands/command_service.dart';
import '../core/commands/command_transport.dart';
import '../core/commands/command_worker.dart';
import '../core/commands/drafts_store.dart';
import '../core/commands/local_read_model.dart';
import '../core/commands/sync_checkpoint.dart';
import '../app/auth_gate.dart';
import '../app/auto_backup_task.dart';
import '../core/app_paths.dart';
import '../core/auth/device_identity_store.dart';
import '../core/auth/session_source.dart';
import '../core/auth/session_store.dart';
import '../core/database/database_helper.dart';
import '../core/utils/app_exceptions.dart';
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
import '../core/auth/permissions.dart';
import '../core/sync/remote/firestore_push_registration.dart';
import '../core/sync/audit_trail.dart';
import '../core/sync/backfill_service.dart';
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
import '../features/auth/domain/auth_repository.dart';
import '../features/auth/data/offline_first_auth_repository.dart';
import '../features/audit/presentation/audit_controller.dart';
import '../features/backup/data/backup_manager.dart';
import '../app/headless.dart' show isHeadlessBackground;
import '../app/notif_poll_task.dart';
import '../features/notifications/data/fcm_push_service.dart';
import '../features/notifications/data/notification_service.dart';
import '../features/notifications/domain/notifications_port.dart';
import '../features/notifications/presentation/notification_controller.dart';
import '../features/backup/domain/backup_service.dart';
import '../features/dashboard/data/dashboard_repo.dart';
import '../features/dashboard/domain/dashboard_repository.dart';
import '../features/inspections/data/inspection_repo.dart';
import '../features/inspections/data/offline_first_inspection_repository.dart';
import '../features/inspections/domain/inspection_repository.dart';
import '../features/lab/data/lab_repo.dart';
import '../features/formulations/domain/formulation_repository.dart';
import '../features/formulations/data/sqlite_formulation_repository.dart';
import '../features/lab/data/nir_validation_repo.dart';
import '../features/lab/data/offline_first_lab_repository.dart';
import '../features/lab/domain/lab_local_repository.dart';
import '../features/lab/domain/lab_result_repository.dart';
import '../features/lab/domain/nir_validation_repository.dart';
import '../features/lab/domain/product_batch_repository.dart';
import '../features/members/domain/member_repository.dart';
import '../features/organizations/data/firestore_organization_repository.dart';
import '../features/organizations/data/member_write_guard.dart';
import '../features/organizations/domain/organization_repository.dart';
import '../features/reference/data/offline_first_reference_repository.dart';
import '../features/reference/data/reference_repo.dart';
import '../features/reference/domain/reference_repository.dart';
import '../features/qc_manager/data/ncr_report_repo.dart';
import '../features/qc_manager/data/offline_first_qc_repository.dart';
import '../features/qc_manager/data/offline_first_qc_custom_tables.dart';
import '../features/qc_manager/data/qc_audit_repo.dart';
import '../features/qc_manager/data/qc_repo.dart';
import '../features/qc_manager/data/qc_custom_tables_repo.dart';
import '../features/qc_manager/domain/qc_repositories.dart';
import '../features/qc_manager/data/ncr_export_service.dart';
import '../features/qc_manager/data/routine_lists_repository.dart'; // RoutineListsRepositoryImpl
import '../features/qc_manager/domain/ncr_report_repository.dart';
import '../features/qc_manager/presentation/cubit/qc_custom_tables_cubit.dart';
import '../features/qc_manager/presentation/cubit/qc_table_rows_cubit.dart';
import '../features/qc_manager/presentation/cubit/qc_sops_cubit.dart';
import '../features/qc_manager/presentation/cubit/qc_ncr_cubit.dart';
import '../features/qc_manager/presentation/routine/routine_history_cubit.dart';
import '../features/qc_manager/presentation/routine/routine_lists_cubit.dart';
import '../features/qc_manager/presentation/routine/routine_sheet_cubit.dart';
import '../features/reports/data/report_html_builder.dart';
import '../features/reports/data/report_service.dart';
import '../features/reports/domain/report_repository.dart';
import '../features/settings/data/settings_repo.dart';
import '../features/settings/domain/settings_repository.dart';
import '../features/settings/domain/export_root_service.dart';

/// Global service locator (get_it). Registration happens once in
/// [initServiceLocator] during app bootstrap.
///
/// Order matters: Firebase first (it decides whether the app runs online or
/// degraded), then the per-organization database, then the repositories, and
/// finally the sync engine which is started only after an organization is bound.
final GetIt getIt = GetIt.instance;

const centralCommandPilotEnabled = bool.fromEnvironment(
  'ENABLE_CENTRAL_COMMAND_PILOT',
);

/// Manual constructors because the repos need the runtime DB path resolved
/// from AppPaths (path_provider is only callable after runApp).
Future<void> initServiceLocator() async {
  getIt
    ..registerLazySingleton<AppPaths>(AppPaths.new)
    ..registerLazySingleton<ConnectivityService>(ConnectivityService.new);

  final secret = await _localSecret();
  // The QR scanner needs the same seal key the reports were sealed with to
  // verify same-device prints (cross-device prints resolve by entry code).
  getIt.registerSingleton<LocalSecret>(secret);
  final dbHelper = await _databaseHelper();
  final hasher = PasswordHasher(
    pepper: String.fromCharCodes(await secret.load()),
  );

  // ── Firebase + identity ────────────────────────────────────────────────
  final bootstrap = await FirebaseBootstrap.initialize();
  final firestore = bootstrap.isReady ? FirebaseFirestore.instance : null;
  final firebaseAuth = bootstrap.isReady ? FirebaseAuth.instance : null;
  final remote = FirestoreDataSource(firestore: firestore, auth: firebaseAuth);
  final authRemote = AuthRemoteDataSourceImpl(
    // Use the same remote adapter for auth, organizations and sync. Creating
    // a second adapter around the same Firebase handles split tracing,
    // configuration and retry behavior between otherwise identical services.
    firestore: remote,
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
    identities: DeviceIdentityStore(),
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
      () => SessionWriteGuard(
        source: sessionSource,
        isOnline: () => connectivity.isOnline,
      ),
    )
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
      () => SettingsRepo(
        dbHelper: dbHelper,
        secret: secret,
        paths: getIt<AppPaths>(),
        queue: queue,
        guard: getIt<WriteGuard>(),
      ),
    )
    ..registerLazySingleton<SettingsRepository>(
      () => getIt<SettingsRepo>() as SettingsRepository,
    )
    ..registerLazySingleton<ExportRootService>(
      () => ExportRootService(
        repo: getIt<SettingsRepo>(),
        paths: getIt<AppPaths>(),
      ),
    )
    ..registerLazySingleton<ThemeService>(
      () => ThemeService(settings: getIt<SettingsRepo>()),
    )
    ..registerLazySingleton<LocaleService>(
      () => LocaleService(settings: getIt<SettingsRepo>()),
    )
    // The offline-first facades are registered under the *old* concrete names,
    // so no cubit or widget changes (plan P5.4). Both are also exposed under
    // their domain contract, which is what new code should depend on.
    ..registerLazySingleton<ReferenceRepo>(
      () => referenceFacade ??= OfflineFirstReferenceRepository(
        dbHelper: dbHelper,
        // Device-scoped entry codes: minted rows carry this device's tag so
        // two offline devices can never mint the same entry_code (which is
        // also the sync document id). Empty before registration → legacy.
        deviceTagProvider: () =>
            getIt<SyncMetadata>().get(SyncMetadata.deviceIdKey),
        guard: getIt<WriteGuard>(),
        queue: queue,
        audit: audit,
      ),
    )
    ..registerLazySingleton<ReferenceRepository>(
      () => getIt<ReferenceRepo>() as ReferenceRepository,
    )
    ..registerLazySingleton<LabRepo>(
      () => labFacade ??= OfflineFirstLabRepository(
        dbHelper: dbHelper,
        guard: getIt<WriteGuard>(),
        queue: queue,
        audit: audit,
      ),
    )
    ..registerLazySingleton<LabResultRepository>(
      () => getIt<LabRepo>() as LabResultRepository,
    )
    ..registerLazySingleton<LabConfigurationRepository>(
      () => getIt<LabRepo>() as LabConfigurationRepository,
    )
    ..registerLazySingleton<LabLocalRepository>(
      () => getIt<LabRepo>() as LabLocalRepository,
    )
    ..registerLazySingleton<FormulationRepository>(
      () => SqliteFormulationRepository(
        dbHelper: dbHelper,
        guard: getIt<WriteGuard>(),
        queue: queue,
        audit: audit,
      ),
    )
    ..registerLazySingleton<ProductBatchRepository>(
      () => getIt<LabRepo>() as ProductBatchRepository,
    )
    // ── NIR فلديشن (device validation) ───────────────────────────────────
    ..registerLazySingleton<NirValidationRepo>(
      () => NirValidationRepo(
        dbHelper: dbHelper,
        guard: getIt<WriteGuard>(),
        queue: queue,
        audit: audit,
      ),
    )
    ..registerLazySingleton<NirValidationRepository>(
      () => getIt<NirValidationRepo>() as NirValidationRepository,
    )
    ..registerLazySingleton<ReportHtmlBuilder>(
      () => ReportHtmlBuilder(
        settingsRepo: getIt<SettingsRepo>(),
        labRepo: getIt<LabRepo>(),
        secret: secret,
      ),
    )
    ..registerLazySingleton<InspectionRepo>(
      () => inspectionFacade ??= OfflineFirstInspectionRepository(
        dbHelper: dbHelper,
        referenceRepo: getIt<ReferenceRepo>(),
        htmlBuilder: getIt<ReportHtmlBuilder>(),
        guard: getIt<WriteGuard>(),
        queue: queue,
        audit: audit,
      ),
    )
    ..registerLazySingleton<InspectionRepository>(
      () => getIt<InspectionRepo>() as InspectionRepository,
    )
    ..registerLazySingleton<SampleRepository>(
      () => getIt<InspectionRepo>() as SampleRepository,
    )
    ..registerLazySingleton<QualityCheckRepository>(
      () => getIt<InspectionRepo>() as QualityCheckRepository,
    )
    ..registerLazySingleton<DashboardRepo>(
      () => DashboardRepo(dbHelper: dbHelper),
    )
    ..registerLazySingleton<DashboardRepository>(
      () => getIt<DashboardRepo>() as DashboardRepository,
    )
    ..registerLazySingleton<SeedService>(() => SeedService(dbHelper: dbHelper))
    ..registerLazySingleton<BackupManager>(
      () => BackupManager(dbHelper: dbHelper),
    )
    ..registerLazySingleton<BackupService>(
      () => getIt<BackupManager>() as BackupService,
    )
    ..registerLazySingleton<ReportService>(
      () => ReportService(
        settingsRepo: getIt<SettingsRepo>(),
        inspectionRepo: getIt<InspectionRepo>(),
        labRepo: getIt<LabRepo>(),
        dbHelper: dbHelper,
        secret: secret,
        htmlBuilder: getIt<ReportHtmlBuilder>(),
        guard: getIt<WriteGuard>(),
      ),
    )
    ..registerLazySingleton<ReportRepository>(
      () => getIt<ReportService>() as ReportRepository,
    )
    // ── Organizations / members ───────────────────────────────────────────
    ..registerLazySingleton<OrganizationRepository>(() {
      final guard = getIt<WriteGuard>();
      return FirestoreOrganizationRepository(remote: authRemote, guard: guard);
    })
    ..registerLazySingleton<MemberRepository>(
      () => getIt<OrganizationRepository>().members,
    )
    // ── Device registry + audit trail (plan §9.7 / §14-P9) ────────────────
    ..registerLazySingleton<AuditTrail>(
      () => AuditTrail(audit: audit, metadata: metadata, devices: devices),
    )
    ..registerFactory<AuditController>(
      () => AuditController(getIt<AuditTrail>()),
    )
    // ── QC Manager (plan V6_ENHANCED P3) ───────────────────────────────────
    // One [QcRepositories] holds all five contracts over the same guard and
    // the same transaction boundary. Registering them individually would hand
    // out five independently-built stacks and let a caller audit one entity
    // while writing another.
    ..registerLazySingleton<QcRepositories>(() {
      return QcRepositories.offlineFirst(
        dbHelper: dbHelper,
        guard: getIt<WriteGuard>(),
        // Read through SessionSource at write time, never captured at
        // registration: a sign-out or a user switch must change who the next
        // audit row names. `QcActor.fromSession` holds the mapping rules.
        actorReader: () => QcActor.fromSession(sessionSource.session),
        // P8: the checklists / sheets / NC-CAPA rows now push through the
        // same sync queue the lab stack uses. The writer guards itself on an
        // unbound account, so offline writes stay purely local there.
        queue: queue,
        syncAudit: audit,
      );
    })
    ..registerLazySingleton<QcSopRepository>(() => getIt<QcRepositories>().sops)
    ..registerLazySingleton<QcTemplateRepository>(
      () => getIt<QcRepositories>().templates,
    )
    ..registerLazySingleton<QcInspectionRepository>(
      () => getIt<QcRepositories>().inspections,
    )
    ..registerLazySingleton<QcNcCapaRepository>(
      () => getIt<QcRepositories>().ncCapa,
    )
    ..registerLazySingleton<QcAuditRepository>(
      () => getIt<QcRepositories>().audit,
    )
    // ── QC custom tables (the QC settings feature) ────────────────────────
    // A family of its own rather than a seventh member of [QcRepositories]:
    // it is the first QC stack wired into the sync queue (its writes go
    // through `sync_write.enqueueLocalChange`), while the six above stay
    // device-local by design (plan P8). Registering it separately keeps that
    // architectural boundary visible - and keeps the other facades' tests
    // free of a queue they do not use.
    ..registerLazySingleton<QcCustomTablesRepository>(() {
      return OfflineFirstQcCustomTablesRepository(
        local: QcCustomTablesRepo(dbHelper),
        guard: getIt<WriteGuard>(),
        dbHelper: dbHelper,
        queue: queue,
        syncAudit: audit,
      );
    })
    // The defs cubit is a factory (not lazy singleton) for the same reason
    // the others are: it holds scope. But the hub and the settings screen
    // must share defs, so the hub BlocProvider owns it and hands the same
    // instance to the gear screen; the factory keeps that ownership one
    // widget away instead of ambient.
    ..registerFactory<QcCustomTablesCubit>(
      () => QcCustomTablesCubit(repo: getIt<QcCustomTablesRepository>()),
    )
    // [registerFactoryParam]: the records screen asks for its cubit with a
    // `tableId`, and a plain factory cannot accept one.
    ..registerFactoryParam<QcTableRowsCubit, int, void>(
      (tableId, _) => QcTableRowsCubit(
        tableId: tableId,
        repo: getIt<QcCustomTablesRepository>(),
      ),
    )
    // ── QC NCR report (plan V6_ENHANCED P7) ───────────────────────────────
    // A read-only projection, registered on its own rather than folded into
    // [QcRepositories]: it deliberately bypasses the write guard and the audit
    // chain because it never mutates anything, and routing it through the
    // audited stack would log a hash-chained row per row *read*.
    ..registerLazySingleton<QcNcReportRepo>(
      () => QcNcReportRepo(dbHelper: dbHelper),
    )
    ..registerLazySingleton<QcNcReportRepository>(() => getIt<QcNcReportRepo>())
    ..registerFactory<NcrExportService>(NcrExportService.new)
    // One cubit per screen: it holds the active filter and the current page, so
    // a singleton would leak one user's report scope into the next screen that
    // happens to ask for the same type.
    ..registerFactory<QcNcrCubit>(
      () => QcNcrCubit(getIt<QcNcReportRepository>()),
    )
    // ── QC inspections (plan V6_ENHANCED P2) ─────────────────────────────────
    // The register cubit carries the filter scope *and* the paged rows, and the
    // "start an inspection" form reuses that same instance so a newly created
    // sheet appears in the list behind it without a second refresh call.
    //
    // [registerFactoryParam] for the sheet cubit: the detail route asks for
    // it with an `inspectionId`, and the sheet must not outlive its screen -
    // it holds the in-flight check being written.
    ..registerLazySingleton<RoutineListsRepository>(
      () => RoutineListsRepositoryImpl(
        dbHelper: getIt<QcRepositories>().dbHelper,
        guard: getIt<WriteGuard>(),
        audit: QcAuditRepo(
          dbHelper: getIt<QcRepositories>().dbHelper,
          // Same live-session rule as the main QC stack: the routine sheet
          // stamps names, not emails (resolved at write time).
          actorReader: () => QcActor.fromSession(sessionSource.session),
        ),
        templates: QcTemplateRepo(getIt<QcRepositories>().dbHelper),
        inspections: QcInspectionRepo(getIt<QcRepositories>().dbHelper),
        // Routine checklist writes must enter the same outbox path as the
        // other QC repositories. Omitting this kept this one feature local.
        queue: queue,
        syncAudit: audit,
      ),
    )
    ..registerFactory<RoutineListsCubit>(
      () => RoutineListsCubit(repo: getIt<RoutineListsRepository>()),
    )
    ..registerFactoryParam<RoutineSheetCubit, int, void>(
      (inspectionId, _) => RoutineSheetCubit(
        repo: getIt<RoutineListsRepository>(),
        inspectionId: inspectionId,
      ),
    )
    ..registerFactory<RoutineHistoryCubit>(
      () => RoutineHistoryCubit(repo: getIt<RoutineListsRepository>()),
    )
    // ── QC SOPs (plan V6_ENHANCED P5) ──────────────────────────────────────
    // The register cubit is per-screen: it
    // carries the active filter scope. The SOP detail cubit is built by the
    // detail screen from *this* instance rather than from DI, so advancing a
    // procedure also refreshes the list still sitting behind it - two
    // independently-built registers would each need its own refresh call, and
    // the one nobody fires is the one the user sees as stale.
    ..registerFactory<QcSopsCubit>(
      () => QcSopsCubit(repo: getIt<QcSopRepository>()),
    )
    // ── Sync engine ───────────────────────────────────────────────────────
    ..registerLazySingleton<ConflictResolver>(
      () => ConflictResolver(
        queue: queue,
        remote: remote,
        source: getIt<SessionSource>(),
      ),
    )
    // Temporary backfill uploader: re-queues local rows that never reached
    // the server so the next syncNow pushes them in batches.
    ..registerLazySingleton<BackfillService>(
      () => BackfillService(
        dbHelper: dbHelper,
        queue: queue,
        guard: getIt<WriteGuard>(),
      ),
    )
    // ── Central command protocol (plan SYNC_ARCHITECTURE_PLAN_2026-10-25) ─
    // New stores: drafts / command outbox / checkpoint. Registered next to the
    // legacy stack for staged tests. Pilot sends require explicit opt-in and a server gate.
    ..registerSingleton<DraftsStore>(
      DraftsStore(dbHelper)
        ..scopeProvider = () {
          final session = sessionSource.session;
          return session.isSignedIn
              ? CommandScope(
                  session.organizationId,
                  session.uid,
                  session.deviceId,
                )
              : null;
        },
    )
    ..registerSingleton<SyncCheckpoints>(SyncCheckpoints(dbHelper))
    ..registerSingleton<CommandOutbox>(
      CommandOutbox(dbHelper)
        ..deviceProvider = () {
          return sessionSource.session.deviceId;
        }
        ..scopeProvider = () {
          final session = sessionSource.session;
          return session.isSignedIn
              ? CommandScope(
                  session.organizationId,
                  session.uid,
                  session.deviceId,
                )
              : null;
        },
    )
    ..registerSingleton<CommandTransport>(
      bootstrap.isReady
          ? CloudFunctionsCommandTransport(
              useRest: Platform.isWindows,
              projectId: bootstrap.config.projectId,
              auth: firebaseAuth,
            )
          : const UnconfiguredCommandTransport(),
    )
    ..registerSingleton<CommandWorker>(
      CommandWorker(
          outbox: getIt<CommandOutbox>(),
          transport: getIt<CommandTransport>(),
        )
        ..onError = (error) {
          debugPrint('[commands] $error');
        }
        ..canSend = () =>
            centralCommandPilotEnabled &&
            sessionSource.session.isSignedIn &&
            sessionSource.session.canWrite &&
            connectivity.isOnline,
    )
    ..registerSingleton<CentralProjection>(
      CentralProjection(databaseHelper: dbHelper, source: sessionSource),
    )
    ..registerSingleton<CentralSyncTransport>(
      CentralSyncTransport(
        useRest: Platform.isWindows,
        projectId: bootstrap.isReady ? bootstrap.config.projectId : null,
        auth: firebaseAuth,
      ),
    )
    ..registerSingleton<CentralSyncDriver>(
      CentralSyncDriver(
        databaseHelper: dbHelper,
        source: sessionSource,
        projection: getIt<CentralProjection>(),
        transport: getIt<CentralSyncTransport>(),
        outbox: getIt<CommandOutbox>(),
        metadata: metadata,
        onError: (error) => debugPrint('[central-sync] $error'),
      ),
    )
    ..registerSingleton<CommandService>(
      CommandService(
        dbHelper: dbHelper,
        drafts: getIt<DraftsStore>(),
        outbox: getIt<CommandOutbox>(),
        readModel: LocalReadModelState(dbHelper),
      )..onDrainRequested = _drainCommands,
    )
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
        allowPush: () => !centralCommandPilotEnabled,
        allowPull: () => !centralCommandPilotEnabled,
        allowAuditPull: () => true,
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
    })
    // ── Mobile-only new-item notifications ─────────────────────────────
    // Built over the same dbHelper/metadata the sync engine uses, so the
    // watermarks live in the per-organization database (plan D3).
    ..registerLazySingleton<NotificationService>(
      () => NotificationService(
        dbHelper: dbHelper,
        metadata: metadata,
        canReadNotification: (kind) => getIt<SessionSource>().session.can(
          kind == 'inspection'
              ? Permission.samplesRead
              : Permission.labResultsRead,
        ),
      ),
    )
    // The presentation-facing contract over the same instance.
    ..registerLazySingleton<NotificationsPort>(
      () => getIt<NotificationService>(),
    )
    ..registerLazySingleton<NotificationController>(
      () => NotificationController(getIt<NotificationsPort>()),
    )
    // Killed-app push (FCM topics `org_<orgId>`). Lazy so desktop builds
    // never touch firebase_messaging; initialized in startNotifications().
    ..registerLazySingleton<FcmPushService>(
      () => FcmPushService(
        notifications: getIt<NotificationService>(),
        source: getIt<SessionSource>(),
        registration: FirestorePushRegistration(),
      ),
    );

  // Central authoring is deliberately installed only when the explicit build
  // flag is present. Once installed every repository transaction enters the
  // savepoint/write-set gateway; legacy push is disabled above. Keeping this
  // as one assignment prevents a screen from silently choosing a second write
  // path.
  if (centralCommandPilotEnabled) {
    final gateway = CentralAuthoringGateway(
      databaseHelper: dbHelper,
      source: sessionSource,
      outbox: getIt<CommandOutbox>(),
      complete: (entry) async {
        if (!connectivity.isOnline) return false;
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        while (DateTime.now().isBefore(deadline)) {
          await getIt<CommandWorker>().runOnce();
          final settled = await getIt<CommandOutbox>().getByOperationId(
            entry.operationId,
          );
          if (settled == null) return false;
          switch (settled.state.value) {
            case 'approved':
              final sequence = settled.result?.changeSequence;
              if (sequence == null) return false;
              try {
                return await getIt<CentralSyncDriver>().syncNow(
                      throughSequence: sequence,
                    ) >=
                    sequence;
              } on Object {
                // The server receipt is durable; keep the UI in pending state
                // until its approved event is safely applied to the read model.
                return false;
              }
            case 'rejected':
            case 'needs_review':
              throw ValidationError(
                settled.lastError ??
                    'رفض السيرفر طلب الاعتماد؛ راجع شاشة المزامنة.',
              );
            case 'auth_required':
              throw AuthorizationError(
                settled.lastError ??
                    'انتهت الجلسة؛ سجّل الدخول ثم أعد المحاولة.',
              );
            default:
              await Future<void>.delayed(const Duration(milliseconds: 250));
          }
        }
        return false;
      },
    );
    dbHelper.businessGateway = gateway;
    getIt.registerSingleton<CentralAuthoringGateway>(gateway);
  }

  debugPrint(
    '[bootstrap] service locator ready (firebase: ${bootstrap.status.name})',
  );
}

/// Debounced drain of the command outbox. `onEnqueued` can burst (a form save
/// loop); one pending microtask per window covers them all.
Timer? _commandDrainTimer;

void _drainCommands() {
  if (!centralCommandPilotEnabled) return;
  _commandDrainTimer?.cancel();
  _commandDrainTimer = Timer(const Duration(milliseconds: 400), () {
    try {
      if (getIt.isRegistered<CommandWorker>()) {
        unawaited(
          getIt<CommandWorker>().runOnce().catchError((Object error) {
            debugPrint('[commands] drain failed: $error');
            return SweepReport.empty;
          }),
        );
      }
    } on Object catch (e) {
      debugPrint('[commands] drain skipped: $e');
    }
  });
}

/// Wires the "organization bound" side effects (defaults → seeds → lab defaults
/// → auto backup → `org_bound_at` → device registry). Kept here so the
/// repository never imports a feature module.
///
/// The binder runs for `active` members only (the repository guarantees it):
/// a pending/disabled account never opens the company database and never
/// starts the sync cycle (plan §8). Sign-out stops the engine again.
Future<void> registerOrganizationBinder(AuthRepository auth) async {
  if (auth is OfflineFirstAuthRepository) {
    auth.onOrganizationBound = (organizationId) async {
      await getIt<SettingsRepo>().ensureDefaults();
      // Headless background polls re-bind the org every 15 min in a separate
      // isolate that shares the same SQLite file: skip everything except the
      // cheap defaults + bound marker. Seeds, lab defaults, backups, device
      // registration and the sync engine all contend for the file lock
      // (BEGIN EXCLUSIVE ~5s stall) and the dispatcher drives its own
      // pull + notification scan directly.
      if (isHeadlessBackground) {
        await getIt<SyncMetadata>().markOrgBound(DateTime.now());
        debugPrint('[bootstrap] organization $organizationId bound (headless)');
        return;
      }
      // Perf: first two seeds are independent (reference data vs lab defaults);
      // run concurrently, then sync links (needs both). Same final state,
      // ~1 IO batch saved on org bind / cold start.
      await Future.wait([
        getIt<SeedService>().ensureInitialImport(),
        getIt<LabRepo>().ensureDefaultAnalyses(),
      ]);
      await getIt<LabRepo>().syncReferenceAnalyses();
      // VACUUM INTO rewrites the whole file while holding the single
      // connection: never block the bind (first frame / auth state) on it.
      // Fire-and-forget with its own error handling inside autoBackup.
      unawaited(getIt<BackupManager>().autoBackup());
      await getIt<SyncMetadata>().markOrgBound(DateTime.now());
      // Register this device once per organization (plan §8.5 step 4) and then
      // let the engine start: the queue is now bound to the right database.
      try {
        await getIt<DeviceRegistry>().ensureRegistered(force: true);
      } on Object catch (e) {
        debugPrint('[bootstrap] device registration skipped: $e');
      }
      getIt<SyncEngine>().start();
      // The command worker re-sends staged drafts on connection/open; a
      // staged row whose transport dropped keeps its operationId (§5).
      if (centralCommandPilotEnabled) {
        getIt<CommandWorker>().start();
        // A fresh sign-in for the same account/organization/device (the
        // outbox scope guarantees the match) re-queues `auth_required`
        // requests under their original operationId + hash, with the draft
        // state updated in the same transaction (production acceptance 3).
        try {
          final requeued = await getIt<CommandOutbox>().retryRejected(
            onlyPendingable: true,
          );
          if (requeued > 0) _drainCommands();
        } on Object catch (e) {
          debugPrint('[commands] auth requeue skipped: $e');
        }
        getIt<CentralSyncDriver>().start();
      }
      // Only durable, explicitly staged writes may be uploaded. Historical
      // local rows without an outbox entry are not adopted by this session.
      // Mobile-only bell: same hooks as app startup (engine start above does
      // not run them on an org switch). Best effort, never fails the bind.
      if ((Platform.isAndroid || Platform.isIOS) && !isHeadlessBackground) {
        try {
          final controller = getIt<NotificationController>();
          controller.resetForSession();
          if (centralCommandPilotEnabled) {
            getIt<CentralSyncDriver>().onApplied = () =>
                controller.refresh(showOs: true);
          }
          // Pulled rows (other devices) -> bell + OS notification. Own saves
          // stay silent via the onEnqueued hook below (they watermark first).
          getIt<SyncEngine>().onPullApplied = () =>
              controller.refresh(showOs: true);
          // Own saves -> bell within seconds. Chains the engine's debounced
          // push (buildSyncEngine sets onEnqueued to scheduleSync); without
          // this, saves after an org switch would only surface on next pull.
          final queue = getIt<SyncQueue>();
          queue.onEnqueued = () {
            getIt<SyncEngine>().scheduleSync();
            unawaited(controller.refresh());
          };
          // Sync problems -> bell: when the engine's conflict/blocked/failed
          // total changes between cycles, store a `sync` bell row + OS head.
          // [notifySyncProblems] dedupes per count, so a stable problem does
          // not spam; the refresh afterwards lets the 30 s timer wait.
          getIt<SyncEngine>().onProblemsChanged = (conflicts, blocked, failed) {
            unawaited(() async {
              try {
                await getIt<NotificationService>().notifySyncProblems(
                  conflicts: conflicts,
                  blocked: blocked,
                  failed: failed,
                );
                await controller.refresh();
              } on Object catch (e) {
                debugPrint('[bootstrap] sync problem notify skipped: $e');
              }
            }());
          };
          // Bell populates without blocking the bind: `load` is two cheap
          // reads (recent + unread count) fired off while the bind returns,
          // and the heavier watermark scans wait for the pull hooks and the
          // 30 s timer instead of stalling startup on the FFI lock.
          unawaited(controller.load());
          controller.startAutoRefresh(showOs: true);
          // Killed-app push follows the org: (re)subscribe to the new
          // `org_<id>` topic so Cloud Function fan-out reaches this device
          // even when the app is killed. Old topic is unsubscribed inside.
          try {
            await getIt<FcmPushService>().setOrganization(organizationId);
          } on Object catch (e) {
            debugPrint('[bootstrap] fcm topic skipped: $e');
          }
          // Poll scheduling lives in startNotifications() (after the first
          // frame). Scheduling here too re-registers the periodic task on
          // every org bind and churns JobScheduler (cancel/schedule storm
          // visible in logcat as repeated Job ID bumps).
        } on Object catch (e) {
          debugPrint('[bootstrap] notifications skipped: $e');
        }
      }
      debugPrint('[bootstrap] organization $organizationId bound');
    };
    auth.onSignedOut = () async {
      _commandDrainTimer?.cancel();
      _commandDrainTimer = null;
      try {
        getIt<SyncEngine>().stop();
      } on Object catch (e) {
        debugPrint('[bootstrap] sync engine stop skipped: $e');
      }
      try {
        getIt<CommandWorker>().stop();
      } on Object catch (e) {
        debugPrint('[bootstrap] command worker stop skipped: $e');
      }
      if (getIt.isRegistered<CentralSyncDriver>()) {
        getIt<CentralSyncDriver>()
          ..stop()
          // An in-flight download must not keep applying pages into the
          // database after the session (and its org binding) is gone.
          ..cancelActive();
      }
      if (Platform.isAndroid || Platform.isIOS) {
        getIt<NotificationController>().resetForSession();
        try {
          await const AndroidNotifPollScheduler().cancel();
        } on Object {
          // Nothing was registered.
        }
        try {
          await getIt<FcmPushService>().setOrganization(null);
        } on Object {
          // Best effort.
        }
      }
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
