import 'package:sqflite/sqflite.dart';

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

  SettingsRepo({required this.dbHelper, required this.secret});

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

  Future<Map<String, dynamic>?> getSetting(String key) async {
    final db = await dbHelper.database;
    final rows = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first;
  }

  Future<String?> getSettingValue(String key) async {
    final row = await getSetting(key);
    return row == null ? null : '${row['value']}';
  }

  // ── Usage expiry (sealed) ────────────────────────────────

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

  // ── Logo ─────────────────────────────────────────────────

  Future<String?> getReportLogoPath() => getSettingValue('report_logo_path');

  Future<void> setReportLogoPath(String path) async {
    await updateSettings({'report_logo_path': path});
  }

  // ── Users ────────────────────────────────────────────────

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
    if (username.trim().isEmpty) throw const ValidationError('Username is required.');
    final existing = await db
        .query('users', where: 'username = ?', whereArgs: [username.trim()]);
    if (existing.isNotEmpty) {
      throw const ValidationError('Username already exists. | اسم المستخدم موجود مسبقاً.');
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
    if (existing.isEmpty) throw const NotFoundError('User not found.');
    final user = User.fromMap(existing.first);
    if (user.isDeveloper && (role != null && role != 'Developer' || isActive == false)) {
      throw const AuthorizationError('Cannot modify the Developer account. | لا يمكن تعديل حساب المطور.');
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
      throw const AuthorizationError('Cannot delete the Developer account. | لا يمكن حذف حساب المطور.');
    }
    await db.delete('users', where: 'id = ?', whereArgs: [id]);
  }

  Future<String> _hashPassword(String password, {required bool isDeveloper}) async {
    final key = await secret.load();
    final hasher = PasswordHasher(pepper: String.fromCharCodes(key));
    return hasher.buildHash(password, isDeveloper: isDeveloper);
  }
}