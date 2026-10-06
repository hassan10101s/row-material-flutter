import 'dart:io';

import '../../../core/app_paths.dart';
import '../data/settings_repo.dart';

/// The report export root folder (`export_root_path`), exposed as a domain
/// service so presentation code can depend on `domain/` instead of `data/`.
///
/// Mirrors the Vue `pick_export_root_path` flow: the setting drives where the
/// report PDFs are saved (`ReportService.resolveExportDir`) and what the
/// "فتح مجلد PDF" action opens. An unset value means the app default exports
/// folder is used.
class ExportRootService {
  ExportRootService({required this.repo, this.paths});

  final SettingsRepo repo;
  final AppPaths? paths;

  /// The configured export folder, or null when not set.
  Future<String?> configuredPath() async {
    final value =
        (await repo.getSettingValue('export_root_path'))?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  /// Persist the user-chosen export folder (`updateSettings` replaces the
  /// previous value; an empty string clears it back to the default).
  Future<void> setPath(String path) =>
      repo.updateSettings({'export_root_path': path.trim()});

  /// The effective export root: the configured folder when set, otherwise the
  /// app default `exports/` folder. The folder is created if missing.
  Future<Directory> effectiveRoot() async {
    final configured = await configuredPath();
    if (configured != null) {
      final dir = Directory(configured);
      await dir.create(recursive: true);
      return dir;
    }
    if (paths == null) {
      throw StateError(
        'No AppPaths available to resolve the default export root',
      );
    }
    return paths!.exportsRoot();
  }
}
