import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../core/database/database_helper.dart';
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';

/// Port of core/services/backup.py + controller.py backup/restore/migration
/// glue. Qt-free, DB-plumbing only — safe to unit-test headlessly.
class BackupManager {
  BackupManager({required this.dbHelper});

  final DatabaseHelper dbHelper;

  static const Set<String> backupRequiredTables = {
    'users',
    'reference_materials',
    'inspections',
    'settings',
  };

  static const Map<String, Set<String>> backupRequiredColumns = {
    'reference_materials': {
      'id',
      'material_name',
      'material_code',
      'physical_reference_json',
      'chemical_reference_json',
    },
    'users': {'id', 'username', 'password_hash', 'role'},
    'inspections': {'id', 'entry_code', 'material_id', 'inspection_date'},
    'settings': {'key', 'value'},
  };

  static const Set<String> materialsTableRequiredColumns = {
    'material_name',
    'material_code',
    'physical_reference_json',
    'chemical_reference_json',
    'source_row',
    'imported_at',
  };

  static const Set<String> parametersTableRequiredColumns = {
    'parameter_name',
    'unit',
    'parameter_type',
    'imported_at',
  };

  static const String _legacyHashPrefix = 'pbkdf2_sha256\$';
  static const String _v2HashPrefix = 'pbkdf2_sha256_v2\$';

  /// Keep at most this many auto-backups (controller.py `_perform_auto_backup`).
  static const int _autoBackupRetention = 5;

