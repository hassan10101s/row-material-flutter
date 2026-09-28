import 'package:sqflite/sqflite.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/entity_registry.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../organizations/data/member_write_guard.dart';
import 'reference_repo.dart';

/// Offline-first facade over the local [ReferenceRepo].
///
/// Same arrangement as the inspections facade: the local repository keeps all
/// of its SQL, and this class is the seam that owns the V2 write contract:
///
/// * the local write, its `sync_queue` row and its `audit_logs` outbox row
///   commit in **one** SQLite transaction, and
/// * the local guards of §9.4 (session / permission / read-only / online-only)
///   run before the write is attempted.
///
/// It extends [ReferenceRepo] so cubits and widgets keep their current
/// dependency type: GetIt registers this class under the name `ReferenceRepo`,
/// which is why no presentation file has to change.
class OfflineFirstReferenceRepository extends ReferenceRepo {
  OfflineFirstReferenceRepository({
    required super.dbHelper,
    required this.guard,
    required this.queue,
    required this.audit,
  });

  final WriteGuard guard;
  final SyncQueue queue;
  final AuditLogger audit;

  static final SyncEntity _labUnit =
      syncEntities.firstWhere((e) => e.type == 'labUnit');

  // ── §9.4 writes: Materials ────────────────────────────────────

  @override
  Future<int> createMaterial({
    required String materialName,
    required String materialCode,
    Map<String, dynamic> physicalReference = const {},
    Map<String, dynamic> chemicalReference = const {},
    Map<String, dynamic> units = const {},
  }) async {
    _check(Permission.samplesUpdate);
    final db = await dbHelper.database;
    late final int id;
    await db.transaction((txn) async {
      id = await super.createMaterial(
        materialName: materialName,
        materialCode: materialCode,
        physicalReference: physicalReference,
        chemicalReference: chemicalReference,
        units: units,
      );
      final row = await getMaterialRaw(id, exec: txn);
      if (row != null) {
        await audit.log(
          txn,
          action: AuditAction.settingsUpdated,
          entityType: 'referenceMaterial',
          entityId: 'ref_mat_$id',
          details: {
            'localId': id,
            'materialName': row['material_name'],
            'materialCode': row['material_code'],
          },
        );
      }
    });
    return id;
  }

