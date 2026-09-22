import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/security/local_secret.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/settings/data/settings_repo.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;
  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

late Directory _tmp;
late DatabaseHelper _dbHelper;
late SettingsRepo _repo;

Future<int> _insertUser(String username, String role) async {
  final db = await _dbHelper.database;
  return db.insert('users', {
    'username': username,
    'full_name': 'User $username',
    'password_hash': 'x',
    'role': role,
    'is_active': 1,
    'created_at': nowIso(),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    DatabaseHelper.ensureDesktopFactory();
    _tmp = await Directory.systemTemp.createTemp('matlab_delete_user_test');
    _dbHelper = DatabaseHelper(_FakeAppPaths(_tmp.path));
    final secret = LocalSecret(_tmp.path);
    _repo = SettingsRepo(
        dbHelper: _dbHelper, secret: secret, paths: _FakeAppPaths(_tmp.path));

    final db = await _dbHelper.database;
    await db.insert('reference_materials', {
      'material_name': 'Sugar',
      'material_code': 'M-SUGAR-01',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': nowIso(),
    });

    final owner = await _insertUser('owner', 'Admin');
    final recorder = await _insertUser('recorder', 'Admin');
    await _insertUser('free', 'Viewer');
    await _insertUser('dev', 'Developer');

    await db.insert('inspections', {
      'entry_code': 'QC-2026-001',
      'material_id': 1,
      'material_name': 'Sugar',
      'material_code': 'M-SUGAR-01',
      'inspection_date': '2026-09-01',
      'specialist_name': 'Sara',
      'physical_results_json': '{}',
      'chemical_results_json': '{}',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'decision_status': 'APPROVED',
      'snapshot_json': '{}',
      'sample_names_json': '["S1"]',
      'decision_version': 1,
      'created_by': owner,
      'created_by_name': 'Owner',
      'created_at': nowIso(),
      'updated_at': nowIso(),
    });
    // Recorder only owns history rows, never inspections.
    await db.insert('inspection_status_history', {
      'inspection_id': 1,
      'version': 1,
      'old_status': 'APPROVED',
      'new_status': 'CONDITIONAL_APPROVAL',
      'change_reason': 'retest',
      'changed_by': recorder,
      'changed_by_name': 'Recorder',
      'changed_at': nowIso(),
    });
  });

  test('deleting a user with inspections is rejected (auth.py:139-155)', () async {
    final db = await _dbHelper.database;
    final ownerId = Sqflite.firstIntValue(
            await db.rawQuery('SELECT id FROM users WHERE username = ?', ['owner']))!;
    expect(
      () => _repo.deleteUser(ownerId),
      throwsA(predicate<ValidationError>(
          (e) => e.message.contains('لديه سجلات فحوصات قائمة'))),
    );
  });

  test('deleting a user with status-history rows is rejected', () async {
    final db = await _dbHelper.database;
    final recorderId = Sqflite.firstIntValue(await db
        .rawQuery('SELECT id FROM users WHERE username = ?', ['recorder']))!;
    expect(
      () => _repo.deleteUser(recorderId),
      throwsA(predicate<ValidationError>(
          (e) => e.message.contains('سجل القرارات'))),
    );
  });

  test('deleting a user with no records succeeds', () async {
    final db = await _dbHelper.database;
    final freeId = Sqflite.firstIntValue(
        await db.rawQuery('SELECT id FROM users WHERE username = ?', ['free']))!;
    await _repo.deleteUser(freeId);
    final rows = await db.query('users', where: 'id = ?', whereArgs: [freeId]);
    expect(rows, isEmpty);
  });

  test('the Developer account can never be deleted', () async {
    final db = await _dbHelper.database;
    final devId = Sqflite.firstIntValue(
        await db.rawQuery('SELECT id FROM users WHERE username = ?', ['dev']))!;
    expect(
      () => _repo.deleteUser(devId),
      throwsA(isA<AuthorizationError>()),
    );
  });
}