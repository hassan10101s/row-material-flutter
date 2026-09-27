import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/network/connectivity_service.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_engine.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/backup/data/backup_manager.dart';
import 'package:material_lab/features/settings/presentation/cubit/database_settings_cubit.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Plan §14-P11: a restore must not produce false data, must not lose a sample,
/// and must leave the sync queue in a state the engine can reason about.
///
/// The two guarantees proved here:
///  * the cached connections (`SyncQueue`, `SyncMetadata`) follow the file that
///    was just replaced, so the next cycle writes to the **restored** database;
///  * a queue entry whose local row is not in the restored file becomes a
///    visible conflict instead of disappearing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  const orgId = 'org_test';

  late Directory tmp;
  late DatabaseHelper helper;
  late SyncQueue queue;
  late SyncMetadata metadata;
  late AuditLogger audit;
  late BackupManager backup;
  late InMemoryDataSource remote;
  late AppSession session;
  late SyncEngine engine;
  late DatabaseSettingsCubit cubit;

  SyncEngine buildEngine() {
    final source = SessionSource.empty(() => session);
    return buildSyncEngine(
      pushWorker: PushWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        audit: audit,
        source: source,
      ),
      pullWorker: PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: ConflictResolver(queue: queue, remote: remote),
        source: source,
      ),
      queue: queue,
      metadata: metadata,
      audit: audit,
      connectivity: ConnectivityService(),
      conflicts: ConflictResolver(queue: queue, remote: remote),
      remote: remote,
    );
  }

  Future<void> insertInspection(String entryCode) async {
    final db = await helper.database;
    await db.insert('inspections', {
      'entry_code': entryCode,
      'material_id': 1,
      'material_name': 'Cement',
      'material_code': 'M-CEM-01',
      'inspection_date': '2026-09-01',
      'supplier': 'Cement Supplier Co',
      'quantity': '10',
      'specialist_name': 'Lab Specialist',
      'physical_results_json': '{}',
      'chemical_results_json': '{}',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'decision_status': 'pending',
      'snapshot_json': '{}',
      'sample_names_json': '[]',
      'created_by': 1,
      'created_by_name': 'Admin',
      'created_at': '2026-09-01 08:00:00',
      'updated_at': '2026-09-01 08:00:00',
    });
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_restore');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    await helper.bindOrg(orgId);
    final db0 = await helper.database;
    await db0.insert('users', {
      'id': 1,
      'email': 'admin@material-lab.test',
      'full_name': 'Admin',
      'role': 'admin',
      'status': 'active',
      'created_at': '2026-09-01 08:00:00',
    });
    await db0.insert('reference_materials', {
      'id': 1,
      'material_name': 'Cement',
      'material_code': 'M-CEM-01',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': '2026-09-01 08:00:00',
    });
    queue = SyncQueue(helper);
    metadata = SyncMetadata(helper);
    remote = InMemoryDataSource(rolesByUid: const {'uid_admin': 'admin'});
    session = const AppSession(
      uid: 'uid_admin',
      email: 'admin@material-lab.test',
      organizationId: orgId,
      memberId: 'member_1',
      role: 'admin',
      status: 'active',
      deviceId: 'dev_this',
    );
    audit = AuditLogger(queue: queue, session: () => session);
    backup = BackupManager(dbHelper: helper);
    engine = buildEngine();
    cubit = DatabaseSettingsCubit(backup: backup, engine: engine);
  });

  tearDown(() async {
    await helper.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('the restored file is the one the next write goes to', () async {
    await insertInspection('QC-OLD');
    final exported = await backup.exportDatabaseBackup();

    // The live database moves on after the backup was taken.
    await insertInspection('QC-NEW');
    expect(await queue.countPending(), 0);

    await cubit.restoreBackup('${exported['path']}');

    final db = await helper.database;
    final rows = await db.query('inspections', columns: ['entry_code']);
    expect(rows.map((r) => r['entry_code']), ['QC-OLD'],
        reason: 'the restore is authoritative');
    expect(cubit.state.restored, isTrue);
    expect(cubit.state.error, isNull);

    // The queue and the metadata follow the replaced file: a write after the
    // restore lands in the restored database, not in the deleted one.
    await insertInspection('QC-AFTER');
    final after = await helper.database;
    expect(
      (await after.query('inspections', columns: ['entry_code']))
          .map((r) => r['entry_code']),
      containsAll(['QC-OLD', 'QC-AFTER']),
    );
    expect(await queue.countPending(), 0);
  });

  test('a queued change is re-queued after a restore so it still reaches the server',
      () async {
    await insertInspection('QC-QUEUED');
    final db = await helper.database;
    await db.insert('sync_queue', {
      'entity_type': 'sample',
      'entity_id': 'QC-QUEUED',
      'local_ref': 1,
      'operation': 'update',
      'payload': '{}',
      'base_version': 1,
      'status': 'pending',
      'retry_count': 0,
      'created_at': '2026-09-01 08:00:00',
      'updated_at': '2026-09-01 08:00:00',
    });
    // The row is not marked as waiting for the server.
    await db.update('inspections', {'sync_state': 'synced'}, where: 'id = 1');

    final report = await engine.reconcileAfterRestore();

    expect(report.requeuedRows, 1);
    expect(report.orphanedEntries, 0);
    final after = await helper.database;
    expect((await after.query('inspections', where: 'id = 1')).single['sync_state'],
        'queued');
    expect(await queue.countPending(), greaterThan(0),
        reason: 'the change must not be stranded by the restore');
  });

  test('a queue entry whose row is gone becomes a conflict, never a deletion',
      () async {
    final db = await helper.database;
    await insertInspection('QC-KEEP');
    await db.insert('sync_queue', {
      'entity_type': 'sample',
      'entity_id': 'QC-GONE',
      'local_ref': 4242,
      'operation': 'update',
      'payload': '{}',
      'base_version': 1,
      'status': 'pending',
      'retry_count': 0,
      'created_at': '2026-09-01 08:00:00',
      'updated_at': '2026-09-01 08:00:00',
    });

    final report = await engine.reconcileAfterRestore();

    expect(report.orphanedEntries, 1);
    final after = await helper.database;
    final conflicts = await after.query('sync_conflicts');
    expect(conflicts, hasLength(1));
    expect(conflicts.single['entity_id'], 'QC-GONE');
    expect(
      (await after.query('inspections', columns: ['entry_code'])).map((r) => r['entry_code']),
      ['QC-KEEP'],
      reason: 'no sample may be deleted by a reconciliation',
    );
    expect(await queue.countBlocked(), greaterThan(0),
        reason: 'the user has to see it');
  });

  test('the device id of the restored file is replaced by this installation',
      () async {
    await metadata.ensureDeviceId(() => 'dev_other');
    expect(await metadata.get(SyncMetadata.deviceIdKey), 'dev_other');

    final report = await engine.reconcileAfterRestore();

    expect(report.deviceIdReplaced, isTrue);
    expect(await metadata.get(SyncMetadata.deviceIdKey), 'dev_this',
        reason: 'the device id belongs to the installation, not to the backup');
  });

  test('a restore of an old backup keeps the schema (integrity_check ok)',
      () async {
    await insertInspection('QC-INT');
    final exported = await backup.exportDatabaseBackup();
    await cubit.restoreBackup('${exported['path']}');

    final db = await helper.database;
    final check = await db.rawQuery('PRAGMA integrity_check');
    expect('${check.first.values.first}', 'ok');
    // The sync bookkeeping tables the restore depends on are there.
    final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'")).map((r) => r['name']);
    expect(tables, containsAll(['sync_queue', 'sync_metadata', 'sync_conflicts', 'audit_logs']));
  });

  test('a report for a clean restore says so', () async {
    final report = await engine.reconcileAfterRestore();
    expect(report.isClean, isTrue);
  });
}
