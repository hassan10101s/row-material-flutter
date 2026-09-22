import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/security/local_secret.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    DatabaseHelper.ensureDesktopFactory();
    _tmp = await Directory.systemTemp.createTemp('matlab_defaults_test');
    _dbHelper = DatabaseHelper(_FakeAppPaths(_tmp.path));
    final secret = LocalSecret(_tmp.path);
    _repo = SettingsRepo(
        dbHelper: _dbHelper, secret: secret, paths: _FakeAppPaths(_tmp.path));
  });

  test('ensureDefaults writes exactly the 10 reference keys', () async {
    await _repo.ensureDefaults();
    final settings = await _repo.getSettings();
    expect(settings.keys, containsAll(const [
      'pdf_export_dir',
      'export_root_path',
      'whatsapp_launch_url',
      'department_label',
      'usage_expiry_date',
      'report_logo_path',
      'reference_seed_done',
      'security_clock_tamper_flag',
      'security_max_seen_date',
      'security_last_online_check',
    ]));
    expect(settings.length, 10);
  });

  test('reference_seed_done defaults to "0" not empty (settings.py:32-45)', () async {
    final settings = await _repo.getSettings();
    expect(settings['reference_seed_done'], '0');
  });

  test('static defaults match the Python reference exactly', () async {
    final settings = await _repo.getSettings();
    expect(settings['whatsapp_launch_url'], 'https://web.whatsapp.com/');
    expect(settings['department_label'], 'Quality Assurance Department');
    expect(settings['usage_expiry_date'], '');
    expect(settings['report_logo_path'], '');
    expect(settings['security_clock_tamper_flag'], '0');
    expect(settings['security_max_seen_date'], '');
    expect(settings['security_last_online_check'], '');
  });

  test('path defaults resolve under the app support dir', () async {
    final settings = await _repo.getSettings();
    final exportRoot = '${settings['export_root_path']}';
    final pdfDir = '${settings['pdf_export_dir']}';
    expect(exportRoot, startsWith(_tmp.path));
    expect(pdfDir, startsWith(_tmp.path));
    expect(pdfDir, contains('pdfs'));
  });

  test('ensureDefaults is idempotent and never overwrites existing values', () async {
    final db = await _dbHelper.database;
    await db.insert('settings', {'key': 'department_label', 'value': 'My Lab'},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _repo.ensureDefaults();
    final settings = await _repo.getSettings();
    expect(settings['department_label'], 'My Lab');
    expect(settings.length, 10);
  });
}