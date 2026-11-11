import '../core/security/secure_field_access.dart';
import '../core/security/secure_archive_coordinator.dart';
import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:get_it/get_it.dart';

import '../core/commands/command_outbox.dart';
import '../core/commands/central_authoring_gateway.dart';
import '../core/commands/domain_draft_service.dart';
import '../core/auth/access_monitor.dart';
import '../core/firebase/firestore_access_monitor.dart';
import '../core/commands/central_projection.dart';
import '../core/commands/central_sync_driver.dart';
import '../core/commands/central_sync_transport.dart';
import '../core/commands/command_contract.dart';
import '../core/commands/command_transport.dart';
import '../core/commands/direct_write_service.dart';
import '../core/commands/offline_write_prompt.dart';
import '../core/commands/pending_entity_actions.dart';
import '../core/commands/drafts_store.dart';
import '../core/commands/domain_manifest.dart';
import '../core/commands/firestore_direct_store.dart';
import '../core/commands/firestore_direct_command_transport.dart';
import '../core/commands/firestore_direct_sync_reader.dart';
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
import '../core/security/id_token_auth_time.dart';
import '../core/security/password_hash.dart';
import '../core/services/seed_service.dart';
import '../core/sync/audit_logger.dart';
import '../core/auth/permissions.dart';
import '../core/sync/audit_trail.dart';
import '../core/sync/device_registry.dart';
import '../core/sync/remote/auth_remote_data_source.dart';
import '../core/sync/remote/firestore_data_source.dart';
import '../core/sync/remote/remote_data_source.dart';
import '../core/sync/sync_metadata.dart';
import '../core/sync/sync_queue.dart';
import '../core/theme/theme_service.dart';
import '../features/auth/domain/auth_repository.dart';
import '../features/auth/data/firebase_auth_repository.dart';
import '../features/audit/presentation/audit_controller.dart';
import '../features/backup/data/backup_manager.dart';
import '../app/headless.dart' show isHeadlessBackground;
import '../app/notif_poll_task.dart';
import '../features/notifications/data/notification_service.dart';
import '../features/notifications/data/notification_delivery_store.dart';
import '../features/notifications/domain/notifications_port.dart';
import '../features/notifications/presentation/notification_controller.dart';
import '../features/backup/domain/backup_service.dart';
import '../features/dashboard/data/dashboard_repo.dart';
import '../features/dashboard/domain/dashboard_repository.dart';
import '../features/inspections/data/inspection_repo.dart';
import '../features/inspections/data/server_confirmed_inspection_repository.dart';
import '../features/inspections/domain/inspection_repository.dart';
import '../features/lab/data/lab_repo.dart';
import '../features/formulations/domain/formulation_repository.dart';
import '../features/formulations/data/sqlite_formulation_repository.dart';
import '../features/lab/data/nir_validation_repo.dart';
import '../features/lab/data/server_confirmed_lab_repository.dart';
import '../features/lab/domain/lab_local_repository.dart';
import '../features/lab/domain/lab_result_repository.dart';
import '../features/lab/domain/nir_validation_repository.dart';
import '../features/lab/domain/product_batch_repository.dart';
import '../features/members/domain/member_repository.dart';
import '../features/organizations/data/firestore_organization_repository.dart';
import '../features/organizations/data/member_write_guard.dart';
import '../features/organizations/domain/organization_repository.dart';
import '../features/reference/data/server_confirmed_reference_repository.dart';
import '../features/reference/data/reference_repo.dart';
import '../features/reference/domain/reference_repository.dart';
import '../features/qc_manager/data/ncr_report_repo.dart';
import '../features/qc_manager/data/server_confirmed_qc_repository.dart';
import '../features/qc_manager/data/server_confirmed_qc_custom_tables.dart';
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

// All business writes and downloads use the server-authoritative protocol.
// The old queue remains available only for safe migration and audit recovery.

/// Set once [initServiceLocator] has completed. The startup retry path
/// re-runs [appBootstrap] inside the same process, so this function can be
/// entered again after a bind failure; registration must stay a no-op then,
/// or get_it throws "Type … is already registered".
bool _serviceLocatorReady = false;

