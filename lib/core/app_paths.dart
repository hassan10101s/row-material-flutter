import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App paths (port of core/paths.py AppPaths) extended with the per-organization
/// layout of plan §D3:
///
///   %APPDATA%\MaterialLab\orgs\<orgId>\material_lab.db
///
/// Physical isolation per organization: a dashboard device physically cannot
/// open another organization's file, and each organization backs up on its own.
class AppPaths {
  static const String appDirName = 'MaterialLab';
  static const String dbFileName = 'material_lab.db';
  static const String orgsDirName = 'orgs';
  static const String legacyOrgId = '_legacy';

  /// [orgId] currently bound to this process (set by `OrgDatabaseProvider`).
  String? _orgId;

  String? get orgId => _orgId;

  set orgId(String? value) => _orgId = (value == null || value.isEmpty) ? null : value;

  Future<Directory> appSupportRoot() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, appDirName));
  }

  /// Root that holds one folder per organization.
  Future<Directory> orgsRoot() async {
    final root = await appSupportRoot();
    final orgs = Directory(p.join(root.path, orgsDirName));
    await orgs.create(recursive: true);
    return orgs;
  }

  /// Folder of a single organization.
  Future<Directory> orgRoot(String? orgId) async {
    final orgs = await orgsRoot();
    final dir = Directory(p.join(orgs.path, _safeSegment(orgId ?? legacyOrgId)));
    await dir.create(recursive: true);
    return dir;
  }

  /// Live database file for the bound organization.
  Future<String> databasePathFor(String? orgId) async {
    final dir = await orgRoot(orgId);
    return p.join(dir.path, dbFileName);
  }

  /// The bound organization's database (falls back to the pre-V2 flat path so
  /// an existing single-user installation keeps working until it is bound).
  Future<String> databasePath() async {
    final orgId = _orgId;
    if (orgId != null) return databasePathFor(orgId);
    return legacyDatabasePath();
  }

  /// Pre-V2 location (`%APPDATA%\MaterialLab\material_lab.db`).
  Future<String> legacyDatabasePath() async {
    final dir = await appSupportRoot();
    await dir.create(recursive: true);
    return p.join(dir.path, dbFileName);
  }

  Future<String> databasePathForLegacy() => legacyDatabasePath();

  /// True when the live database lives inside a cloud-synced folder (OneDrive).
  ///
  /// Desktop best-practice: SQLite + cloud sync = corruption risk. Covers
  /// localized/renamed OneDrive, OneDrive Business/Commercial, Dropbox,
  /// Google Drive, Box and iCloud Drive. Case-insensitive; matches both
  /// `\OneDrive - Contoso\` and bare `onedrive` segments.
  Future<bool> isCloudSynced() async {
    final path = await databasePath();
    final lowered = path.toLowerCase();
    const markers = [
      'onedrive',
      'onedrivecommercial',
      'onedrive - ',
      'sharepoint',
      'dropbox',
      'google drive',
      'googledrive',
      'drivefs',
      'box sync',
      r'\box\',
      'icloud',
      'mega',
      'pcloud',
      'nextcloud',
    ];
    return markers.any(lowered.contains);
  }

  /// Basename helper — always use instead of `split('\\').last`.
  /// Handles UNC, `content://`, trailing separators and mixed slashes.
  static String fileNameOf(String path) {
    final normalized = path.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/') && normalized.length > 1
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    return p.basename(trimmed);
  }

  Future<Directory> exportsRoot() async {
    final dir = await appSupportRoot();
    await dir.create(recursive: true);
    final exports = Directory(p.join(dir.path, 'exports'));
    await exports.create(recursive: true);
    return exports;
  }

  /// Ephemeral share/open staging for phones.
  ///
  /// Mobile best-practice: a PDF/HTML/XLSX that is only opened in a viewer or
  /// handed to the share sheet must NOT live in the permanent `exports/` tree
  /// — the sandbox is unreachable by any file manager, so every saved export
  /// is invisible dead weight eating storage. Stage it in the OS cache dir
  /// instead (auto-purgeable) and let the caller delete it after share/open.
  /// Desktop ignores this and keeps the persistent exports tree.
  Future<Directory> shareCacheDir() async {
    Directory base;
    try {
      base = await getTemporaryDirectory();
    } on Object {
      // Unit tests / early boot without plugins: fall back to system temp.
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, 'material_lab_share'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Best-effort prune of staged share files older than [maxAge].
  /// Never throws — storage hygiene must not break an export.
  Future<void> pruneShareCache(
      {Duration maxAge = const Duration(hours: 24)}) async {
    try {
      final dir = await shareCacheDir();
      await _pruneDir(dir, maxAge);
    } catch (_) {}
  }

  /// Best-effort prune of legacy permanent mobile exports (pre-temp era files
  /// stranded in the unreachable sandbox). Grace period defaults to 7 days so
  /// a just-created file is never yanked from under the share sheet.
  Future<void> pruneLegacyMobileExports(
      {Duration grace = const Duration(days: 7)}) async {
    try {
      final dir = await exportsRoot();
      await _pruneDir(
        dir,
        grace,
        extensions: const {'.pdf', '.html', '.xlsx'},
        recursive: true,
      );
    } catch (_) {}
  }

  static Future<void> _pruneDir(
    Directory dir,
    Duration maxAge, {
    Set<String>? extensions,
    bool recursive = false,
  }) async {
    if (!await dir.exists()) return;
    final cutoff = DateTime.now().subtract(maxAge);
    await for (final entity in dir.list(recursive: recursive)) {
      if (entity is! File) continue;
      if (extensions != null &&
          !extensions.contains(p.extension(entity.path).toLowerCase())) {
        continue;
      }
      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
        }
      } catch (_) {}
    }
  }

  /// Port of paths.default_pdf_dir (export_dir / "pdfs").
  Future<Directory> defaultPdfDir() async {
    final exports = await exportsRoot();
    final pdfs = Directory(p.join(exports.path, 'pdfs'));
    await pdfs.create(recursive: true);
    return pdfs;
  }

  Future<String> secretFilePath() async {
    final dir = await appSupportRoot();
    await dir.create(recursive: true);
    return p.join(dir.path, '.secret');
  }

  /// Backups of the bound organization only.
  Future<Directory> backupsDir() => backupsDirFor(_orgId);

  Future<Directory> backupsDirFor(String? orgId) async {
    final root = await orgRoot(orgId);
    final backups = Directory(p.join(root.path, 'backups'));
    await backups.create(recursive: true);
    return backups;
  }

  Future<Directory> autoBackupDir() => autoBackupDirFor(_orgId);

  Future<Directory> autoBackupDirFor(String? orgId) async {
    final dir = await backupsDirFor(orgId);
    final auto = Directory(p.join(dir.path, 'auto'));
    await auto.create(recursive: true);
    return auto;
  }

  /// Reject anything that could escape the orgs root.
  static String _safeSegment(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
    if (cleaned.isEmpty) return legacyOrgId;
    return cleaned.length > 96 ? cleaned.substring(0, 96) : cleaned;
  }
}
