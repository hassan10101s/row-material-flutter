import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App paths (port of core/paths.py AppPaths).
class AppPaths {
  static const String appDirName = 'MaterialLab';
  static const String dbFileName = 'material_lab.db';

  Future<Directory> appSupportRoot() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, appDirName));
  }

  Future<String> databasePath() async {
    final dir = await appSupportRoot();
    await dir.create(recursive: true);
    return p.join(dir.path, dbFileName);
  }

  Future<Directory> exportsRoot() async {
    final dir = await appSupportRoot();
    await dir.create(recursive: true);
    final exports = Directory(p.join(dir.path, 'exports'));
    await exports.create(recursive: true);
    return exports;
  }

  Future<String> secretFilePath() async {
    final dir = await appSupportRoot();
    await dir.create(recursive: true);
    return p.join(dir.path, '.secret');
  }

  Future<Directory> backupsDir() async {
    final dir = await exportsRoot();
    final backups = Directory(p.join(dir.path, 'backups'));
    await backups.create(recursive: true);
    return backups;
  }

  Future<Directory> autoBackupDir() async {
    final dir = await backupsDir();
    final auto = Directory(p.join(dir.path, 'auto'));
    await auto.create(recursive: true);
    return auto;
  }
}