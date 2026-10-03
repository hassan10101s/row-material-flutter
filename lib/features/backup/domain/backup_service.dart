import 'dart:io';

/// The backup and legacy-import contract.
///
/// Implementation: `data/backup_manager.dart` (`BackupManager`).
///
/// ## Why a contract
///
/// `BackupManager` holds a `DatabaseHelper` and reads source SQLite files
/// directly. Three presentation files named it, which is why
/// `settings_screen.dart`, `migration_panel.dart` and
/// `database_settings_cubit.dart` were the last three ratchet entries in the
/// architecture test.
///
/// ## Why these result maps are `Map<String, dynamic>`
///
/// Every importer returns a report the migration panel renders key by key. That
/// report shape predates this contract and is read by the panel today; typing it
/// would be a behaviour change dressed as a refactor. The map keys are pinned by
/// `test/backup/backup_manager_test.dart` and by the panel's own tests.
abstract interface class BackupService {
  /// Message shown instead of a user import.
  ///
  /// Importing local password hashes into the roster would resurrect the exact
  /// vulnerability V2 removes, and Firebase UIDs cannot be invented locally.
  static const String usersImportDisabledMessage =
      'استيراد المستخدمين معطّل في النسخة الثانية: الهوية أصبحت عبر Google/Firebase. '
      'أضف الأعضاء من شاشة "الأعضاء" (Members) داخل التطبيق، وسيتم ربط كل بريد '
      'بحسابه تلقائيًا عند أول تسجيل دخول.';

  // ── Backup / restore ───────────────────────────────────────────

  /// Copy the live database to the backups directory. Returns
  /// `{path, size_bytes?, ...}`; [explicitPath] overrides the chosen name.
  Future<Map<String, dynamic>> exportDatabaseBackup({String? explicitPath});

  /// Scheduled backup, run by the OS on desktop and by `workmanager` on
  /// Android. Rotates to the implementation's retention.
  Future<void> autoBackup();

  /// Validate a backup file before it is allowed to replace the live database.
  /// Throws when the file is not a usable Material Lab database.
  Future<void> validateBackupDatabase(String backupPath);

  /// Replace the live database with [backupPath].
  Future<Map<String, dynamic>> restoreDatabaseBackup(String backupPath);

  // ── Legacy import ──────────────────────────────────────────────

  /// Probe an external database without writing anything.
  Future<String> preflightMigrateBackup(String backupPath, Directory tempRoot);

  /// Validate a source database as a *materials* import (materials + parameters
  /// + units), as opposed to a full backup.
  Future<void> validateMaterialsDatabase(String sourcePath);

  /// Always returns the disabled report. Present so callers can render the
  /// explanation without special-casing the import.
  Future<Map<String, dynamic>> pullUsersFromSourceDb({
    required String sourceDbPath,
    String developerName = '',
  });

  /// Copy inspections and their status history from a source database,
  /// creating missing reference materials. Returns the number copied.
  Future<int> importInspectionsFromSource({required String sourceDbPath});

  /// Merge materials and parameters from a source database (upsert on name).
  /// [importUnits] is invoked only when the source has no parameter rows.
  Future<Map<String, dynamic>> importMaterialsDatabase({
    required String sourceDbPath,
    Future<int> Function()? importUnits,
  });
}