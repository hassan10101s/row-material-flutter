import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';

/// Shared fixture for the sync tests (plan §14-P6.5): a **real** SQLite file
/// created by the production [DatabaseHelper], so the schema, the partial
/// unique index on `sync_queue` and the triggers are the production ones.
class FakeAppPaths extends AppPaths {
  FakeAppPaths(this.base);

  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Creates a fresh, fully migrated database in a temp directory.
Future<SyncFixture> openSyncFixture() async {
  DatabaseHelper.ensureDesktopFactory();
  final dir = await Directory.systemTemp.createTemp('matlab_sync');
  final helper = DatabaseHelper(FakeAppPaths(dir.path));
  // Touch the database so the schema is created before the test body runs.
  final db = await helper.database;
  return SyncFixture(dir: dir, helper: helper, db: db);
}

class SyncFixture {
  SyncFixture({required this.dir, required this.helper, required this.db});

  final Directory dir;
  final DatabaseHelper helper;
  final Database db;

  /// Runs [body] inside one transaction and returns its result - the seam P7
  /// uses for "local write + queue + audit in a single transaction".
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor txn) body) =>
      db.transaction<T>(body);

  /// Seeds the FK targets an `inspections` row needs: the org owner
  /// (`users`) and the reference material. Idempotent.
  Future<void> seedOrganization({
    int userId = 1,
    String uid = 'uid_admin',
    String email = 'admin@material-lab.test',
  }) async {
    if (await db.query('users', where: 'id = ?', whereArgs: [userId], limit: 1).then((r) => r.isEmpty)) {
      await db.insert('users', <String, dynamic>{
        'id': userId,
        'uid': uid,
        'email': email,
        'full_name': 'Ahmed Ali',
        'display_name': 'Ahmed Ali',
        'role': 'admin',
        'status': 'active',
        'permissions_json': '[]',
        'version': 1,
        'updated_at': '2026-09-01T07:00:00.000',
        'created_at': '2026-09-01T07:00:00.000',
      });
    }
    if (await db.query('reference_materials', where: 'id = ?', whereArgs: [1], limit: 1).then((r) => r.isEmpty)) {
      await db.insert('reference_materials', <String, dynamic>{
        'id': 1,
        'material_name': 'Cement',
        'material_code': 'M-CEM-01',
        'physical_reference_json': '{}',
        'chemical_reference_json': '{}',
        'imported_at': '2026-09-01T07:00:00.000',
        'active': 1,
      });
    }
  }

  Future<void> dispose() async {
    await db.close();
    if (dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows keeps the file handle around; the temp dir is disposable.
      }
    }
  }
}

/// Minimal `inspections` row: the sample table is the one every sync test
/// pushes, because `SyncEntity.docId` for a sample is its `entry_code`.
///
/// Column names must match the production schema (plan §6.5): the per-row
/// sync version of an inspection is the legacy `decision_version` column, and
/// `updatedBy`/`deviceId` are pushed from the session, not stored locally.
Map<String, dynamic> sampleRow({
  required String entryCode,
  String decisionStatus = 'PENDING',
  int decisionVersion = 1,
  int remoteVersion = 0,
  String syncState = 'local',
  String? deletedAt,
}) =>
    <String, dynamic>{
      'entry_code': entryCode,
      'material_id': 1,
      'material_name': 'Cement',
      'material_code': 'M-CEM-01',
      'inspection_date': '2026-09-01',
      'specialist_name': 'Ahmed Ali',
      'physical_results_json': '{}',
      'chemical_results_json': '{}',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'decision_status': decisionStatus,
      'snapshot_json': '{}',
      'sample_names_json': '[]',
      'decision_version': decisionVersion,
      'remote_version': remoteVersion,
      'sync_state': syncState,
      'created_by': 1,
      'created_by_name': 'Ahmed Ali',
      'created_at': '2026-09-01T08:00:00.000',
      'updated_at': '2026-09-01T08:00:00.000',
      'deleted_at': ?deletedAt,
    };

/// A row of the append-only `inspection_status_history` (a `qualityCheck`).
/// Its `version` column *is* the sync version, and its doc id is
/// `qc_<inspection_id>_<version>`.
Map<String, dynamic> historyRow({
  required int inspectionId,
  required String newStatus,
  int version = 1,
  String? oldStatus,
}) =>
    <String, dynamic>{
      'inspection_id': inspectionId,
      'version': version,
      'old_status': ?oldStatus,
      'new_status': newStatus,
      'change_reason': '',
      'changed_by': 1,
      'changed_by_name': 'Ahmed Ali',
      'changed_at': '2026-09-01T09:00:00.000',
      'remote_version': 0,
      'sync_state': 'local',
    };
