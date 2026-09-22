import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/security/password_hash.dart';
import 'package:material_lab/core/security/seal_codec.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/auth/data/auth_repo.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;
  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

late Directory _tmp;
late DatabaseHelper _dbHelper;
late LocalSecret _secret;
late AuthRepo _auth;

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    DatabaseHelper.ensureDesktopFactory();
    _tmp = await Directory.systemTemp.createTemp('matlab_seal_test');
    _dbHelper = DatabaseHelper(_FakeAppPaths(_tmp.path));
    final db = await _dbHelper.database;
    _secret = LocalSecret(_tmp.path);
    final hash = sha256.convert(utf8.encode('pw123')).toString();
    await db.insert('users', {
      'username': 'admin',
      'full_name': 'Admin One',
      'password_hash': hash,
      'role': 'Admin',
      'is_active': 1,
      'created_at': nowIso(),
    });
    _auth = AuthRepo(dbHelper: _dbHelper, hasher: PasswordHasher(), secret: _secret);
  });

  Future<void> setUsageExpiry(String value) async {
    final db = await _dbHelper.database;
    await db.insert('settings', {'key': 'usage_expiry_date', 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  test('tampered (invalid) seal blocks login — settings.py:118-124 parity', () async {
    await setUsageExpiry('enc1:!!not-a-valid-seal!!');
    expect(
      () => _auth.login(username: 'admin', password: 'pw123'),
      throwsA(predicate<AuthorizationError>(
          (e) => e.message.contains('انتهت صلاحية'))),
    );
    expect(_auth.currentUser, isNull);
  });

  test('seal that unseals to a non-date string is treated as expired', () async {
    await setUsageExpiry('not-a-date');
    expect(
      () => _auth.login(username: 'admin', password: 'pw123'),
      throwsA(predicate<AuthorizationError>(
          (e) => e.message.contains('انتهت صلاحية رخصة التطبيق'))),
    );
    expect(_auth.currentUser, isNull);
  });

  test('expired sealed date blocks login', () async {
    final key = await _secret.load();
    final expired = sealText(
        DateTime.now().subtract(const Duration(days: 1)).toIso8601String(), key);
    await setUsageExpiry(expired);
    expect(
      () => _auth.login(username: 'admin', password: 'pw123'),
      throwsA(isA<AuthorizationError>()),
    );
  });

  test('future sealed date allows login', () async {
    final key = await _secret.load();
    final future = sealText(
        DateTime.now().add(const Duration(days: 365)).toIso8601String(), key);
    await setUsageExpiry(future);
    final user = await _auth.login(username: 'admin', password: 'pw123');
    expect(user.username, 'admin');
    expect(_auth.currentUser, isNotNull);
  });
}