/// Manual constructors because the repos need the runtime DB path resolved
/// from AppPaths (path_provider is only callable after runApp).
Future<void> initServiceLocator() async {
  if (_serviceLocatorReady) return;
  getIt
    ..registerLazySingleton<AppPaths>(AppPaths.new)
    ..registerLazySingleton<ConnectivityService>(ConnectivityService.new);

  final secret = await _localSecret();
  // The QR scanner needs the same seal key the reports were sealed with to
  // verify same-device prints (cross-device prints resolve by entry code).
  getIt.registerSingleton<LocalSecret>(secret);
  final dbHelper = await _databaseHelper();
  getIt.registerSingleton<PendingEntityActions>(PendingEntityActions(dbHelper));
  getIt.registerSingleton<OfflineWritePrompt>(OfflineWritePrompt());
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
    // Audit writes must carry the *registered* device id (the rules accept an
    // audit entry only from an active device the signer owns). Read live from
    // the session at write time — `gate` is registered further below, and the
    // closure only runs once a member write happens, long after registration.
    deviceIdReader: () => getIt<AuthGate>().session.deviceId,
  );
  final connectivity = getIt<ConnectivityService>();
  final metadata = SyncMetadata(dbHelper);
  final queue = SyncQueue(dbHelper);
  final sessionStore = SessionStore();

  // Serialization for quarantined-record persistence: each skip report is
  // appended onto the previous write so concurrent skips never lose one.
  var quarantinePersist = Future<List<String>>.value([]);

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

  final authRepository = FirebaseAuthRepository(
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
  Map<String, dynamic>? directManifest;
  int? directManifestGeneration;
  Future<Map<String, dynamic>> loadDirectManifest() async {
    if (directManifestGeneration != dbHelper.connectionGeneration) {
      directManifest = await buildDomainManifest(await dbHelper.database);
      directManifestGeneration = dbHelper.connectionGeneration;
    }
    return directManifest!;
  }

  final directStore = bootstrap.isReady
      ? FirestoreDirectStore(
          projectId: bootstrap.config.projectId,
          tokenProvider: () async {
            final user = firebaseAuth?.currentUser;
            if (user == null || user.uid != sessionSource.session.uid) {
              return null;
            }
            return user.getIdToken();
          },
        )
      : null;
  if (directStore != null) {
    getIt.registerSingleton<FirestoreDirectStore>(
      directStore,
      dispose: (store) => store.close(),
    );
  }

  getIt.registerSingleton<SecureFieldAccess>(
    SecureFieldAccess(
      source: sessionSource,
      sessionChanges: gate,
      store: directStore,
      authTime: () async {
        final user = firebaseAuth?.currentUser;
        if (user == null || user.uid != sessionSource.session.uid) return null;
        final result = await user.getIdTokenResult();
        if (result.authTime != null) {
          return result.authTime!.millisecondsSinceEpoch ~/ 1000;
        }
        // The bundled Windows firebase_auth plugin returns only the token
        // string from getIdToken, so IdTokenResult.authTime stays null there.
        // The Rules compare the raw auth_time claim, so decode it from the
        // token itself: the value then matches request.auth.token.auth_time
        // on every platform.
        return idTokenAuthTime(result.token);
      },
    ),
    dispose: (access) => access.dispose(),
  );

  // The server-confirmed facades: one instance each, exposed under the old
  // concrete name *and* under the domain contracts, so no cubit or widget
  // changes while new code can depend on the abstraction (plan P5.4).
  ServerConfirmedLabRepository? labFacade;
  ServerConfirmedInspectionRepository? inspectionFacade;
  ServerConfirmedReferenceRepository? referenceFacade;

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
        organizationName: () => sessionSource.session.organizationName,
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
    // The server-confirmed facades are registered under the *old* concrete names,
    // so no cubit or widget changes (plan P5.4). Both are also exposed under
    // their domain contract, which is what new code should depend on.
    ..registerLazySingleton<ReferenceRepo>(
      () => referenceFacade ??= ServerConfirmedReferenceRepository(
        dbHelper: dbHelper,
        // Readable codes use the last six characters of the device identity;
        // remote UUIDs and server unique reservations protect shared records.
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
      () => labFacade ??= ServerConfirmedLabRepository(
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
        secureAccess: getIt<SecureFieldAccess>(),
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
      () => inspectionFacade ??= ServerConfirmedInspectionRepository(
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
      // The manual "refresh from server" action is resolved against the live
      // session at creation: only the organization manager (admin) shows the
      // single button that ever reads `auditLogs` from Firestore. Nothing
      // automatic ever syncs the trail again (November 10 decision).
      () => AuditController(
        getIt<AuditTrail>(),
        canFetchFromServer: getIt<AuditTrail>().canRead,
        refreshTrail: () => getIt<CentralSyncDriver>().refreshAuditTrail(),
      ),
    )
    // ── QC Manager (plan V6_ENHANCED P3) ───────────────────────────────────
    // One [QcRepositories] holds all five contracts over the same guard and
    // the same transaction boundary. Registering them individually would hand
    // out five independently-built stacks and let a caller audit one entity
    // while writing another.
    ..registerLazySingleton<QcRepositories>(() {
      return QcRepositories.serverConfirmed(
        dbHelper: dbHelper,
        guard: getIt<WriteGuard>(),
        // Read through SessionSource at write time, never captured at
        // registration: a sign-out or a user switch must change who the next
        // audit row names. `QcActor.fromSession` holds the mapping rules.
        actorReader: () => QcActor.fromSession(sessionSource.session),
        // Record the effects for atomic command capture. This metadata does
        // not send anything; the bound business gateway requires explicit
        // submission and a verified server receipt, or saves a manual draft.
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
      return ServerConfirmedQcCustomTablesRepository(
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
    ..registerFactory<NcrExportService>(
      () => NcrExportService(
        organizationName: () => sessionSource.session.organizationName,
        reportSettings: () => getIt<SettingsRepo>().getSettings(),
      ),
    )
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
      directStore == null
          ? const UnconfiguredCommandTransport()
          : FirestoreDirectCommandTransport(
              store: directStore,
              source: sessionSource,
              manifest: loadDirectManifest,
              onDiagnostic: (code, message) =>
                  debugPrint('[central-write] $code: $message'),
            ),
    )
    ..registerSingleton<CentralProjection>(
      CentralProjection(databaseHelper: dbHelper, source: sessionSource),
    )
    ..registerSingleton<CentralSyncReader>(
      directStore == null
          ? const UnconfiguredCentralSyncReader()
          : FirestoreDirectSyncReader(
              store: directStore,
              source: sessionSource,
              manifest: loadDirectManifest,
              onSkippedRecord: (detail) {
                debugPrint('[central-sync] $detail');
                // Persist the report so an organization/quality manager can
                // see the exact document path and repair it at the source.
                // Chained so concurrent skips never lose a report.
                quarantinePersist = quarantinePersist
                    .then((current) async {
                      current.remove(detail);
                      current.add(detail);
                      await metadata.markQuarantine(current);
                      return current;
                    });
              },
            ),
    )
    ..registerSingleton<CentralSyncDriver>(
      CentralSyncDriver(
        databaseHelper: dbHelper,
        source: sessionSource,
        projection: getIt<CentralProjection>(),
        transport: getIt<CentralSyncReader>(),
        outbox: getIt<CommandOutbox>(),
        metadata: metadata,
        onError: (error) => debugPrint('[central-sync] $error'),
        onManualRequest: directStore?.resumeQuota,
      ),
    )
    ..registerSingleton<DirectWriteService>(
      DirectWriteService(
        outbox: getIt<CommandOutbox>(),
        transport: getIt<CommandTransport>(),
        isOnline: () => connectivity.isOnline,
        onManualRequest: directStore?.resumeQuota,
        synchronize: (sequence) => getIt<CentralSyncDriver>().syncNow(
          throughSequence: sequence,
          resumeQuota: false,
        ),
      ),
    )
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
    );

  // Central authoring is enabled by default. Once installed every repository transaction enters the
  // savepoint/write-set gateway; legacy push is disabled above. Keeping this
  // as one assignment prevents a screen from silently choosing a second write
  // path.

  final gateway = CentralAuthoringGateway(
    databaseHelper: dbHelper,
    source: sessionSource,
    outbox: getIt<CommandOutbox>(),
    prepareSecureDefinitions: SecureArchiveCoordinator(
      databaseHelper: dbHelper,
      source: sessionSource,
      queue: queue,
      access: getIt<SecureFieldAccess>(),
      store: directStore,
    ).prepare,
    isOnline: () => connectivity.isOnline,
    chooseOfflineDraft: getIt<OfflineWritePrompt>().choose,
    onPending: getIt<OfflineWritePrompt>().notify,
    complete: (entry) async {
      final direct = getIt<DirectWriteService>();
      final approved = await direct.submitAndWait(entry);
      if (approved) return true;
      final current = await getIt<CommandOutbox>().getByOperationId(
        entry.operationId,
      );
      if (!connectivity.isOnline &&
          current?.attempts == 0 &&
          current?.state == OutboxState.pending) {
        if (await getIt<OfflineWritePrompt>().choose()) {
          await direct.retainUnsentAsDraft(current!);
        } else if (await direct.cancelUnsent(current!)) {
          throw const BusinessActionCancelled();
        }
      }
      return false;
    },
  );
  dbHelper.businessGateway = gateway;
  getIt.registerSingleton<CentralAuthoringGateway>(gateway);
  getIt.registerSingleton<DomainDraftService>(
    DomainDraftService(
      drafts: getIt<DraftsStore>(),
      outbox: getIt<CommandOutbox>(),
      source: sessionSource,
      isOnline: () => connectivity.isOnline,
    ),
  );

  getIt.registerSingleton<AccessMonitor>(
    firestore == null
        ? NoopAccessMonitor()
        : FirestoreAccessMonitor(
            firestore: firestore,
            source: sessionSource,
            onError: (error) => debugPrint('[access] $error'),
            onChanged: () async {
              getIt<CentralSyncDriver>()
                ..stop()
                ..cancelActive();
              await getIt<CentralProjection>().clearForAccessChange();
              await authRepository.resolveProfile();
            },
          ),
  );
  _serviceLocatorReady = true;
  debugPrint(
    '[bootstrap] service locator ready (firebase: ${bootstrap.status.name})',
  );
}

/// Wires organization binding: local settings, backup, device registration,
/// archive reader and explicitly issued requests. Kept here so the
/// repository never imports a feature module.
///
/// The binder runs for `active` members only (the repository guarantees it):
/// a pending/disabled account never opens the company database and never
/// starts the sync cycle (plan §8). Sign-out stops the engine again.
Future<void> registerOrganizationBinder(AuthRepository auth) async {
  if (auth is FirebaseAuthRepository) {
    auth.onOrganizationBound = (organizationId) async {
      await getIt<SettingsRepo>().ensureDefaults();
      // Retired background callbacks may bind metadata only. They must not
      // download or upload business data, register devices or create seeds.
      if (isHeadlessBackground) {
        await getIt<SyncMetadata>().markOrgBound(DateTime.now());
        debugPrint('[bootstrap] organization $organizationId bound (headless)');
        return;
      }
      // Shared seeds belong to the reviewed server migration. Session startup
      // must not create local business rows or submit derived commands.
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
      // Startup only preserves local drafts and reads existing receipts.
      // It never transmits or retries a business command.
      await getIt<DirectWriteService>().recover(
        migrateUnsent: true,
        checkReceipts: false,
      );
      unawaited(getIt<DirectWriteService>().recover());
      getIt<CentralSyncDriver>().start();
      getIt<AccessMonitor>().start();

      // Mobile notifications observe approved rows after a successful refresh.
      if ((Platform.isAndroid || Platform.isIOS) && !isHeadlessBackground) {
        try {
          final controller = getIt<NotificationController>();
          controller.resetForSession();

          getIt<CentralSyncDriver>().onApplied = () =>
              controller.refresh(showOs: true);

          // Bell populates without blocking the bind: `load` is two cheap
          // reads (recent + unread count) fired off while the bind returns,
          // and the heavier watermark scans wait for the pull hooks and the
          // 30 s timer instead of stalling startup on the FFI lock.
          unawaited(controller.load());
          controller.startAutoRefresh(showOs: true);
          // Local OS delivery uses the same organization/device binding for
          // dedupe and own-device suppression, even without an FCM sender.
          try {
            final actor = getIt<SessionSource>().session;
            await getIt<NotificationService>().bindSession(
              PushBinding(
                organizationId: organizationId,
                uid: actor.uid,
                deviceId: actor.deviceId,
                samples: actor.can(Permission.samplesRead),
                lab: actor.can(Permission.labResultsRead),
              ),
            );
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
      getIt<AccessMonitor>().stop();
      if (getIt.isRegistered<CentralSyncDriver>()) {
        getIt<CentralSyncDriver>()
          ..stop()
          // An in-flight download must not keep applying pages into the
          // database after the session (and its org binding) is gone.
          ..cancelActive()
          // A deferred housekeeping hook belongs to the signed-in bind; never
          // fire it against a database the next session has not bound yet.
          ..onReady = null;
      }
      if (Platform.isAndroid || Platform.isIOS) {
        getIt<NotificationController>().resetForSession();
        try {
          await const AndroidNotifPollScheduler().cancel();
        } on Object {
          // Nothing was registered.
        }
        try {
          await getIt<NotificationService>().bindSession(null);
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
