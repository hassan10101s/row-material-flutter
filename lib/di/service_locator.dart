import 'package:flutter/material.dart' show debugPrint;
import 'package:get_it/get_it.dart';

import '../app/auth_gate.dart';
import '../core/app_paths.dart';
import '../core/database/database_helper.dart';
import '../core/security/local_secret.dart';
import '../core/security/password_hash.dart';
import '../core/services/seed_service.dart';
import '../features/auth/data/auth_repo.dart';
import '../features/backup/data/backup_manager.dart';
import '../features/dashboard/data/dashboard_repo.dart';
import '../features/inspections/data/inspection_repo.dart';
import '../features/lab/data/lab_repo.dart';
import '../features/reference/data/reference_repo.dart';
import '../features/reports/data/report_service.dart';
import '../features/settings/data/settings_repo.dart';

/// Global service locator (get_it). Registration happens once in
/// [initServiceLocator] during app bootstrap.
final GetIt getIt = GetIt.instance;

/// Manual constructors because the repos need the runtime DB path resolved
/// from AppPaths (path_provider is only callable after runApp).
Future<void> initServiceLocator() async {
  getIt
    ..registerLazySingleton<AppPaths>(AppPaths.new)
    ..registerLazySingletonAsync<LocalSecret>(() async {
      final paths = getIt<AppPaths>();
      final dir = await paths.appSupportRoot();
      return LocalSecret(dir.path);
    })
    ..registerLazySingletonAsync<DatabaseHelper>(() async {
      final paths = getIt<AppPaths>();
      DatabaseHelper.ensureDesktopFactory();
      return DatabaseHelper(paths);
    });

  final secret = await getIt.getAsync<LocalSecret>();
  final dbHelper = await getIt.getAsync<DatabaseHelper>();
  final hasher = PasswordHasher(pepper: String.fromCharCodes(await secret.load()));

  getIt
    ..registerLazySingleton(() => hasher)
    ..registerLazySingleton<SettingsRepo>(() => SettingsRepo(dbHelper: dbHelper, secret: secret))
    ..registerLazySingleton<ReferenceRepo>(() => ReferenceRepo(dbHelper: dbHelper))
    ..registerLazySingleton<InspectionRepo>(
        () => InspectionRepo(dbHelper: dbHelper, referenceRepo: getIt<ReferenceRepo>()))
    ..registerLazySingleton<LabRepo>(() => LabRepo(dbHelper: dbHelper))
    ..registerLazySingleton<DashboardRepo>(() => DashboardRepo(dbHelper: dbHelper))
    ..registerLazySingleton<SeedService>(() => SeedService(dbHelper: dbHelper))
    ..registerLazySingleton<AuthRepo>(
        () => AuthRepo(dbHelper: dbHelper, hasher: hasher, secret: secret))
    ..registerLazySingleton<AuthGate>(() => AuthGate(getIt<AuthRepo>()))
    ..registerLazySingleton<BackupManager>(() => BackupManager(dbHelper: dbHelper))
    ..registerLazySingleton<ReportService>(() => ReportService(
          settingsRepo: getIt<SettingsRepo>(),
          inspectionRepo: getIt<InspectionRepo>(),
          labRepo: getIt<LabRepo>(),
          dbHelper: dbHelper,
          secret: secret,
        ));

  debugPrint('[bootstrap] service locator ready');
}