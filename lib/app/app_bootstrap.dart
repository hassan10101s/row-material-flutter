import 'package:flutter/material.dart' show debugPrint;

import '../core/services/seed_service.dart';
import '../di/service_locator.dart';
import '../features/auth/data/auth_repo.dart';
import '../features/backup/data/backup_manager.dart';
import '../features/lab/data/lab_repo.dart';
import '../features/settings/data/settings_repo.dart';

/// Startup sequence mirroring MaterialLabController.__init__
/// (core/controller.py): DB schema, settings defaults, one-time
/// reference/units import, lab default analyses, optional auto backup.
Future<void> appBootstrap() async {
  await initServiceLocator();

  final settings = getIt<SettingsRepo>();
  await settings.ensureDefaults();

  final seed = getIt<SeedService>();
  await seed.ensureInitialImport();

  final lab = getIt<LabRepo>();
  await lab.ensureDefaultAnalyses();

  final backup = getIt<BackupManager>();
  await backup.autoBackup();

  debugPrint('[bootstrap] database, seeds and defaults ready');
}

/// Sign out and clear in-memory session after a database restore.
Future<void> resetAfterRestore() async {
  final auth = getIt<AuthRepo>();
  auth.logout();
}