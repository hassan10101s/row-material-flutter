import 'package:sqflite/sqflite.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/security/local_secret.dart';
import '../../../core/security/password_hash.dart';
import '../../../core/security/seal_codec.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../domain/user.dart';

/// Authentication + session repository (port of core/services/auth.py
/// and controller bootstrap/login).
class AuthRepo {
  final DatabaseHelper dbHelper;
  final PasswordHasher hasher;
  final LocalSecret secret;

  AuthRepo({
    required this.dbHelper,
    required this.hasher,
    required this.secret,
  });

  User? _currentUser;
  User? get currentUser => _currentUser;

  /// Is the first-run setup still required (no users yet)?
  Future<bool> needsSetup() async {
    final db = await dbHelper.database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM users');
    final count = Sqflite.firstIntValue(rows) ?? 0;
    return count == 0;
  }

  /// Is an Admin/Developer missing (admin setup prompt)?
  Future<bool> needsAdminSetup() async {
    final db = await dbHelper.database;
    final rows = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM users WHERE role IN ('Admin','Developer')");
    final count = Sqflite.firstIntValue(rows) ?? 0;
    return count == 0;
  }

  Future<bool> isSetupBlocked() async {
    final db = await dbHelper.database;
    final rows = await db.rawQuery(
        "SELECT value FROM settings WHERE key = 'setup_blocked'");
    return rows.isNotEmpty;
  }

  Future<List<User>> listUsers() async {
    final db = await dbHelper.database;
    final rows = await db.query('users', orderBy: 'role DESC, username COLLATE NOCASE');
    return rows.map(User.fromMap).toList();
  }

  /// Create the first administrator (setup wizard).
  Future<User> createAdmin({
    required String username,
    required String fullName,
    required String password,
    required String role,
    String? usageExpiryDate,
  }) async {
    final db = await dbHelper.database;
    if (!await needsSetup()) {
      throw const AuthorizationError('Setup has already been completed.');
    }
    final normalizedRole = role == 'Developer' ? 'Developer' : 'Admin';
    final hash = await hasher.buildHash(password);
    final createdAt = nowIso();
    final existing = await db
        .query('users', where: 'username = ?', whereArgs: [username]);
    if (existing.isNotEmpty) {
      throw ValidationError('Username already exists. | اسم المستخدم موجود مسبقاً.');
    }
    final id = await db.insert('users', {
      'username': username.trim(),
      'full_name': fullName.trim(),
      'password_hash': hash,
      'role': normalizedRole,
      'is_active': 1,
      'created_at': createdAt,
    });
    // Persist the sealed usage-expiry license date (mirrors auth.py
    // bootstrap_create_admin saving usage_expiry_date in settings).
    if (usageExpiryDate != null && usageExpiryDate.trim().isNotEmpty) {
      final key = await secret.load();
      final sealed = sealText(usageExpiryDate.trim(), key);
      await db.insert('settings', {'key': 'usage_expiry_date', 'value': sealed},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    return User(
      id: id,
      username: username.trim(),
      fullName: fullName.trim(),
      role: normalizedRole,
      createdAt: createdAt,
    );
  }

  Future<User> login({
    required String username,
    required String password,
  }) async {
    final db = await dbHelper.database;
    final rows = await db.query('users', where: 'username = ?', whereArgs: [username]);
    if (rows.isEmpty) {
      throw const AuthorizationError('Invalid username or password. | اسم المستخدم أو كلمة المرور غير صحيحة.');
    }
    final user = User.fromMap(rows.first);
    if (!user.isActive) {
      throw const AuthorizationError('Account is disabled. | الحساب معطل.');
    }
    final ok = await hasher.verify(password, user.passwordHash ?? '');
    if (!ok) {
      throw const AuthorizationError('Invalid username or password. | اسم المستخدم أو كلمة المرور غير صحيحة.');
    }
    await _checkUsageExpiry(user);
    // Upgrade legacy hash if needed.
    if (hasher.needsUpgrade(user.passwordHash ?? '')) {
      final newHash = await hasher.buildHash(password);
      await db.update('users', {'password_hash': newHash},
          where: 'id = ?', whereArgs: [user.id]);
    }
    _currentUser = user;
    return user;
  }

  Future<void> _checkUsageExpiry(User user) async {
    if (user.isDeveloper) return;
    final db = await dbHelper.database;
    final rows = await db
        .query('settings', where: 'key = ?', whereArgs: ['usage_expiry_date']);
    if (rows.isEmpty) return;
    final sealed = '${rows.first['value'] ?? ''}';
    if (sealed.isEmpty) return;
    final secretKey = await secret.load();
    final (plain, ok) = unsealText(sealed, secretKey);
    // A broken/wrong seal means the database was tampered with — treat it as
    // expired (parity with settings.py:118-124 returning yesterday's date).
    if (!ok) {
      _currentUser = null;
      throw const AuthorizationError(
          'انتهت صلاحية استخدام النظام. يرجى الاتصال بالمطور.');
    }
    final text = plain.trim();
    if (text.isEmpty) return;
    final expiry = DateTime.tryParse(text);
    // Invalid (non-date) text, like a tampered seal, is treated as expired.
    if (expiry == null || DateTime.now().isAfter(expiry)) {
      _currentUser = null;
      throw const AuthorizationError(
          'Application license has expired. | انتهت صلاحية رخصة التطبيق.');
    }
  }

  void logout() {
    _currentUser = null;
  }
}