  Future<Database> _openReadOnly(String path) async {
    DatabaseHelper.ensureDesktopFactory();
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(readOnly: true),
    );
  }

  Future<bool> _sameFile(String a, String b) async {
    final resolvedA = p.canonicalize(a);
    final resolvedB = p.canonicalize(b);
    return resolvedA == resolvedB;
  }

  String _sqlQuote(String value) => value.replaceAll("'", "''");

  Future<Set<String>> _tableNames(Database db) async {
    final rows = await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
    return rows.map((r) => '${r['name']}').toSet();
  }

  Future<Set<String>> _columnNames(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.map((r) => '${r['name']}').toSet();
  }

  Future<bool> _integrityOk(Database db) async {
    final check = await db.rawQuery('PRAGMA integrity_check');
    return check.isNotEmpty &&
        '${check.first.values.first}'.trim().toLowerCase() == 'ok';
  }

  // ── Validation / pre-flight ───────────────────────────────────────

  /// Validate that a file is a readable backup with the required schema.
  Future<void> validateBackupDatabase(String backupPath) async {
    Database? conn;
    try {
      conn = await _openReadOnly(backupPath);
      if (!await _integrityOk(conn)) {
        throw const ValidationError(
            'ملف النسخة الاحتياطية تالف (فشل فحص السلامة integrity check).');
      }

      final tables = await _tableNames(conn);
      final missingTables = backupRequiredTables.difference(tables).toList()..sort();
      if (missingTables.isNotEmpty) {
        throw ValidationError(
            'ملف النسخة الاحتياطية غير صالح: الجداول المطلوبة ناقصة: ${missingTables.join(', ')}');
      }

      for (final entry in backupRequiredColumns.entries) {
        final cols = await _columnNames(conn, entry.key);
        final missingCols = entry.value.difference(cols).toList()..sort();
        if (missingCols.isNotEmpty) {
          throw ValidationError(
              "ملف النسخة الاحتياطية قديم جداً أو غير متوافق مع هذا الإصدار: "
              "جدول '${entry.key}' ينقصه الأعمدة: ${missingCols.join(', ')}");
        }
      }
    } on ValidationError {
      rethrow;
    } catch (e) {
      throw ValidationError('ملف النسخة الاحتياطية تالف أو غير قابل للقراءة: $e');
    } finally {
      await conn?.close();
    }
  }

  /// Copy the backup to a temp file and run the full current-schema migration
  /// against the copy. Returns the migrated file path.
  Future<String> preflightMigrateBackup(String backupPath, Directory tempRoot) async {
    final stamp = nowIso().replaceAll(':', '').replaceAll(' ', '_');
    final migrated = p.join(tempRoot.path, 'preflight_$stamp.db');
    await File(backupPath).copy(migrated);
    try {
      await dbHelper.applySchemaToArbitraryFile(migrated);
    } catch (e) {
      throw AppError(
          'تعذر ترقية النسخة الاحتياطية إلى بنية النسخة الحالية من البرنامج: $e');
    }
    Database? conn;
    try {
      conn = await _openReadOnly(migrated);
      if (!await _integrityOk(conn)) {
        throw const AppError(
            'فشل التحقق من سلامة النسخة الاحتياطية بعد الترقية التلقائية.');
      }
    } finally {
      await conn?.close();
    }
    return migrated;
  }

  /// Validate a materials (reference) database file.
  Future<void> validateMaterialsDatabase(String sourcePath) async {
    Database? conn;
    try {
      conn = await _openReadOnly(sourcePath);
      final tables = await _tableNames(conn);
      if (!tables.contains('reference_materials')) {
        throw const ValidationError(
            'Invalid materials database: missing reference_materials table.');
      }
      if (!tables.contains('parameters')) {
        throw const ValidationError(
            'Invalid materials database: missing parameters table.');
      }
      final materialCols = await _columnNames(conn, 'reference_materials');
      final missingMaterials = materialsTableRequiredColumns.difference(materialCols).toList()..sort();
      if (missingMaterials.isNotEmpty) {
        throw ValidationError(
            'Incompatible materials table (missing: ${missingMaterials.join(', ')}).');
      }
      final paramCols = await _columnNames(conn, 'parameters');
      final missingParams = parametersTableRequiredColumns.difference(paramCols).toList()..sort();
      if (missingParams.isNotEmpty) {
        throw ValidationError(
            'Incompatible parameters table (missing: ${missingParams.join(', ')}).');
      }
    } finally {
      await conn?.close();
    }
  }

  // ── Export / restore ─────────────────────────────────────────────

  /// Export a full backup of the live database. Mirrors
  /// controller.export_database_backup (VACUUM INTO achieves the same
  /// consistent snapshot as sqlite's online backup API).
  Future<Map<String, dynamic>> exportDatabaseBackup({String? explicitPath}) async {
    final db = await dbHelper.database;
    final livePath = await dbHelper.databasePath;

    String backupPath;
    if (explicitPath != null && explicitPath.trim().isNotEmpty) {
      backupPath = explicitPath.trim();
      if (p.extension(backupPath).isEmpty) backupPath = '$backupPath.db';
    } else {
      final dir = await dbHelper.paths.backupsDir();
      backupPath = p.join(dir.path, 'material_lab_backup_${fileTimestamp()}.db');
    }
    if (await _sameFile(backupPath, livePath)) {
      throw const ValidationError(
          'Backup path must be different from the active database path.');
    }

    final target = File(backupPath);
    if (await target.exists()) await target.delete();
    await target.parent.create(recursive: true);

    await db.execute('PRAGMA wal_checkpoint(FULL)');
    await db.execute("VACUUM INTO '${_sqlQuote(backupPath)}'");

    Database? checkDb;
    try {
      checkDb = await _openReadOnly(backupPath);
      if (!await _integrityOk(checkDb)) {
        throw const AppError('Backup was created but integrity verification failed.');
      }
    } finally {
      await checkDb?.close();
    }
    return {
      'path': backupPath,
      'size_bytes': await target.length(),
      'created_at': nowIso(),
    };
  }

  /// Create an automatic safety backup (retaining the latest 5) before a
  /// restore overwrites the live database. Failures are silent (parity with
  /// controller._perform_auto_backup).
  Future<void> autoBackup() async {
    try {
      final dir = await dbHelper.paths.autoBackupDir();
      final backupPath = p.join(dir.path, 'material_lab_backup_${fileTimestamp()}.db');

      final db = await dbHelper.database;
      await db.execute('PRAGMA wal_checkpoint(FULL)');
      await db.execute("VACUUM INTO '${_sqlQuote(backupPath)}'");

      Database? checkDb;
      try {
        checkDb = await _openReadOnly(backupPath);
        if (!await _integrityOk(checkDb)) {
          final f = File(backupPath);
          if (await f.exists()) await f.delete();
          return;
        }
      } finally {
        await checkDb?.close();
      }

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) =>
              p.basename(f.path).startsWith('material_lab_backup_') &&
              f.path.endsWith('.db'))
          .toList()
        ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      while (files.length > _autoBackupRetention) {
        final oldest = files.removeAt(0);
        try {
          await oldest.delete();
        } catch (_) {}
      }
    } catch (_) {
      // Auto-backup must never break the restore flow.
    }
  }

  /// Restore the live database from a backup, upgrading old backups to the
  /// current schema first. On failure the sign-in state is invalidated by the
  /// caller (the DB may be untouched).
  Future<Map<String, dynamic>> restoreDatabaseBackup(String backupPath) async {
    final livePath = await dbHelper.databasePath;
    if (await _sameFile(backupPath, livePath)) {
      throw const ValidationError('Selected file is already the active database.');
    }
    await validateBackupDatabase(backupPath);

    final tempRoot = await Directory.systemTemp.createTemp('lab_restore_');
    try {
      await autoBackup();
      final migrated = await preflightMigrateBackup(backupPath, tempRoot);

      await dbHelper.close();

      for (final side in [livePath, '$livePath-wal', '$livePath-shm']) {
        final f = File(side);
        if (await f.exists()) await f.delete();
      }
      await File(migrated).copy(livePath);

      await dbHelper.database;
      await dbHelper.ensureSchema();
    } catch (e) {
      throw AppError('فشل استرداد قاعدة البيانات: $e');
    } finally {
      await cleanupTempRoot(tempRoot);
    }
    return {
      'restored': true,
      'path': backupPath,
      'message':
          'تم استرداد قاعدة البيانات بنجاح (مع ترقية تلقائية للنسخ القديمة إلى '
          'البنية الحالية). سيتم تسجيل الخروج الآن.',
    };
  }

  // ── Cross-database import (migration wizard) ─────────────────────

  /// Copy users from a source database. Legacy (no-pepper) hashes are kept and
  /// auto-upgrade to V2 on next login.
  Future<Map<String, dynamic>> pullUsersFromSourceDb({
    required String sourceDbPath,
    String developerName = '',
  }) async {
    final livePath = await dbHelper.databasePath;
    const emptyResult = {
      'users_copied': 0,
      'users_skipped': 0,
      'legacy_count': 0,
      'v2_count': 0,
    };
    if (await _sameFile(sourceDbPath, livePath)) return emptyResult;

    final db = await dbHelper.database;
    Database? source;
    var copied = 0, skipped = 0, legacyCount = 0, v2Count = 0;
    try {
      source = await _openReadOnly(sourceDbPath);
      final tables = await _tableNames(source);
      if (!tables.contains('users')) return emptyResult;

      final cols = await _columnNames(source, 'users');
      const required = {'username', 'full_name', 'password_hash', 'role', 'created_at'};
      final missing = required.difference(cols).toList()..sort();
      if (missing.isNotEmpty) {
        throw ValidationError(
            'Source database users table is missing columns: ${missing.join(', ')}');
      }

      final hasIsActive = cols.contains('is_active');
      final sourceUsers = hasIsActive
          ? await source.rawQuery(
              'SELECT username, full_name, password_hash, role, is_active, created_at FROM users')
          : await source.rawQuery(
              'SELECT username, full_name, password_hash, role, created_at FROM users');

      final existingRows = await db.rawQuery('SELECT username FROM users');
      final pending = existingRows.map((r) => '${r['username']}').toSet();

      final rowsToInsert = <Map<String, Object?>>[];
      for (final user in sourceUsers) {
        final username = '${user['username'] ?? ''}'.trim();
        if (username.isEmpty) {
          skipped++;
          continue;
        }
        if (username == developerName) {
          skipped++;
          continue;
        }
        if (pending.contains(username)) {
          skipped++;
          continue;
        }
        pending.add(username);
        final hash = '${user['password_hash'] ?? ''}';
        if (hash.isEmpty) {
          skipped++;
          continue;
        }
        if (hash.startsWith(_legacyHashPrefix)) {
          legacyCount++;
        } else if (hash.startsWith(_v2HashPrefix)) {
          v2Count++;
        }
        final fullName = '${user['full_name'] ?? username}'.trim();
        var role = '${user['role'] ?? 'Lab User'}'.trim();
        if (role == 'Developer') role = 'Admin';
        var isActive = 1;
        if (hasIsActive) {
          final rawActive = user['is_active'];
          if (rawActive != null) {
            final parsed = int.tryParse('$rawActive');
            if (parsed != null) isActive = parsed;
          }
        }
        rowsToInsert.add({
          'username': username,
          'full_name': fullName,
          'password_hash': hash,
          'role': role,
          'is_active': isActive,
          'created_at': '${user['created_at'] ?? nowIso()}'.trim(),
        });
      }
      if (rowsToInsert.isNotEmpty) {
        final batch = db.batch();
        for (final row in rowsToInsert) {
          batch.insert('users', row, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await batch.commit(noResult: true);
        copied = rowsToInsert.length;
      }
    } finally {
      await source?.close();
    }
    return {
      'users_copied': copied,
      'users_skipped': skipped,
      'legacy_count': legacyCount,
      'v2_count': v2Count,
    };
  }

  /// Copy inspections (and their status history) from a source database,
  /// creating missing reference materials. Returns the number of inspections
  /// copied.
  Future<int> importInspectionsFromSource({required String sourceDbPath}) async {
    final livePath = await dbHelper.databasePath;
    if (await _sameFile(sourceDbPath, livePath)) return 0;

    final db = await dbHelper.database;
    Database? source;
    var copied = 0;
    try {
      source = await _openReadOnly(sourceDbPath);
      final tables = await _tableNames(source);
      if (!tables.contains('inspections')) return 0;

      final sourceInspections =
          await source.rawQuery('SELECT * FROM inspections ORDER BY id ASC');
      final sourceHistory = tables.contains('inspection_status_history')
          ? await source.rawQuery(
              'SELECT * FROM inspection_status_history ORDER BY id ASC')
          : <Map<String, Object?>>[];

      final existingCodes = (await db.rawQuery('SELECT entry_code FROM inspections'))
          .map((r) => '${r['entry_code']}')
          .toSet();
      final userRows = await db.rawQuery('SELECT id, username FROM users');
      final usernamesToId = <String, int>{
        for (final r in userRows) '${r['username']}': int.parse('${r['id']}'),
      };
      final materialRows =
          await db.rawQuery('SELECT id, material_name FROM reference_materials');
      final materialNameToId = <String, int>{
        for (final r in materialRows) '${r['material_name']}': int.parse('${r['id']}'),
      };
      final timestamp = nowIso();
      final idMap = <int, int>{};

      await db.execute('PRAGMA foreign_keys = OFF');
      try {
        await db.transaction((txn) async {
          final newMaterials = <List<Object?>>[];
          final pendingMaterials = <String>{};
          for (final insp in sourceInspections) {
            final entryCode = '${insp['entry_code'] ?? ''}'.trim();
            if (entryCode.isEmpty || existingCodes.contains(entryCode)) continue;
            final materialName = '${insp['material_name'] ?? 'Unknown'}'.trim();
            final materialCode = '${insp['material_code'] ?? ''}'.trim();
            final key = materialName.toLowerCase();
            if (!materialNameToId.containsKey(materialName) &&
                !pendingMaterials.contains(key)) {
              pendingMaterials.add(key);
              newMaterials.add([materialName, materialCode, timestamp]);
            }
          }
          if (newMaterials.isNotEmpty) {
            for (final m in newMaterials) {
              await txn.insert(
                'reference_materials',
                {
                  'material_name': m[0],
                  'material_code': m[1],
                  'physical_reference_json': '{}',
                  'chemical_reference_json': '{}',
                  'imported_at': m[2],
                },
                conflictAlgorithm: ConflictAlgorithm.ignore,
              );
            }
            for (final m in newMaterials) {
              final rows = await txn.rawQuery(
                  'SELECT id FROM reference_materials WHERE material_name = ?', [m[0]]);
              if (rows.isNotEmpty) {
                materialNameToId['${m[0]}'] = int.parse('${rows.first['id']}');
              }
            }
          }

          for (final insp in sourceInspections) {
            final entryCode = '${insp['entry_code'] ?? ''}'.trim();
            if (entryCode.isEmpty || existingCodes.contains(entryCode)) continue;
            final materialName = '${insp['material_name'] ?? 'Unknown'}'.trim();
            final materialId = materialNameToId[materialName]!;
            final createdByName = '${insp['created_by_name'] ?? ''}'.trim();
            final createdBy = usernamesToId[createdByName] ?? 1;
            final dv = insp['decision_version'];

            final newId = await txn.insert('inspections', {
              'entry_code': entryCode,
              'material_id': materialId,
              'material_name': materialName,
              'material_code': '${insp['material_code'] ?? ''}',
              'inspection_date': '${insp['inspection_date'] ?? ''}',
              'expiry_date': '${insp['expiry_date'] ?? ''}',
              'supplier': '${insp['supplier'] ?? ''}',
              'truck_number': '${insp['truck_number'] ?? ''}',
              'quantity': '${insp['quantity'] ?? ''}',
              'sample_taken_by': '${insp['sample_taken_by'] ?? ''}',
              'specialist_name': '${insp['specialist_name'] ?? ''}',
              'physical_results_json': '${insp['physical_results_json'] ?? '{}'}',
              'chemical_results_json': '${insp['chemical_results_json'] ?? '{}'}',
              'physical_reference_json': '${insp['physical_reference_json'] ?? '{}'}',
              'chemical_reference_json': '${insp['chemical_reference_json'] ?? '{}'}',
              'decision_status': '${insp['decision_status'] ?? ''}',
              'decision_reason': '${insp['decision_reason'] ?? ''}',
              'follow_up_note': '${insp['follow_up_note'] ?? ''}',
              'rejected_quantity': '${insp['rejected_quantity'] ?? ''}',
              'report_html': '${insp['report_html'] ?? ''}',
              'snapshot_json': '${insp['snapshot_json'] ?? '{}'}',
              'sample_names_json': '${insp['sample_names_json'] ?? '[]'}',
              'decision_version': dv != null ? (int.tryParse('$dv') ?? 1) : 1,
              'created_by': createdBy,
              'created_by_name': createdByName,
              'last_pdf_path': '',
              'created_at': '${insp['created_at'] ?? timestamp}',
              'updated_at': '${insp['updated_at'] ?? timestamp}',
            });
            idMap[int.parse('${insp['id']}')] = newId;
            copied++;
            existingCodes.add(entryCode);
          }

          for (final hist in sourceHistory) {
            final oldId = int.parse('${hist['inspection_id']}');
            final newId = idMap[oldId];
            if (newId == null) continue;
            final changedByName = '${hist['changed_by_name'] ?? ''}'.trim();
            final changedBy = usernamesToId[changedByName] ?? 1;
            final ver = hist['version'];
            await txn.insert('inspection_status_history', {
              'inspection_id': newId,
              'version': ver != null ? (int.tryParse('$ver') ?? 1) : 1,
              'old_status': '${hist['old_status'] ?? ''}',
              'new_status': '${hist['new_status'] ?? ''}',
              'change_reason': '${hist['change_reason'] ?? ''}',
              'follow_up_note': '${hist['follow_up_note'] ?? ''}',
              'rejected_quantity': '${hist['rejected_quantity'] ?? ''}',
              'changed_by': changedBy,
              'changed_by_name': changedByName,
              'changed_at': '${hist['changed_at'] ?? nowIso()}',
            });
          }
        });
      } finally {
        await db.execute('PRAGMA foreign_keys = ON');
      }
    } finally {
      await source?.close();
    }
    return copied;
  }

  /// Merge materials + parameters from a source materials DB into the live
  /// database (Upsert on name). Optionally re-import units when the source has
  /// no parameters table rows.
  Future<Map<String, dynamic>> importMaterialsDatabase({
    required String sourceDbPath,
    Future<int> Function()? importUnits,
  }) async {
    final db = await dbHelper.database;
    final livePath = await dbHelper.databasePath;
    Database? source;
    try {
      source = await _openReadOnly(sourceDbPath);
      final materialRows = await source.rawQuery('''
            SELECT material_name, material_code, physical_reference_json,
                   chemical_reference_json, source_row, imported_at
            FROM reference_materials
            ''');
      final tables = await _tableNames(source);
      final parameterRows = tables.contains('parameters')
          ? await source.rawQuery(
              'SELECT parameter_name, unit, parameter_type, imported_at FROM parameters')
          : <Map<String, Object?>>[];

      final existingMaterials =
          (await db.rawQuery('SELECT material_name FROM reference_materials'))
              .map((r) => '${r['material_name']}')
              .toSet();
      final existingParameters =
          (await db.rawQuery('SELECT parameter_name FROM parameters'))
              .map((r) => '${r['parameter_name']}')
              .toSet();
      final timestamp = nowIso();

      await db.transaction((txn) async {
        for (final row in materialRows) {
          await txn.rawInsert(
            '''
            INSERT INTO reference_materials (
                material_name, material_code, physical_reference_json,
                chemical_reference_json, source_row, imported_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(material_name) DO UPDATE SET
                material_code = excluded.material_code,
                physical_reference_json = excluded.physical_reference_json,
                chemical_reference_json = excluded.chemical_reference_json,
                source_row = excluded.source_row,
                imported_at = excluded.imported_at
            ''',
            [
              '${row['material_name'] ?? ''}',
              '${row['material_code'] ?? ''}',
              '${row['physical_reference_json'] ?? ''}',
              '${row['chemical_reference_json'] ?? ''}',
              row['source_row'],
              '${row['imported_at'] ?? timestamp}',
            ],
          );
        }
        for (final row in parameterRows) {
          await txn.rawInsert(
            '''
            INSERT INTO parameters (
                parameter_name, unit, parameter_type, imported_at
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(parameter_name) DO UPDATE SET
                unit = excluded.unit,
                parameter_type = excluded.parameter_type,
                imported_at = excluded.imported_at
            ''',
            [
              '${row['parameter_name'] ?? ''}',
              '${row['unit'] ?? ''}',
              '${row['parameter_type'] ?? 'physical'}',
              '${row['imported_at'] ?? timestamp}',
            ],
          );
        }
      });

      var importedUnits = 0;
      if (parameterRows.isEmpty && importUnits != null) {
        importedUnits = await importUnits();
      }
      final materialCount = materialRows.length;
      final parameterCount = parameterRows.isNotEmpty ? parameterRows.length : importedUnits;
      final createdMaterials = materialRows
          .where((r) => !existingMaterials.contains('${r['material_name']}'))
          .length;
      final createdParameters = parameterRows
          .where((r) => !existingParameters.contains('${r['parameter_name']}'))
          .length;
      return {
        'imported': true,
        'materials': materialCount,
        'materials_created': createdMaterials,
        'materials_updated': materialCount - createdMaterials,
        'parameters': parameterCount,
        'parameters_created':
            parameterRows.isNotEmpty ? createdParameters : importedUnits,
        'parameters_updated':
            parameterRows.isNotEmpty ? (parameterRows.length - createdParameters) : 0,
        'target_path': livePath,
        'message':
            'تم تحديث $materialCount خامة و $parameterCount وحدة/متطلب '
            'بدون تغيير الإعدادات أو المسارات المحلية.',
      };
    } finally {
      await source?.close();
    }
  }

  static Future<void> cleanupTempRoot(Directory? tempRoot) async {
    if (tempRoot == null) return;
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  }
}