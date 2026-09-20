import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/backup/data/backup_manager.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

late Directory _tmp;
late DatabaseHelper _dbHelper;
late BackupManager _backup;

const String _usersTable = '''
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    full_name TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role TEXT NOT NULL,
    is_active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
  )
''';

const String _materialsTable = '''
  CREATE TABLE IF NOT EXISTS reference_materials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    material_name TEXT NOT NULL UNIQUE,
    material_code TEXT NOT NULL,
    physical_reference_json TEXT NOT NULL,
    chemical_reference_json TEXT NOT NULL,
    source_row INTEGER,
    imported_at TEXT NOT NULL
  )
''';

const String _inspectionsTable = '''
  CREATE TABLE IF NOT EXISTS inspections (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_code TEXT NOT NULL UNIQUE,
    material_id INTEGER NOT NULL,
    material_name TEXT NOT NULL,
    material_code TEXT NOT NULL,
    inspection_date TEXT NOT NULL,
    expiry_date TEXT,
    supplier TEXT,
    truck_number TEXT,
    quantity TEXT,
    sample_taken_by TEXT,
    specialist_name TEXT NOT NULL,
    physical_results_json TEXT NOT NULL,
    chemical_results_json TEXT NOT NULL,
    physical_reference_json TEXT NOT NULL,
    chemical_reference_json TEXT NOT NULL,
    decision_status TEXT NOT NULL,
    decision_reason TEXT,
    follow_up_note TEXT,
    rejected_quantity TEXT,
    report_html TEXT,
    snapshot_json TEXT NOT NULL,
    sample_names_json TEXT NOT NULL,
    decision_version INTEGER NOT NULL DEFAULT 1,
    created_by INTEGER NOT NULL,
    created_by_name TEXT NOT NULL,
    last_pdf_path TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
''';

const String _historyTable = '''
  CREATE TABLE IF NOT EXISTS inspection_status_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    inspection_id INTEGER NOT NULL,
    version INTEGER NOT NULL,
    old_status TEXT,
    new_status TEXT NOT NULL,
    change_reason TEXT,
    follow_up_note TEXT,
    rejected_quantity TEXT,
    changed_by INTEGER NOT NULL,
    changed_by_name TEXT NOT NULL,
    changed_at TEXT NOT NULL
  )
''';

const String _parametersTable = '''
  CREATE TABLE IF NOT EXISTS parameters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    parameter_name TEXT NOT NULL UNIQUE,
    unit TEXT,
    parameter_type TEXT DEFAULT 'physical',
    imported_at TEXT NOT NULL
  )
''';

const String _settingsTable =
    'CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)';

Future<String> createSourceDb(Set<String> tables) async {
  final dir = await Directory.systemTemp.createTemp('matlab_src');
  final path = '${dir.path}${Platform.pathSeparator}source.db';
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        if (tables.contains('settings')) await db.execute(_settingsTable);
        if (tables.contains('users')) await db.execute(_usersTable);
        if (tables.contains('reference_materials')) {
          await db.execute(_materialsTable);
        }
        if (tables.contains('inspections')) await db.execute(_inspectionsTable);
        if (tables.contains('history')) await db.execute(_historyTable);
        if (tables.contains('parameters')) await db.execute(_parametersTable);
      },
    ),
  );
  await db.close();
  return path;
}

