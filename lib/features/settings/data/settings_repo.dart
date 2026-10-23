import 'package:sqflite/sqflite.dart';

import '../../../core/app_paths.dart';
import '../../../core/constants/report_form_keys.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/security/local_secret.dart';
import '../../../core/security/seal_codec.dart';
import '../domain/settings_repository.dart';

/// Settings repository (organization scoped).
///
/// User management moved to `features/members` in V2: members are owned by
/// Firestore and mirrored into the local `users` table, they are never created
/// or edited from the settings screen.
class SettingsRepo implements SettingsRepository {
  final DatabaseHelper dbHelper;
  final LocalSecret secret;
  final AppPaths? paths;

  SettingsRepo({required this.dbHelper, required this.secret, this.paths});

  Future<Map<String, dynamic>> getSettings() async {
    final db = await dbHelper.database;
    final rows = await db.query('settings');
    final map = <String, dynamic>{};
    for (final r in rows) {
      map['${r['key']}'] = r['value'];
    }
    return map;
  }

  @override
  Future<void> updateSettings(Map<String, String> updates) async {
    final db = await dbHelper.database;
    final batch = db.batch();
    for (final entry in updates.entries) {
      batch.insert('settings', {
        'key': entry.key,
        'value': entry.value,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Ensure the standard settings rows exist (port of
  /// SettingsService.ensure_defaults from core/services/settings.py:32-45).
  Future<void> ensureDefaults() async {
    final db = await dbHelper.database;
    String? pdfExportDir;
    String? exportRoot;
    if (paths != null) {
      try {
        exportRoot = (await paths!.exportsRoot()).path;
        pdfExportDir = (await paths!.defaultPdfDir()).path;
      } catch (_) {
        // Path defaults are best-effort; everything else still applies.
      }
    }
    final defaults = <String, String>{
      'pdf_export_dir': ?pdfExportDir,
      'export_root_path': ?exportRoot,
      'whatsapp_launch_url': 'https://web.whatsapp.com/',
      'department_label': 'Quality Assurance Department',
      // Per-form QA form numbers (`نموذج رقم / Form No:` on the printed
      // document), each editable from the gear button beside its own report
      // or label. `qa_form_no` is the legacy global value, kept as a fallback
      // for any form whose own key is still empty.
      ReportFormKeys.global: '',
      ReportFormKeys.inspectionReport: '',
      ReportFormKeys.inspectionLabel: '',
      // Equipment label keeps its historical key.
      ReportFormKeys.equipmentLabel: '',
      ReportFormKeys.dailyReport: '',
      ReportFormKeys.monthlyReport: '',
      ReportFormKeys.yearlyReport: '',
      ReportFormKeys.followUpReport: '',
      ReportFormKeys.labDailyReport: '',
      ReportFormKeys.labMonthlyReport: '',
      ReportFormKeys.labYearlyReport: '',
      ReportFormKeys.ncrReport: '',
      'usage_expiry_date': '',
      'report_logo_path': '',
      'reference_seed_done': '0',
      'security_clock_tamper_flag': '0',
      'security_max_seen_date': '',
      'security_last_online_check': '',
    };
    final existing = <String>{};
    for (final r in await db.query('settings')) {
      existing.add('${r['key']}');
    }
    final batch = db.batch();
    var pending = 0;
    for (final e in defaults.entries) {
      if (!existing.contains(e.key)) {
        batch.insert('settings', {'key': e.key, 'value': e.value});
        pending++;
      }
    }
    // An empty batch still opens a transaction (BEGIN EXCLUSIVE) and waits on
    // the file lock: on a device where a workmanager isolate holds the DB,
    // that wait is the full busy_timeout (~5s) for zero work. Skip it.
    if (pending == 0) return;
    await batch.commit(noResult: true);
  }

  Future<Map<String, dynamic>?> getSetting(String key) async {
    final db = await dbHelper.database;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<String?> getSettingValue(String key) async {
    final row = await getSetting(key);
    return row == null ? null : '${row['value']}';
  }

  // ── Usage expiry (sealed) ─────────────────────────────────────

  Future<String?> readUsageExpiry() async {
    final value = await getSettingValue('usage_expiry_date');
    if (value == null || value.isEmpty) return null;
    final key = await secret.load();
    final (plain, ok) = unsealText(value, key);
    return ok ? plain : null;
  }

  Future<void> setUsageExpiry(String? dateIso) async {
    if (dateIso == null || dateIso.trim().isEmpty) {
      await updateSettings({'usage_expiry_date': ''});
      return;
    }
    final key = await secret.load();
    final sealed = sealText(dateIso.trim(), key);
    await updateSettings({'usage_expiry_date': sealed});
  }

  // ── Logo ──────────────────────────────────────────────────────

  @override
  Future<String?> getReportLogoPath() => getSettingValue('report_logo_path');

  @override
  Future<String?> getReportLogoDataUri() =>
      getSettingValue('report_logo_data_uri');

  @override
  Future<void> setReportLogo(String path, String dataUri) async {
    await updateSettings({
      'report_logo_path': path,
      'report_logo_data_uri': dataUri,
    });
  }

  Future<void> setReportLogoPath(String path) async {
    await updateSettings({'report_logo_path': path});
  }

  @override
  Future<void> clearReportLogo() async {
    await updateSettings({'report_logo_path': '', 'report_logo_data_uri': ''});
  }
}