  @override
  Future<void> updateMaterial(
    int id, {
    required String materialName,
    required String materialCode,
    Map<String, dynamic>? physicalReference,
    Map<String, dynamic>? chemicalReference,
    Map<String, dynamic> units = const {},
  }) async {
    _check(Permission.samplesUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await super.updateMaterial(
        id,
        materialName: materialName,
        materialCode: materialCode,
        physicalReference: physicalReference,
        chemicalReference: chemicalReference,
        units: units,
      );
      final row = await getMaterialRaw(id, exec: txn);
      if (row != null) {
        await audit.log(
          txn,
          action: AuditAction.settingsUpdated,
          entityType: 'referenceMaterial',
          entityId: 'ref_mat_$id',
          details: {
            'localId': id,
            'materialName': row['material_name'],
            'materialCode': row['material_code'],
          },
        );
      }
    });
  }

  /// A tombstone (soft-delete) so delete is auditable and consistent with
  /// the rest of the domain.
  @override
  Future<void> deleteMaterial(int id) async {
    _check(Permission.samplesUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await super.deleteMaterial(id);
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'referenceMaterial',
        entityId: 'ref_mat_$id',
        details: {'localId': id, 'operation': 'delete'},
      );
    });
  }

  // ── §9.4 writes: Parameters ───────────────────────────────────

  @override
  Future<void> upsertParameter(
    String name,
    String unit, {
    String parameterType = 'chemical',
  }) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await super.upsertParameter(name, unit, parameterType: parameterType);
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'parameter',
        entityId: 'param_${parameterType}_${name.trim()}',
        details: {
          'parameterName': name.trim(),
          'parameterType': parameterType,
          'unit': unit.trim(),
        },
      );
    });
  }

  @override
  Future<void> deleteParameter(String name) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await super.deleteParameter(name);
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'parameter',
        entityId: 'param_$name',
        details: {'parameterName': name.trim(), 'operation': 'delete'},
      );
    });
  }

  // ── §9.4 writes: Lab units ────────────────────────────────────

  @override
  Future<void> upsertUnit(
    String symbol, {
    String name = '',
    String dimension = '',
  }) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await super.upsertUnit(symbol, name: name, dimension: dimension);
      final trimmed = symbol.trim();
      final rows = await txn.query(
        'lab_units',
        where: 'symbol = ?',
        whereArgs: [trimmed],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        await _enqueueLabUnit(
          txn,
          Map<String, dynamic>.from(rows.first),
          operation: 'upsert',
          action: AuditAction.settingsUpdated,
          details: {
            'symbol': trimmed,
            'name': name.trim(),
            'dimension': dimension.trim(),
          },
        );
      }
    });
  }

  @override
  Future<void> deleteUnit(String symbol) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final trimmed = symbol.trim();
      final rows = await txn.query(
        'lab_units',
        where: 'symbol = ?',
        whereArgs: [trimmed],
        limit: 1,
      );
      await super.deleteUnit(trimmed);
      if (rows.isNotEmpty) {
        final row = Map<String, dynamic>.from(rows.first)
          ..['is_active'] = 0
          ..['deleted_at'] = DateTime.now().toIso8601String();
        await _enqueueLabUnit(
          txn,
          row,
          operation: 'tombstone',
          action: AuditAction.settingsUpdated,
          details: {'symbol': trimmed, 'operation': 'delete'},
        );
      }
    });
  }

  // ── Transaction plumbing ──────────────────────────────────────

  /// §9.4: active member + permission + not a read-only device, and
  /// connectivity for the privileged operations. Throws
  /// [AuthorizationError] otherwise, before anything is written.
  void _check(Permission permission) {
    if (guard.allows(permission.id)) return;
    final privileged = permissionRequiresFreshSession(permission);
    throw AuthorizationError(
      privileged && !guard.online
          ? AppErrors.privilegedOperationNeedsConnection
          : AppErrors.notAuthorizedForOperation,
    );
  }

  /// Bumps the sync bookkeeping of the row, snapshots the remote payload,
  /// queues it and appends the audit entry — all on the caller's executor.
  Future<void> _enqueueLabUnit(
    DatabaseExecutor txn,
    Map<String, dynamic> row, {
    required String operation,
    required String action,
    required Map<String, dynamic> details,
  }) async {
    final id = (row['id'] as num?)?.toInt();
    if (id == null) return;
    final localVersion = (row['version'] as num?)?.toInt() ?? 0;
    final remoteVersion = (row['remote_version'] as num?)?.toInt() ?? 0;
    final isFirstPush = remoteVersion == 0;
    final nextVersion = isFirstPush
        ? 1
        : (localVersion > remoteVersion ? localVersion : remoteVersion) + 1;
    await txn.update(
      'lab_units',
      {
        'version': nextVersion,
        'sync_state': 'queued',
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    final snapshot = Map<String, dynamic>.from(row)
      ..['version'] = nextVersion
      ..['sync_state'] = 'queued'
      ..['is_active'] = row['is_active'] is int
          ? row['is_active']
          : ((row['is_active'] as bool?) ?? true ? 1 : 0)
      ..['deleted_at'] = row['deleted_at']
      ..['config_type'] = 'unit'
      ..['payload'] = {
        'symbol': row['symbol'],
        'name': row['name'],
        'dimension': row['dimension'],
        'is_active': row['is_active'] is int
            ? row['is_active']
            : ((row['is_active'] as bool?) ?? true ? 1 : 0),
      };

    final ctx = SyncPayloadContext(
      organizationId: guard.organizationId,
      uid: guard.uid,
      deviceId: guard.deviceId,
      version: nextVersion,
      versionField: 'version',
    );
    final docId = _labUnit.docId(snapshot);
    await queue.enqueue(
      txn,
      entityType: _labUnit.type,
      entityId: docId,
      localRef: id,
      operation: operation,
      payload: buildRemotePayload(_labUnit, snapshot, ctx,
          asCreate: isFirstPush || operation == 'tombstone'),
      baseVersion: remoteVersion,
    );
    await audit.log(
      txn,
      action: action,
      entityType: _labUnit.type,
      entityId: docId,
      details: {
        ...details,
        'localId': id,
        'version': nextVersion,
        'operation': operation,
        'actor': guard.email,
      },
    );
  }
}
