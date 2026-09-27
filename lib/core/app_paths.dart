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
  Future<bool> isCloudSynced() async {
    final path = await databasePath();
    final lowered = path.toLowerCase();
    return lowered.contains('onedrive') ||
        lowered.contains(r'\dropbox\') ||
        lowered.contains(r'\google drive\') ||
        lowered.contains(r'\box\');
  }

  Future<Directory> exportsRoot() async {
    final dir = await appSupportRoot();
    await dir.create(recursive: true);
    final exports = Directory(p.join(dir.path, 'exports'));
    await exports.create(recursive: true);
    return exports;
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