Future<void> _insertLiveInspection() async {
  final db = await _dbHelper.database;
  await db.insert('inspections', {
    'entry_code': 'QC-MIG-001',
    'material_id': 1,
    'material_name': 'Sugar',
    'material_code': 'M-SUGAR-01',
    'inspection_date': '2026-09-01',
    'specialist_name': 'Ahmed Ali',
    'physical_results_json': '{}',
    'chemical_results_json': '{}',
    'physical_reference_json': '{}',
    'chemical_reference_json': '{}',
    'decision_status': 'APPROVED',
    'snapshot_json': '{}',
    'sample_names_json': '[]',
    'created_by': 1,
    'created_by_name': 'Ahmed Ali',
    'created_at': nowIso(),
    'updated_at': nowIso(),
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    DatabaseHelper.ensureDesktopFactory();
    _tmp = await Directory.systemTemp.createTemp('matlab_backup');
    _dbHelper = DatabaseHelper(_FakeAppPaths(_tmp.path));
    final db = await _dbHelper.database;
    await db.insert('settings', {
      'key': 'department_label',
      'value': 'Quality Assurance Department'
    });
    await db.insert('reference_materials', {
      'material_name': 'Sugar',
      'material_code': 'M-SUGAR-01',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': nowIso(),
    });
    await db.insert('users', {
      'username': 'inspector',
      'full_name': 'Ahmed Ali',
      'password_hash': 'x',
      'role': 'inspector',
      'created_at': nowIso(),
    });
    await _insertLiveInspection();
    _backup = BackupManager(dbHelper: _dbHelper);
  });

  test('exportDatabaseBackup creates a valid .db backup', () async {
    final result = await _backup.exportDatabaseBackup();
    expect(result['path'], endsWith('.db'));
    expect(File('${result['path']}').existsSync(), isTrue);
    await _backup.validateBackupDatabase('${result['path']}');
  });

  test('exportDatabaseBackup rejects the live database path', () async {
    expectLater(
      _backup.exportDatabaseBackup(explicitPath: await _dbHelper.databasePath),
      throwsA(isA<ValidationError>()),
    );
  });

  test('validateBackupDatabase rejects garbage files', () async {
    final bad =
        File('${_tmp.path}${Platform.pathSeparator}garbage.db');
    await bad.writeAsBytes([1, 2, 3, 4, 5]);
    expect(
      () => _backup.validateBackupDatabase(bad.path),
      throwsA(isA<ValidationError>()),
    );
    await bad.delete();
  });

  test('preflightMigrateBackup upgrades legacy backups in place', () async {
    final backup = await _backup.exportDatabaseBackup();
    final tempRoot = await Directory.systemTemp.createTemp('matlab_preflight');
    final result = await _backup.preflightMigrateBackup('${backup['path']}', tempRoot);
    expect(result, endsWith('.db'));
    expect(File(result).existsSync(), isTrue);
    final restoredPart = await _backup.preflightMigrateBackup(result, tempRoot);
    expect(File(restoredPart).existsSync(), isTrue);
  });

  test('restoreDatabaseBackup round-trips the data', () async {
    final backup = await _backup.exportDatabaseBackup();
    final liveBefore = await _dbHelper.database;
    await liveBefore.delete(
        'inspections', where: "entry_code = 'QC-MIG-001'");
    await _backup.restoreDatabaseBackup('${backup['path']}');
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
        "SELECT COUNT(*) AS c FROM inspections WHERE entry_code = 'QC-MIG-001'");
    expect('${rows.first['c']}', '1');
    final settings = await db.rawQuery(
        "SELECT value FROM settings WHERE key = 'department_label'");
    expect(settings, hasLength(1));
  });

  test('restoreDatabaseBackup rejects invalid files before touching the live db',
      () async {
    final bad =
        File('${_tmp.path}${Platform.pathSeparator}bad_restore.db');
    await bad.writeAsBytes([9, 9, 9]);
    expectLater(
      _backup.restoreDatabaseBackup(bad.path),
      throwsA(isA<ValidationError>()),
    );
    final db = await _dbHelper.database;
    final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM inspections');
    expect('${rows.first['c']}', '1');
  });

  test('autoBackup creates files and enforces retention of 5', () async {
    final autoDir = await _dbHelper.paths.autoBackupDir();
    for (var i = 0; i < 4; i++) {
      await File('${autoDir.path}${Platform.pathSeparator}material_lab_backup_$i.db')
          .writeAsString('stale');
    }
    await _backup.autoBackup();
    final files = autoDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.db'))
        .toList();
    expect(files.length, lessThanOrEqualTo(5));
    final real = files.where((f) => f.lengthSync() > 10).first;
    await _backup.validateBackupDatabase(real.path);
  });

  test('pullUsersFromSourceDb copies users and counts legacy hashes', () async {
    final src = await createSourceDb({'users'});
    final db = await databaseFactoryFfi
        .openDatabase(src, options: OpenDatabaseOptions(version: 1));
    await db.insert('users', {
      'username': 'legacy_user',
      'full_name': 'Legacy User',
      'password_hash': 'pbkdf2_sha256' r'$abc',
      'role': 'Lab User',
      'created_at': nowIso(),
    });
    await db.insert('users', {
      'username': 'v2_user',
      'full_name': 'V2 User',
      'password_hash': 'pbkdf2_sha256_v2' r'$xyz',
      'role': 'Admin',
      'created_at': nowIso(),
    });
    await db.close();

    final result = await _backup.pullUsersFromSourceDb(sourceDbPath: src);
    expect(result['users_copied'], 2);
    expect(result['legacy_count'], 1);
    expect(result['v2_count'], 1);

    final live = await _dbHelper.database;
    final rows = await live.rawQuery(
        "SELECT username, role FROM users WHERE username IN ('legacy_user', 'v2_user')");
    expect(rows.length, 2);
    expect(
        rows.any((r) => r['username'] == 'v2_user' && r['role'] == 'Admin'),
        isTrue);
  });

  test('pullUsersFromSourceDb skips the developer account', () async {
    final src = await createSourceDb({'users'});
    final db = await databaseFactoryFfi
        .openDatabase(src, options: OpenDatabaseOptions(version: 1));
    await db.insert('users', {
      'username': 'developer',
      'full_name': 'Dev Acc',
      'password_hash': 'pbkdf2_sha256' r'$abc',
      'role': 'Developer',
      'created_at': nowIso(),
    });
    await db.close();

    final result = await _backup.pullUsersFromSourceDb(
        sourceDbPath: src, developerName: 'developer');
    expect(result['users_copied'], 0);
    expect(result['users_skipped'], 1);
  });

  test('importInspectionsFromSource copies inspections, materials and history',
      () async {
    final src =
        await createSourceDb({'inspections', 'history', 'reference_materials'});
    final db = await databaseFactoryFfi
        .openDatabase(src, options: OpenDatabaseOptions(version: 1));
    await db.insert('reference_materials', {
      'material_name': 'Salt',
      'material_code': 'M-SALT-01',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': nowIso(),
    });
    await db.insert('inspections', {
      'entry_code': 'OLD-2025-001',
      'material_id': 1,
      'material_name': 'Salt',
      'material_code': 'M-SALT-01',
      'inspection_date': '2025-06-15',
      'specialist_name': 'Old Specialist',
      'physical_results_json': '{}',
      'chemical_results_json': '{}',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'decision_status': 'FULL_REJECTION',
      'snapshot_json': '{}',
      'sample_names_json': '[]',
      'created_by': 1,
      'created_by_name': 'ghost_user',
      'created_at': '2025-06-15 10:00:00',
      'updated_at': '2025-06-15 10:00:00',
    });
    await db.insert('inspection_status_history', {
      'inspection_id': 1,
      'version': 1,
      'old_status': '',
      'new_status': 'FULL_REJECTION',
      'changed_by': 1,
      'changed_by_name': 'ghost_user',
      'changed_at': '2025-06-15 10:05:00',
    });
    await db.close();

    final copied = await _backup.importInspectionsFromSource(sourceDbPath: src);
    expect(copied, 1);

    final live = await _dbHelper.database;
    final mat = await live.rawQuery(
        "SELECT id FROM reference_materials WHERE material_name = 'Salt'");
    expect(mat, isNotEmpty);
    final insp = await live.rawQuery(
        "SELECT * FROM inspections WHERE entry_code = 'OLD-2025-001'");
    expect(insp, hasLength(1));
    expect('${insp.first['material_name']}', 'Salt');
    final hist = await live.rawQuery(
        'SELECT * FROM inspection_status_history WHERE new_status = ?',
        ['FULL_REJECTION']);
    expect(hist, hasLength(1));
    expect('${hist.first['inspection_id']}', '${insp.first['id']}');
  });

  test('importInspectionsFromSource skips duplicate entry codes', () async {
    final src =
        await createSourceDb({'inspections', 'history', 'reference_materials'});
    final db = await databaseFactoryFfi
        .openDatabase(src, options: OpenDatabaseOptions(version: 1));
    await db.insert('reference_materials', {
      'material_name': 'Sugar',
      'material_code': 'M-SUGAR-01',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': nowIso(),
    });
    await db.insert('inspections', {
      'entry_code': 'QC-MIG-001',
      'material_id': 1,
      'material_name': 'Sugar',
      'material_code': 'M-SUGAR-01',
      'inspection_date': '2025-03-01',
      'specialist_name': 'Ghost',
      'physical_results_json': '{}',
      'chemical_results_json': '{}',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'decision_status': 'APPROVED',
      'snapshot_json': '{}',
      'sample_names_json': '[]',
      'created_by': 1,
      'created_by_name': 'Ghost',
      'created_at': '2025-03-01 09:00:00',
      'updated_at': '2025-03-01 09:00:00',
    });
    await db.close();

    final copied = await _backup.importInspectionsFromSource(sourceDbPath: src);
    expect(copied, 0);
  });

  test('importMaterialsDatabase merges materials and parameters', () async {
    final src = await createSourceDb({'reference_materials', 'parameters'});
    final db = await databaseFactoryFfi
        .openDatabase(src, options: OpenDatabaseOptions(version: 1));
    await db.insert('reference_materials', {
      'material_name': 'Sugar',
      'material_code': 'M-SUGAR-NEW',
      'physical_reference_json': '{"x": 1}',
      'chemical_reference_json': '{}',
      'imported_at': nowIso(),
    });
    await db.insert('reference_materials', {
      'material_name': 'Flour',
      'material_code': 'M-FLOUR-01',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': nowIso(),
    });
    await db.insert('parameters', {
      'parameter_name': 'Moisture',
      'unit': '%',
      'parameter_type': 'physical',
      'imported_at': nowIso(),
    });
    await db.close();

    final result = await _backup.importMaterialsDatabase(sourceDbPath: src);
    expect(result['materials'], 2);
    expect(result['materials_created'], 1);
    expect(result['materials_updated'], 1);
    expect(result['parameters'], 1);
    expect(result['parameters_created'], 1);

    final live = await _dbHelper.database;
    final sugar = await live.rawQuery(
        "SELECT * FROM reference_materials WHERE material_name = 'Sugar'");
    expect(sugar, hasLength(1));
    expect('${sugar.first['material_code']}', 'M-SUGAR-NEW');
    final p = await live.rawQuery(
        "SELECT * FROM parameters WHERE parameter_name = 'Moisture'");
    expect(p, hasLength(1));
  });
}