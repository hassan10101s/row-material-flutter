import 'package:sqflite/sqflite.dart';

import '../../../core/app_paths.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/security/local_secret.dart';
import '../../../core/security/password_hash.dart';
import '../../../core/security/seal_codec.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../auth/domain/user.dart';

/// Settings + user management repository.
class SettingsRepo {
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

  Future<void> updateSettings(Map<String, String> updates) async {
    final db = await dbHelper.database;
    final batch = db.batch();
    for (final entry in updates.entries) {
      batch.insert('settings', {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace);
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
    for (final e in defaults.entries) {
      if (!existing.contains(e.key)) {
        batch.insert('settings', {'key': e.key, 'value': e.value});
      }
    }
    await batch.commit(noResult: true);
  }

  Future<Map<String, dynamic>?> getSetting(String key) async {
    final db = await dbHelper.database;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first;
  }

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

  Future<String?> getReportLogoPath() => getSettingValue('report_logo_path');

  Future<String?> getReportLogoDataUri() => getSettingValue('report_logo_data_uri');

  Future<void> setReportLogo(String path, String dataUri) async {
    await updateSettings({
      'report_logo_path': path,
      'report_logo_data_uri': dataUri,
    });
  }

  Future<void> setReportLogoPath(String path) async {
    await updateSettings({'report_logo_path': path});
  }

  Future<void> clearReportLogo() async {
    await updateSettings({'report_logo_path': '', 'report_logo_data_uri': ''});
  }

  // ── Users ─────────────────────────────────────────────────────

  Future<List<User>> listUsers() async {
    final db = await dbHelper.database;
    final rows = await db.query('users',
        orderBy: 'CASE role WHEN \'Developer\' THEN 0 WHEN \'Admin\' THEN 1 '
            'WHEN \'Lab User\' THEN 2 ELSE 3 END, username COLLATE NOCASE');
    return rows.map(User.fromMap).toList();
  }

  Future<User> createUser({
    required String username,
    required String fullName,
    required String password,
    required String role,
  }) async {
    final db = await dbHelper.database;
    if (username.trim().isEmpty) throw ValidationError(AppErrors.usernameRequired);
    final existing = await db
        .query('users', where: 'username = ?', whereArgs: [username.trim()]);
    if (existing.isNotEmpty) {
      throw ValidationError(AppErrors.usernameExists);
    }
    final hash = await _hashPassword(password, isDeveloper: role == 'Developer');
    final id = await db.insert('users', {
      'username': username.trim(),
      'full_name': fullName.trim(),
      'password_hash': hash,
      'role': role,
      'is_active': 1,
      'created_at': nowIso(),
    });
    return User(id: id, username: username.trim(), fullName: fullName.trim(),
        role: role, createdAt: nowIso());
  }

  Future<void> updateUser({
    required int id,
    String? fullName,
    String? role,
    bool? isActive,
    String? newPassword,
  }) async {
    final db = await dbHelper.database;
    final existing = await db.query('users', where: 'id = ?', whereArgs: [id]);
    if (existing.isEmpty) throw NotFoundError(AppErrors.userNotFound);
    final user = User.fromMap(existing.first);
    if (user.isDeveloper && (role != null && role != 'Developer' || isActive == false)) {
      throw AuthorizationError(AppErrors.cannotModifyDeveloper);
    }
    final updates = <String, dynamic>{};
    if (fullName != null) updates['full_name'] = fullName.trim();
    if (role != null) updates['role'] = role;
    if (isActive != null) updates['is_active'] = isActive ? 1 : 0;
    if (newPassword != null && newPassword.isNotEmpty) {
      updates['password_hash'] = await _hashPassword(newPassword,
          isDeveloper: (role ?? user.role) == 'Developer');
    }
    if (updates.isEmpty) return;
    await db.update('users', updates, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteUser(int id) async {
    final db = await dbHelper.database;
    final rows = await db.query('users', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final user = User.fromMap(rows.first);
    if (user.isDeveloper) {
      throw AuthorizationError(AppErrors.cannotDeleteDeveloper);
    }
    // Reject deletion while the user owns data (parity with auth.py:139-155)
    // so referential integrity / audit identity is never lost.
    final insp = await db
        .rawQuery('SELECT COUNT(*) AS c FROM inspections WHERE created_by = ?', [id]);
    if ((Sqflite.firstIntValue(insp) ?? 0) > 0) {
      throw ValidationError(AppErrors.userIdHasInspectionRecords);
    }
    final hist = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM inspection_status_history WHERE changed_by = ?',
        [id]);
    if ((Sqflite.firstIntValue(hist) ?? 0) > 0) {
      throw ValidationError(AppErrors.userIdHasStatusHistoryRecords);
    }
    await db.delete('users', where: 'id = ?', whereArgs: [id]);
  }

  Future<String> _hashPassword(String password, {required bool isDeveloper}) async {
    final key = await secret.load();
    final hasher = PasswordHasher(pepper: String.fromCharCodes(key));
    return hasher.buildHash(password, isDeveloper: isDeveloper);
  }
}