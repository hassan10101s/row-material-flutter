import 'package:sqflite/sqflite.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/entity_registry.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/sync/sync_write.dart' as sync_write;
import '../../../core/utils/app_dates.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/lab_local_repository.dart';
import '../domain/lab_result_repository.dart';
import '../domain/product_batch_repository.dart';
import 'lab_repo.dart';

/// Offline-first facade over the local [LabRepo] (plan P5.2, P7.1).
///
/// Same arrangement as the inspections facade: the local repository keeps all of
/// its SQL, and this class is the seam that owns the V2 write contract:
///
/// * the local write, its `sync_queue` row and its `audit_logs` outbox row
///   commit in **one** SQLite transaction, and
/// * the local guards of §9.4 (session / permission / read-only / online-only)
///   run before the write is attempted.
///
/// It extends [LabRepo] so the lab cubits and widgets keep their current
/// dependency type: GetIt registers this class under the name `LabRepo`, so no
/// presentation file had to change.
///
/// Plan §6.3: lab results + lab configuration replicate; inventory, consumption
/// and the worksheet stay device-local but are still guarded.
class OfflineFirstLabRepository extends LabRepo
    implements
        LabResultRepository,
        LabLocalRepository,
        LabConfigurationRepository,
        ProductBatchRepository {
  OfflineFirstLabRepository({
    required super.dbHelper,
    required this.guard,
    required this.queue,
    required this.audit,
  });

  final WriteGuard guard;
  final SyncQueue queue;
  final AuditLogger audit;

  static final SyncEntity _labResult = syncEntities.firstWhere(
    (e) => e.type == 'labResult',
  );
  static final SyncEntity _labProduct = syncEntities.firstWhere(
    (e) => e.type == 'labProduct',
  );
  static final SyncEntity _labAnalysis = syncEntities.firstWhere(
    (e) => e.type == 'labAnalysis',
  );
  static final SyncEntity _labConstant = syncEntities.firstWhere(
    (e) => e.type == 'labConstant',
  );
  static final SyncEntity _labAnalysisItem = syncEntities.firstWhere(
    (e) => e.type == 'labAnalysisItem',
  );
  static final SyncEntity _labFieldLink = syncEntities.firstWhere(
    (e) => e.type == 'labFieldLink',
  );
  static final SyncEntity _labProductAnalysis = syncEntities.firstWhere(
    (e) => e.type == 'labProductAnalysis',
  );
  static final SyncEntity _productBatchSample = syncEntities.firstWhere(
    (e) => e.type == 'productBatchSample',
  );
  static SyncEntity _entity(String type) =>
      SyncEntity.byType(type) ??
      (throw StateError('Unknown sync entity: $type'));

  /// Resolve the local numeric user id used by SQLite.  The authenticated
  /// user id is normally a Firebase UID (text), while the legacy tables use
  /// the local `users.id` (integer).  Passing the UID into an INTEGER column
  /// makes the write succeed on some SQLite builds and fail on others.
  Future<int?> _resolveUserId(
    DatabaseExecutor txn,
    Map<String, dynamic>? user,
  ) async {
    if (user == null) return null;
    final rawId = user['local_id'] ?? user['user_id'] ?? user['id'];
    final numeric = rawId is num ? rawId.toInt() : int.tryParse('$rawId');
    if (numeric != null) return numeric;
    final uid = '${user['uid'] ?? ''}'.trim();
    final name =
        '${user['full_name'] ?? user['fullName'] ?? user['username'] ?? ''}'
            .trim();
    try {
      final rows = await txn.query(
        'users',
        columns: ['id'],
        where: uid.isNotEmpty ? 'uid = ?' : 'full_name = ?',
        whereArgs: [uid.isNotEmpty ? uid : name],
        limit: 1,
      );
      return rows.isEmpty ? null : (rows.first['id'] as num?)?.toInt();
    } on Object {
      return null;
    }
  }

  Future<T> _inTransaction<T>(
    DatabaseExecutor? executor,
    Future<T> Function(DatabaseExecutor txn) action,
  ) async {
    if (executor != null) return action(executor);
    final db = await dbHelper.database;
    return db.transaction(action);
  }

  /// Stamps `remote_id` on a freshly written row (UUID for new rows).
  /// Missing column on legacy files is ignored — the migration backfills it
  /// on the next open.
  Future<Map<String, dynamic>> _withRemoteId(
    DatabaseExecutor txn,
    String table,
    Map<String, dynamic> row,
  ) async {
    final mutable = Map<String, dynamic>.from(row);
    if ('${mutable['remote_id'] ?? ''}'.isNotEmpty) return mutable;
    mutable['remote_id'] = sync_write.newRemoteId();
    try {
      await txn.update(
        table,
        {'remote_id': mutable['remote_id']},
        where: 'id = ?',
        whereArgs: [mutable['id']],
      );
    } on Object {
      // Column absent until the next open runs the migration.
    }
    return mutable;
  }

  /// Replicates the parent's `last_calibration_date` bump that rides along
  /// with calibration events. The base repo bumps the master row locally;
  /// without this the event syncs but other devices keep the old date.
  Future<void> _enqueueEquipmentParent(
    DatabaseExecutor txn,
    int equipmentId,
  ) async {
    try {
      final rows = await txn.query(
        'lab_equipment',
        where: 'id = ?',
        whereArgs: [equipmentId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final stamped =
          await _withRemoteId(txn, 'lab_equipment', rows.first);
      await _enqueue(
        txn,
        'equipment',
        stamped,
        'update',
        AuditAction.settingsUpdated,
      );
    } on Object {
      // Parent replication is best-effort; the event itself already queued.
    }
  }
  /// Links an event row to its parent's cross-device identity and stamps the
  /// row. The pull remaps `equipment_id` through this value, so an event
  /// created offline still lands on the right equipment on other devices.
  Future<Map<String, dynamic>> _withEquipmentParent(
    DatabaseExecutor txn,
    Map<String, dynamic> event,
  ) async {
    final mutable = Map<String, dynamic>.from(event);
    try {
      final parentId = (mutable['equipment_id'] as num?)?.toInt();
      if (parentId != null) {
        final parent = await txn.query(
          'lab_equipment',
          columns: const ['id', 'remote_id'],
          where: 'id = ?',
          whereArgs: [parentId],
          limit: 1,
        );
        if (parent.isNotEmpty) {
          var parentRow = Map<String, dynamic>.from(parent.first);
          if ('${parentRow['remote_id'] ?? ''}'.isEmpty) {
            parentRow = await _withRemoteId(txn, 'lab_equipment', parentRow);
          }
          final parentRemote = '${parentRow['remote_id'] ?? ''}';
          if (parentRemote.isNotEmpty &&
              '${mutable['equipment_remote_id'] ?? ''}' != parentRemote) {
            mutable['equipment_remote_id'] = parentRemote;
            await txn.update(
              'lab_equipment_events',
              {'equipment_remote_id': parentRemote},
              where: 'id = ?',
              whereArgs: [mutable['id']],
            );
          }
        }
      }
    } on Object {
      // Link stamp is best-effort; the raw FK still applies locally.
    }
    return mutable;
  }

  Future<void> _enqueue(
    DatabaseExecutor txn,
    String entityType,
    Map<String, dynamic> row,
    String operation,
    String auditAction,
  ) async {
    try {
      await sync_write.enqueueLocalChange(
        executor: txn,
        entity: _entity(entityType),
        row: row,
        operation: operation,
        queue: queue,
        audit: audit,
        auditAction: auditAction,
        organizationId: guard.organizationId,
        uid: guard.uid,
        deviceId: guard.deviceId,
      );
    } on Object catch (e) {
      // Sync must never fail the local write: stamp the row so the next
      // cycle or a manual retry can pick it up.
      try {
        await txn.update(
          _entity(entityType).localTable,
          {'sync_state': 'queued'},
          where: 'id = ?',
          whereArgs: [(row['id'] as num?)?.toInt()],
        );
      } on Object {
        // Row stamp is best-effort too.
      }
      await audit.log(
        txn,
        action: AuditAction.syncConflict,
        entityType: entityType,
        entityId: '$e',
        details: {'localId': row['id'], 'error': '$e'},
      );
    }
  }

  /// Inserts one append-only ledger row + enqueues it (plan §4).
  /// Every inventory mutation (receipt/adjustment/consumption/reversal)
  /// funnels through here inside the business transaction.
  Future<Map<String, dynamic>> _recordInventoryTransaction(
    DatabaseExecutor txn, {
    required int inventoryId,
    required double quantityDelta,
    required String transactionType,
    String? referenceType,
    int? referenceId,
    String? referenceRemoteId,
    String reason = '',
    int? createdBy,
  }) async {
    final now = nowIso();
    final remoteId = sync_write.newRemoteId();
    String? inventoryRemoteId;
    try {
      final inv = await txn.query(
        'lab_inventory',
        columns: ['remote_id'],
        where: 'id = ?',
        whereArgs: [inventoryId],
        limit: 1,
      );
      if (inv.isNotEmpty) inventoryRemoteId = '${inv.first['remote_id'] ?? ''}';
    } on Object {
      inventoryRemoteId = null;
    }
    final id = await txn.rawInsert(
      'INSERT INTO inventory_transactions (remote_id, inventory_id, '
      'inventory_remote_id, quantity_delta, transaction_type, reference_type, '
      'reference_id, reference_remote_id, reason, created_by, created_at, '
      'updated_at, device_id, version, sync_state) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)',
      [
        remoteId,
        inventoryId,
        inventoryRemoteId,
        quantityDelta,
        transactionType,
        referenceType,
        referenceId,
        referenceRemoteId,
        reason,
        createdBy,
        now,
        now,
        guard.deviceId,
        'queued',
      ],
    );
    final rows = await txn.query(
      'inventory_transactions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final txnRow = Map<String, dynamic>.from(rows.first);
    await _enqueue(
      txn,
      'inventoryTransaction',
      txnRow,
      'create',
      AuditAction.settingsUpdated,
    );
    return txnRow;
  }

  // ── Inventory (synced + ledger-mirrored, plan §4+§5) ──

  @override
  Future<Map<String, dynamic>> addInventoryItem({
    required String name,
    required String category,
    required String unit,
    required double qty,
    required double minQty,
    String description = '',
    Map<String, dynamic>? user,
    DatabaseExecutor? executor,
  }) async {
    _check(Permission.labResultsUpdate);
    return _inTransaction(executor, (txn) async {
      final item = await super.addInventoryItem(
        name: name,
        category: category,
        unit: unit,
        qty: qty,
        minQty: minQty,
        description: description,
        user: user,
        executor: txn,
      );
      var stamped = await _withRemoteId(txn, 'lab_inventory', item);
      await _enqueue(
        txn,
        'inventoryItem',
        stamped,
        'create',
        AuditAction.settingsUpdated,
      );
      // Opening balance ledger row (plan §4): the truth for cross-device
      // balance, `current_qty` stays as the local cache.
      final opening = (stamped['current_qty'] as num?)?.toDouble() ?? 0.0;
      final createdBy = await _resolveUserId(txn, user);
      if (opening != 0) {
        await _recordInventoryTransaction(
          txn,
          inventoryId: (stamped['id'] as num).toInt(),
          quantityDelta: opening,
          transactionType: 'OPENING_BALANCE',
          reason: 'Opening balance for ${stamped['name']}',
          createdBy: createdBy,
        );
      }
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'inventoryItem',
        entityId: 'inv_${item['id']}',
        details: {
          'localId': item['id'],
          'name': item['name'],
          'category': category,
          'openingQty': qty,
        },
      );
      return stamped;
    });
  }

  @override
  Future<Map<String, dynamic>> updateInventoryItem(
    int itemId,
    Map<String, dynamic> fields, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    return _inTransaction(executor, (txn) async {
      final item = await super.updateInventoryItem(itemId, fields, txn);
      var stamped = await _withRemoteId(txn, 'lab_inventory', item);
      await _enqueue(
        txn,
        'inventoryItem',
        stamped,
        'update',
        AuditAction.settingsUpdated,
      );
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'inventoryItem',
        entityId: 'inv_$itemId',
        details: {'localId': itemId, 'fields': fields.keys.toList()},
      );
      return stamped;
    });
  }

  @override
  Future<Map<String, dynamic>> adjustStock({
    required int itemId,
    double? newQty,
    String reason = '',
    Map<String, dynamic>? user,
    double? deltaQty,
    DatabaseExecutor? executor,
  }) async {
    _check(Permission.labResultsUpdate);
    return _inTransaction(executor, (txn) async {
      final before = await super.getInventoryItem(itemId, txn);
      final item = await super.adjustStock(
        itemId: itemId,
        newQty: newQty,
        reason: reason,
        user: user,
        deltaQty: deltaQty,
        executor: txn,
      );
      var stamped = await _withRemoteId(txn, 'lab_inventory', item);
      final beforeQty = (before['current_qty'] as num?)?.toDouble() ?? 0.0;
      final afterQty = (stamped['current_qty'] as num?)?.toDouble() ?? 0.0;
      final delta = afterQty - beforeQty;
      final createdBy = await _resolveUserId(txn, user);
      await _enqueue(
        txn,
        'inventoryItem',
        stamped,
        'update',
        AuditAction.settingsUpdated,
      );
      if (delta != 0) {
        // Mirror into the detail table (kept for history UI) + unified
        // ledger (the sync truth). Both inside the same txn.
        try {
          final adjId = await txn.rawInsert(
            'INSERT INTO lab_stock_adjustments (inventory_id, old_qty, '
            'new_qty, reason, adjusted_by, adjusted_at, remote_id) '
            'VALUES (?, ?, ?, ?, ?, ?, ?)',
            [
              itemId,
              beforeQty,
              afterQty,
              reason,
              createdBy,
              nowIso(),
              sync_write.newRemoteId(),
            ],
          );
          final adjRows = await txn.query(
            'lab_stock_adjustments',
            where: 'id = ?',
            whereArgs: [adjId],
            limit: 1,
          );
          if (adjRows.isNotEmpty) {
            await _enqueue(
              txn,
              'stockAdjustment',
              Map<String, dynamic>.from(adjRows.first),
              'create',
              AuditAction.settingsUpdated,
            );
          }
        } on Object {
          // Detail mirror is best-effort; the ledger below is the truth.
        }
        await _recordInventoryTransaction(
          txn,
          inventoryId: itemId,
          quantityDelta: delta,
          transactionType: deltaQty != null ? 'RECEIPT' : 'ADJUSTMENT',
          reason: reason,
          createdBy: createdBy,
        );
      }
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'inventoryItem',
        entityId: 'inv_$itemId',
        details: {
          'localId': itemId,
          'newQty': item['current_qty'],
          'reason': reason,
          'delta': deltaQty,
        },
      );
      return stamped;
    });
  }

  // ── Equipment (synced registry, plan §8) ──

  @override
  Future<Map<String, dynamic>> createEquipment({
    required String name,
    String manufacturer = '',
    String description = '',
    String lastCalibrationDate = '',
    DatabaseExecutor? executor,
  }) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final item = await super.createEquipment(
        name: name,
        manufacturer: manufacturer,
        description: description,
        lastCalibrationDate: lastCalibrationDate,
        executor: txn,
      );
      var stamped = await _withRemoteId(txn, 'lab_equipment', item);
      await _enqueue(
        txn,
        'equipment',
        stamped,
        'create',
        AuditAction.settingsUpdated,
      );
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipment',
        entityId: 'eq_${item['id']}',
        details: {'localId': item['id'], 'name': item['name']},
      );
      return stamped;
    });
  }

  @override
  Future<Map<String, dynamic>> updateEquipment(
    int equipmentId,
    Map<String, dynamic> fields, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final item = await super.updateEquipment(equipmentId, fields, txn);
      var stamped = await _withRemoteId(txn, 'lab_equipment', item);
      await _enqueue(
        txn,
        'equipment',
        stamped,
        'update',
        AuditAction.settingsUpdated,
      );
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipment',
        entityId: 'eq_$equipmentId',
        details: {'localId': equipmentId, 'fields': fields.keys.toList()},
      );
      return stamped;
    });
  }

  @override
  Future<void> deleteEquipment(
    int equipmentId, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'lab_equipment',
        where: 'id = ?',
        whereArgs: [equipmentId],
        limit: 1,
      );
      await super.deleteEquipment(equipmentId, txn);
      // Tombstone, never a hard remote delete (plan §8).
      if (existing.isNotEmpty) {
        final row = Map<String, dynamic>.from(existing.first)
          ..['deleted_at'] = nowIso();
        await _enqueue(
          txn,
          'equipment',
          row,
          'tombstone',
          AuditAction.settingsUpdated,
        );
      }
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipment',
        entityId: 'eq_$equipmentId',
        details: {'localId': equipmentId, 'operation': 'delete'},
      );
    });
  }

  @override
  Future<Map<String, dynamic>> addEquipmentEvent({
    required int equipmentId,
    required String eventType,
    required String eventDate,
    String notes = '',
    DatabaseExecutor? executor,
  }) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final event = await super.addEquipmentEvent(
        equipmentId: equipmentId,
        eventType: eventType,
        eventDate: eventDate,
        notes: notes,
        executor: txn,
      );
      var stamped = await _withRemoteId(txn, 'lab_equipment_events', event);
      stamped = await _withEquipmentParent(txn, stamped);
      await _enqueue(
        txn,
        'equipmentEvent',
        stamped,
        'create',
        AuditAction.settingsUpdated,
      );
      // Calibration events also bump the master's `last_calibration_date`
      // locally — replicate the parent so other devices show the new date.
      if (LabRepo.normalizeEquipmentEventType(eventType) ==
          LabRepo.equipmentEventCalibration) {
        await _enqueueEquipmentParent(txn, equipmentId);
      }
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipmentEvent',
        entityId: 'eqev_${event['id']}',
        details: {'localId': event['id'], 'equipmentId': equipmentId},
      );
      return stamped;
    });
  }

  @override
  Future<Map<String, dynamic>> updateEquipmentEvent(
    int eventId,
    Map<String, dynamic> fields, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final event = await super.updateEquipmentEvent(eventId, fields, txn);
      var stamped = await _withRemoteId(txn, 'lab_equipment_events', event);
      stamped = await _withEquipmentParent(txn, stamped);
      // Corrections replicate as versioned updates of the same document
      // (rules enforce the +1 version bump), never a rewrite of history.
      await _enqueue(
        txn,
        'equipmentEvent',
        stamped,
        'update',
        AuditAction.settingsUpdated,
      );
      // A correction that touches a calibration event may have moved the
      // master's `last_calibration_date` — replicate the parent as well.
      final touchedType = fields.containsKey('event_type')
          ? LabRepo.normalizeEquipmentEventType(fields['event_type'])
          : '${stamped['event_type'] ?? ''}';
      if (touchedType == LabRepo.equipmentEventCalibration) {
        final parentId = (stamped['equipment_id'] as num?)?.toInt();
        if (parentId != null) await _enqueueEquipmentParent(txn, parentId);
      }
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipmentEvent',
        entityId: 'eqev_$eventId',
        details: {'localId': eventId, 'fields': fields.keys.toList()},
      );
      return stamped;
    });
  }

  @override
  Future<void> deleteEquipmentEvent(
    int eventId, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'lab_equipment_events',
        where: 'id = ?',
        whereArgs: [eventId],
        limit: 1,
      );
      await super.deleteEquipmentEvent(eventId, txn);
      if (existing.isNotEmpty) {
        final row = Map<String, dynamic>.from(existing.first)
          ..['deleted_at'] = nowIso();
        final linked = await _withEquipmentParent(txn, row);
        await _enqueue(
          txn,
          'equipmentEvent',
          linked,
          'tombstone',
          AuditAction.settingsUpdated,
        );
      }
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipmentEvent',
        entityId: 'eqev_$eventId',
        details: {'localId': eventId, 'operation': 'delete'},
      );
    });
  }

  // ── §9.4 writes: Products ──────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> createProduct({
    required String name,
    String category = '',
    String description = '',
    List<Map<String, dynamic>>? ranges,
    Map<String, dynamic>? physicalReference,
    Map<String, dynamic>? chemicalReference,
    Map<String, dynamic>? user,
    DatabaseExecutor? executor,
  }) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    late final Map<String, dynamic> product;
    await db.transaction((txn) async {
      product = await super.createProduct(
        name: name,
        category: category,
        description: description,
        ranges: ranges,
        physicalReference: physicalReference,
        chemicalReference: chemicalReference,
        user: user,
        executor: txn,
      );
      final id = (product['id'] as num?)?.toInt();
      if (id != null) {
        await _enqueueConfig(
          txn,
          entity: _labProduct,
          table: 'lab_products',
          localId: id,
          operation: 'create',
          action: AuditAction.settingsUpdated,
          details: {
            'localId': id,
            'productName': product['name'],
            'rangesCount': ranges?.length ?? 0,
          },
        );
        if ((ranges != null && ranges.isNotEmpty) ||
            (chemicalReference != null && chemicalReference.isNotEmpty)) {
          await _refreshRangesForProduct(txn, id);
        }
      }
    });
    return product;
  }

  @override
  Future<Map<String, dynamic>> updateProduct(
    int productId,
    Map<String, dynamic> fields, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    late final Map<String, dynamic> product;
    await db.transaction((txn) async {
      product = await super.updateProduct(productId, fields, txn);
      await _enqueueConfig(
        txn,
        entity: _labProduct,
        table: 'lab_products',
        localId: productId,
        operation: 'update',
        action: AuditAction.settingsUpdated,
        details: {'localId': productId, 'fields': fields.keys.toList()},
      );
      if (fields.containsKey('ranges') ||
          fields.containsKey('chemical_reference')) {
        await _refreshRangesForProduct(txn, productId);
      }
    });
    return product;
  }

  @override
  Future<Map<String, dynamic>> deleteProduct(
    int productId, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final result = await super.deleteProduct(productId, txn);
      await _enqueueConfig(
        txn,
        entity: _labProduct,
        table: 'lab_products',
        localId: productId,
        operation: 'tombstone',
        action: AuditAction.settingsUpdated,
        details: {'localId': productId},
      );
      return result;
    });
  }

  @override
  Future<Map<String, dynamic>> saveMaterialBounds(
    int materialId,
    List<Map<String, dynamic>>? specs, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final result = await super.saveMaterialBounds(materialId, specs, txn);
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'materialParameterBounds',
        entityId: 'mat_bounds_$materialId',
        details: {'materialId': materialId, 'saved': result['saved']},
      );
      return result;
    });
  }

  /// Derive the canonical reference (parameters, per-material bounds and linked
  /// analyses) from the materials themselves. Local-only, like the reference,
  /// and deliberately role-agnostic (mirrors `ensureDefaultAnalyses`, which
  /// also runs during organization bootstrap).
  @override
  Future<Map<String, dynamic>> syncReferenceAnalyses([
    DatabaseExecutor? executor,
  ]) async {
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final result = await super.syncReferenceAnalyses(txn);
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'referenceAnalyses',
        entityId: 'sync_reference_analyses',
        details: {
          'materials': result['materials'],
          'parameters': result['parameters'],
          'bounds': result['bounds'],
          'analyses': result['analyses'],
          'linked': result['linked'],
        },
      );
      return result;
    });
  }

  // ── Worksheets + consumption mirror (plan §5+§7) ──

  @override
  Future<Map<String, dynamic>> saveWorksheet(
    List<Map<String, dynamic>> rows,
    Map<String, dynamic>? user, {
    DatabaseExecutor? exec,
  }) async {
    if (exec != null) {
      return super.saveWorksheet(rows, user, exec: exec);
    }
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    final startedAt = nowIso();
    return db.transaction((txn) async {
      final result = await super.saveWorksheet(rows, user, exec: txn);
      await _mirrorWorksheetSync(txn, result, user, since: startedAt);
      return result;
    });
  }

  /// Post-pass after a worksheet save: stamps `remote_id` on touched rows,
  /// enqueues worksheet/consumption/result entities and mirrors every
  /// consumption delta into `inventory_transactions` (plan §5).
  Future<void> _mirrorWorksheetSync(
    DatabaseExecutor txn,
    Map<String, dynamic> result,
    Map<String, dynamic>? user, {
    required String since,
  }) async {
    // Worksheet rows.
    try {
      final wsRows = await txn.query(
        'lab_worksheet',
        where: 'updated_at >= ? OR created_at >= ?',
        whereArgs: [since, since],
        orderBy: 'id DESC',
      );
      for (final r in wsRows) {
        final row = Map<String, dynamic>.from(r);
        if ('${row['remote_id'] ?? ''}'.isEmpty) {
          row['remote_id'] = sync_write.newRemoteId();
          try {
            await txn.update(
              'lab_worksheet',
              {'remote_id': row['remote_id']},
              where: 'id = ?',
              whereArgs: [row['id']],
            );
          } on Object {
            break;
          }
        }
        final status = '${row['status'] ?? 'ACTIVE'}';
        await _enqueue(
          txn,
          'worksheet',
          row,
          status == 'VOIDED' ? 'tombstone' : 'update',
          AuditAction.labResultSaved,
        );
      }
    } on Object {
      // Worksheet mirror is best-effort.
    }
    // Consumption deltas reported by the save.
    final consumption = (result['consumption'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    // The detail rows were written via batch inside the save; fetch the
    // newest ones and mirror them (idempotent: only rows without remote_id
    // get a ledger entry — re-saves of the same test produce new detail
    // rows, each mirrored exactly once).
    try {
      final detailRows = await txn.rawQuery(
        'SELECT * FROM lab_consumption_log '
        'WHERE (remote_id IS NULL OR remote_id = ?) AND created_at >= ? '
        'ORDER BY id DESC',
        ['', since],
      );
      final createdBy = await _resolveUserId(txn, user);
      for (final d in detailRows) {
        final row = Map<String, dynamic>.from(d);
        row['remote_id'] = sync_write.newRemoteId();
        try {
          await txn.update(
            'lab_consumption_log',
            {'remote_id': row['remote_id']},
            where: 'id = ?',
            whereArgs: [row['id']],
          );
        } on Object {
          break;
        }
        await _enqueue(
          txn,
          'consumption',
          row,
          'create',
          AuditAction.labResultSaved,
        );
        await _recordInventoryTransaction(
          txn,
          inventoryId: (row['inventory_id'] as num).toInt(),
          quantityDelta: '${row['event_type'] ?? 'CONSUMPTION'}' == 'REVERSAL'
              ? ((row['applied_qty'] as num?)?.toDouble() ??
                        (row['qty_used'] as num?)?.toDouble() ??
                        0.0)
                    .abs()
              : -((row['applied_qty'] as num?)?.toDouble() ??
                        ((row['qty_used'] as num?)?.toDouble() ?? 0.0))
                    .abs(),
          transactionType: '${row['event_type'] ?? 'CONSUMPTION'}' == 'REVERSAL'
              ? 'REVERSAL'
              : 'CONSUMPTION',
          referenceType: 'sample_test',
          referenceId: (row['sample_test_id'] as num?)?.toInt(),
          reason: 'Worksheet consumption',
          createdBy: createdBy,
        );
      }
    } on Object {
      // Consumption mirror is best-effort; `current_qty` was already updated.
    }
    for (final _ in consumption) {
      // `consumption` list is informational; ledger rows above are the truth.
    }
  }

  /// Voids a worksheet: tombstones the header, reverses its consumption via
  /// `REVERSAL` ledger rows and restores the cached quantities (plan §5).
  Future<void> voidWorksheet({
    required int worksheetId,
    String reason = '',
    Map<String, dynamic>? user,
  }) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final createdBy = await _resolveUserId(txn, user);
      final now = nowIso();
      await txn.update(
        'lab_worksheet',
        {
          'status': 'VOIDED',
          'void_reason': reason,
          'voided_by': createdBy,
          'voided_at': now,
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [worksheetId],
      );
      // Reverse every consumption linked to this worksheet's tests.
      final tests = await txn.query(
        'lab_sample_tests',
        columns: ['id'],
        where: 'worksheet_row_id = ?',
        whereArgs: [worksheetId],
      );
      for (final t in tests) {
        final testId = (t['id'] as num).toInt();
        final logs = await txn.query(
          'lab_consumption_log',
          where: 'sample_test_id = ?',
          whereArgs: [testId],
        );
        for (final l in logs) {
          final log = Map<String, dynamic>.from(l);
          final applied =
              ((log['applied_qty'] as num?)?.toDouble() ??
                      ((log['qty_used'] as num?)?.toDouble() ?? 0.0))
                  .abs();
          if (applied <= 0) continue;
          await _recordInventoryTransaction(
            txn,
            inventoryId: (log['inventory_id'] as num).toInt(),
            quantityDelta: applied,
            transactionType: 'REVERSAL',
            referenceType: 'sample_test',
            referenceId: testId,
            reason: reason.isEmpty ? 'Worksheet voided' : reason,
            createdBy: createdBy,
          );
          try {
            final inv = await txn.query(
              'lab_inventory',
              columns: ['current_qty'],
              where: 'id = ?',
              whereArgs: [log['inventory_id']],
              limit: 1,
            );
            if (inv.isNotEmpty) {
              final cur = ((inv.first['current_qty'] as num?)?.toDouble() ?? 0);
              await txn.update(
                'lab_inventory',
                {'current_qty': cur + applied, 'updated_at': now},
                where: 'id = ?',
                whereArgs: [log['inventory_id']],
              );
            }
          } on Object {
            // Cache restore is best-effort; the ledger is the truth.
          }
        }
      }
      final header = await txn.query(
        'lab_worksheet',
        where: 'id = ?',
        whereArgs: [worksheetId],
        limit: 1,
      );
      if (header.isNotEmpty) {
        await _enqueue(
          txn,
          'worksheet',
          Map<String, dynamic>.from(header.first),
          'tombstone',
          AuditAction.labResultSaved,
        );
      }
    });
  }

  /// Recomputes and stores the cached `current_qty` from the ledger truth.
  Future<double> recomputeInventoryBalance(int inventoryId) async {
    final db = await dbHelper.database;
    final balance = await sync_write.recomputeBalance(db, inventoryId);
    try {
      await db.update(
        'lab_inventory',
        {'current_qty': balance, 'updated_at': nowIso()},
        where: 'id = ?',
        whereArgs: [inventoryId],
      );
    } on Object {
      // Cache write is best-effort.
    }
    return balance;
  }

  // ── §9.4 writes: Analyses ─────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> createAnalysis({
    required String name,
    String description = '',
    List<String>? dynamicFields,
    List<Map<String, dynamic>>? items,
    String unit = '%',
    int? parameterId,
    Object? formula,
    List<Map<String, dynamic>>? fieldChemicalLinks,
    DatabaseExecutor? executor,
  }) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    late final Map<String, dynamic> analysis;
    await db.transaction((txn) async {
      analysis = await super.createAnalysis(
        name: name,
        description: description,
        dynamicFields: dynamicFields,
        items: items,
        unit: unit,
        parameterId: parameterId,
        formula: formula,
        fieldChemicalLinks: fieldChemicalLinks,
        executor: txn,
      );
      final id = (analysis['id'] as num?)?.toInt();
      if (id != null) {
        await _enqueueConfig(
          txn,
          entity: _labAnalysis,
          table: 'lab_analyses',
          localId: id,
          operation: 'create',
          action: AuditAction.settingsUpdated,
          details: {'localId': id, 'analysisName': analysis['name']},
        );
        await _refreshAnalysisChildren(txn, id);
      }
    });
    return analysis;
  }

  @override
  Future<Map<String, dynamic>> updateAnalysis({
    required int analysisId,
    String? name,
    String? description,
    List<String>? dynamicFields,
    List<Map<String, dynamic>>? items,
    String? unit,
    int? parameterId,
    bool clearParameter = false,
    Object? formula,
    List<Map<String, dynamic>>? fieldChemicalLinks,
    DatabaseExecutor? executor,
  }) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final analysis = await super.updateAnalysis(
        analysisId: analysisId,
        name: name,
        description: description,
        dynamicFields: dynamicFields,
        items: items,
        unit: unit,
        parameterId: parameterId,
        clearParameter: clearParameter,
        formula: formula,
        fieldChemicalLinks: fieldChemicalLinks,
        executor: txn,
      );
      await _enqueueConfig(
        txn,
        entity: _labAnalysis,
        table: 'lab_analyses',
        localId: analysisId,
        operation: 'update',
        action: AuditAction.settingsUpdated,
        details: {'localId': analysisId},
      );
      if (items != null || fieldChemicalLinks != null) {
        await _refreshAnalysisChildren(txn, analysisId);
      }
      return analysis;
    });
  }

  @override
  Future<Map<String, dynamic>> deleteAnalysis(
    int analysisId, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final result = await super.deleteAnalysis(analysisId, txn);
      await _enqueueConfig(
        txn,
        entity: _labAnalysis,
        table: 'lab_analyses',
        localId: analysisId,
        operation: 'tombstone',
        action: AuditAction.settingsUpdated,
        details: {'localId': analysisId},
      );
      return result;
    });
  }

  // ── §9.4 writes: Constants ────────────────────────────────────────

  @override
  Future<Map<String, dynamic>> upsertGlobalConstant(
    Map<String, dynamic> payload, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final row = await super.upsertGlobalConstant(payload, txn);
      final id = (row['id'] as num?)?.toInt();
      if (id != null) {
        await _enqueueConfig(
          txn,
          entity: _labConstant,
          table: 'lab_constants',
          localId: id,
          operation: 'upsert',
          action: AuditAction.settingsUpdated,
          details: {
            'localId': id,
            'name': row['name'],
            'symbol': row['symbol'],
          },
        );
      }
      return row;
    });
  }

  @override
  Future<Map<String, dynamic>> deleteGlobalConstant(
    int constantId, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final result = await super.deleteGlobalConstant(constantId, txn);
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: _labConstant.type,
        entityId: 'lc_lab_constants_$constantId',
        details: {'localId': constantId, 'operation': 'delete'},
      );
      return result;
    });
  }

  // ── §9.4 writes: Lab results (kept from V1) ───────────────────────

  /// `lab_results.create` - a lab technician saves a test result.
  @override
  Future<Map<String, dynamic>> runSampleTest({
    required int analysisId,
    required String sourceType,
    int? sourceRefId,
    required String sourceName,
    required String sampleName,
    String resultText = '',
    Map<String, dynamic>? dynamicValues,
    Map<String, dynamic>? user,
    String entryCode = '',
    bool manualResult = false,
    bool keepSourceRefId = false,
    DatabaseExecutor? exec,
  }) async {
    if (exec != null) {
      return super.runSampleTest(
        analysisId: analysisId,
        sourceType: sourceType,
        sourceRefId: sourceRefId,
        sourceName: sourceName,
        sampleName: sampleName,
        resultText: resultText,
        dynamicValues: dynamicValues,
        user: user,
        entryCode: entryCode,
        manualResult: manualResult,
        keepSourceRefId: keepSourceRefId,
        exec: exec,
      );
    }
    _check(Permission.labResultsCreate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final result = await super.runSampleTest(
        analysisId: analysisId,
        sourceType: sourceType,
        sourceRefId: sourceRefId,
        sourceName: sourceName,
        sampleName: sampleName,
        resultText: resultText,
        dynamicValues: dynamicValues,
        user: user,
        entryCode: entryCode,
        manualResult: manualResult,
        keepSourceRefId: keepSourceRefId,
        exec: txn,
      );
      await _enqueueResult(txn, result['test'] as Map<String, dynamic>?);
      return result;
    });
  }

  /// `lab_results.update` - editing the fillable fields of a saved test.
  @override
  Future<Map<String, dynamic>> updateSampleTest(
    int testId, {
    String? sampleName,
    String? resultText,
    Map<String, dynamic>? dynamicValues,
    String? entryCode,
    Map<String, dynamic>? user,
    DatabaseExecutor? executor,
  }) async {
    if (executor != null) {
      return super.updateSampleTest(
        testId,
        sampleName: sampleName,
        resultText: resultText,
        dynamicValues: dynamicValues,
        entryCode: entryCode,
        user: user,
        executor: executor,
      );
    }
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final result = await super.updateSampleTest(
        testId,
        sampleName: sampleName,
        resultText: resultText,
        dynamicValues: dynamicValues,
        entryCode: entryCode,
        user: user,
        executor: txn,
      );
      await _enqueueResult(txn, result);
      return result;
    });
  }

  @override
  Future<void> deleteSampleTest(
    int testId, {
    Map<String, dynamic>? user,
    DatabaseExecutor? executor,
  }) async {
    if (executor != null) {
      return super.deleteSampleTest(testId, executor: executor, user: user);
    }
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'lab_sample_tests',
        where: 'id = ?',
        whereArgs: [testId],
        limit: 1,
      );
      if (rows.isEmpty) throw NotFoundError(AppErrors.testNotFound);
      final snapshot = Map<String, dynamic>.from(rows.first);
      final remoteVersion = (snapshot['remote_version'] as num?)?.toInt() ?? 0;
      final localVersion = (snapshot['version'] as num?)?.toInt() ?? 0;
      final version = remoteVersion == 0
          ? 1
          : (localVersion > remoteVersion ? localVersion : remoteVersion) + 1;
      final tombstone = Map<String, dynamic>.from(snapshot)
        ..['version'] = version
        ..['sync_state'] = 'queued'
        ..['deleted_at'] = DateTime.now().toIso8601String();
      final ctx = SyncPayloadContext(
        organizationId: guard.organizationId,
        uid: guard.uid,
        deviceId: guard.deviceId,
        version: version,
        versionField: 'version',
      );
      await queue.enqueue(
        txn,
        entityType: _labResult.type,
        entityId: _labResult.docId(snapshot),
        localRef: testId,
        operation: 'tombstone',
        payload: buildRemotePayload(_labResult, tombstone, ctx, asCreate: true),
        baseVersion: remoteVersion,
      );
      // Plan §5: deleting a result reverses its consumption via REVERSAL
      // ledger rows. The original consumption rows are kept for history.
      final logs = await txn.query(
        'lab_consumption_log',
        where: 'sample_test_id = ?',
        whereArgs: [testId],
      );
      for (final l in logs) {
        final applied =
            ((l['applied_qty'] as num?)?.toDouble() ??
                    ((l['qty_used'] as num?)?.toDouble() ?? 0.0))
                .abs();
        if (applied <= 0) continue;
        await _recordInventoryTransaction(
          txn,
          inventoryId: (l['inventory_id'] as num).toInt(),
          quantityDelta: applied,
          transactionType: 'REVERSAL',
          referenceType: 'sample_test',
          referenceId: testId,
          reason: 'Result deleted',
          createdBy: user?['id'] as int?,
        );
        try {
          final inv = await txn.query(
            'lab_inventory',
            columns: ['current_qty'],
            where: 'id = ?',
            whereArgs: [l['inventory_id']],
            limit: 1,
          );
          if (inv.isNotEmpty) {
            final cur = ((inv.first['current_qty'] as num?)?.toDouble() ?? 0);
            await txn.update(
              'lab_inventory',
              {'current_qty': cur + applied},
              where: 'id = ?',
              whereArgs: [l['inventory_id']],
            );
          }
        } on Object {
          // Cache restore is best-effort; the ledger is the truth.
        }
      }
      await super.deleteSampleTest(testId, executor: txn, user: user);
      await audit.log(
        txn,
        action: AuditAction.labResultSaved,
        entityType: _labResult.type,
        entityId: _labResult.docId(snapshot),
        details: {
          'localId': testId,
          'operation': 'delete',
          'user': user?['id'],
        },
      );
    });
  }

  // ── Product batch samples (محضر التشغيلة rows) ──────────────────────
  //
  // Raw-material flow never calls these. Result rows keep flowing through
  // `runSampleTest`/`deleteSampleTest`, so consumption, audit and the
  // `labResult` sync path are reused untouched.

  @override
  Future<Map<String, dynamic>> addBatchSample({
    required int batchId,
    String? sampleName,
    String sampleTaker = '',
    Map<String, String> physicalResults = const {},
    List<Map<String, String>> chemicalResults = const [],
    Map<String, dynamic>? user,
    DatabaseExecutor? executor,
  }) async {
    if (executor != null) {
      return super.addBatchSample(
        batchId: batchId,
        sampleName: sampleName,
        sampleTaker: sampleTaker,
        physicalResults: physicalResults,
        chemicalResults: chemicalResults,
        user: user,
        executor: executor,
      );
    }
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    late final Map<String, dynamic> sample;
    await db.transaction((txn) async {
      sample = await super.addBatchSample(
        batchId: batchId,
        sampleName: sampleName,
        sampleTaker: sampleTaker,
        physicalResults: physicalResults,
        chemicalResults: chemicalResults,
        user: user,
        executor: txn,
      );
      final id = (sample['id'] as num?)?.toInt();
      if (id != null) {
        await _enqueueConfig(
          txn,
          entity: _productBatchSample,
          table: 'product_batch_samples',
          localId: id,
          operation: 'create',
          action: AuditAction.labResultSaved,
          details: {
            'localId': id,
            'batchId': batchId,
            'sampleNo': sample['sample_no'],
          },
        );
      }
    });
    return sample;
  }

  @override
  Future<void> updateBatchSample(
    int sampleId, {
    String? sampleName,
    String? sampleTaker,
    Map<String, String>? physicalResults,
    List<Map<String, String>>? chemicalResults,
    DatabaseExecutor? executor,
  }) async {
    if (executor != null) {
      return super.updateBatchSample(
        sampleId,
        sampleName: sampleName,
        sampleTaker: sampleTaker,
        physicalResults: physicalResults,
        chemicalResults: chemicalResults,
        executor: executor,
      );
    }
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await super.updateBatchSample(
        sampleId,
        sampleName: sampleName,
        sampleTaker: sampleTaker,
        physicalResults: physicalResults,
        chemicalResults: chemicalResults,
        executor: txn,
      );
      await _enqueueConfig(
        txn,
        entity: _productBatchSample,
        table: 'product_batch_samples',
        localId: sampleId,
        operation: 'update',
        action: AuditAction.labResultSaved,
        details: {'localId': sampleId},
      );
    });
  }

  @override
  Future<void> setBatchSampleDecision(
    int sampleId, {
    required String status,
    String reason = '',
    DatabaseExecutor? executor,
  }) async {
    if (executor != null) {
      return super.setBatchSampleDecision(
        sampleId,
        status: status,
        reason: reason,
        executor: executor,
      );
    }
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await super.setBatchSampleDecision(
        sampleId,
        status: status,
        reason: reason,
        executor: txn,
      );
      await _enqueueConfig(
        txn,
        entity: _productBatchSample,
        table: 'product_batch_samples',
        localId: sampleId,
        operation: 'update',
        action: AuditAction.labResultSaved,
        details: {'localId': sampleId, 'status': status},
      );
    });
  }

  @override
  Future<void> deleteBatchSample(
    int sampleId, [
    DatabaseExecutor? executor,
    Map<String, dynamic>? user,
  ]) async {
    if (executor != null) {
      return super.deleteBatchSample(sampleId, executor);
    }
    _check(Permission.labResultsUpdate);
    // Each result keeps its own tombstone + consumption reversal through
    // the existing delete path (own transactions, no nesting).
    final testIds = await listBatchSampleTestIds(sampleId);
    for (final id in testIds) {
      await deleteSampleTest(id, user: user);
    }
    final db = await dbHelper.database;
    await db.transaction((txn) async {
      await super.deleteBatchSample(sampleId, txn);
      await _enqueueConfig(
        txn,
        entity: _productBatchSample,
        table: 'product_batch_samples',
        localId: sampleId,
        operation: 'tombstone',
        action: AuditAction.labResultSaved,
        details: {'localId': sampleId},
      );
    });
  }

  // ── Transaction plumbing ──────────────────────────────────────────────

  /// §9.4: active member + permission + not a read-only device, and
  /// connectivity for the privileged operations. Throws [AuthorizationError]
  /// otherwise, before anything is written.
  void _check(Permission permission) {
    if (guard.allows(permission.id)) return;
    final privileged = permissionRequiresFreshSession(permission);
    throw AuthorizationError(
      privileged && !guard.online
          ? AppErrors.privilegedOperationNeedsConnection
          : AppErrors.notAuthorizedForOperation,
    );
  }

  /// Shared bookkeeping for every `labConfig` entity: bump the sync version,
  /// queue it and append the audit entry, all on the caller's executor so a
  /// failure rolls everything back.
  Future<void> _enqueueConfig(
    DatabaseExecutor txn, {
    required SyncEntity entity,
    required String table,
    required int localId,
    required String operation,
    required String action,
    required Map<String, dynamic> details,
  }) async {
    final current = await txn.query(
      table,
      where: 'id = ?',
      whereArgs: [localId],
      limit: 1,
    );
    final Map<String, dynamic> fresh;
    if (current.isEmpty) {
      fresh = {'id': localId};
    } else {
      fresh = Map<String, dynamic>.from(current.first);
    }
    final localVersion = (fresh['version'] as num?)?.toInt() ?? 0;
    final remoteVersion = (fresh['remote_version'] as num?)?.toInt() ?? 0;
    final isFirstPush = remoteVersion == 0;
    final nextVersion = isFirstPush
        ? 1
        : (localVersion > remoteVersion ? localVersion : remoteVersion) + 1;
    await txn.update(
      table,
      {'version': nextVersion, 'sync_state': 'queued'},
      where: 'id = ?',
      whereArgs: [localId],
    );
    final snapshot = Map<String, dynamic>.from(fresh)
      ..['version'] = nextVersion
      ..['sync_state'] = 'queued'
      ..['config_type'] = _configTypeOf(table)
      ..['payload'] = Map<String, dynamic>.from(fresh)
      ..['updated_at'] = fresh['updated_at'] ?? DateTime.now().toIso8601String()
      ..['updated_by'] = fresh['updated_by'] ?? guard.uid
      ..['device_id'] = fresh['device_id'] ?? guard.deviceId;
    if (operation == 'tombstone') {
      snapshot['deleted_at'] = DateTime.now().toIso8601String();
      if (fresh['is_active'] != null) snapshot['is_active'] = 0;
      if (fresh['active'] != null) snapshot['active'] = 0;
    }
    final ctx = SyncPayloadContext(
      organizationId: guard.organizationId,
      uid: guard.uid,
      deviceId: guard.deviceId,
      version: nextVersion,
      versionField: 'version',
    );
    final docId = entity.docId(snapshot);
    await queue.enqueue(
      txn,
      entityType: entity.type,
      entityId: docId,
      localRef: localId,
      operation: operation,
      payload: buildRemotePayload(
        entity,
        snapshot,
        ctx,
        asCreate: isFirstPush || operation == 'tombstone',
      ),
      baseVersion: remoteVersion,
    );
    await audit.log(
      txn,
      action: action,
      entityType: entity.type,
      entityId: docId,
      details: {
        ...details,
        'localId': localId,
        'version': nextVersion,
        'operation': operation,
        'actor': guard.email,
      },
    );
  }

  String _configTypeOf(String table) => switch (table) {
    'lab_analyses' => 'analysis',
    'lab_analysis_items' => 'analysis_item',
    'lab_field_chemical_links' => 'field_chemical_link',
    'lab_constants' => 'constant',
    'lab_products' => 'product',
    'lab_product_analyses' => 'product_analysis',
    'lab_units' => 'unit',
    _ => table,
  };

  Future<void> _refreshRangesForProduct(
    DatabaseExecutor txn,
    int productId,
  ) async {
    final rows = await txn.query(
      'lab_product_analyses',
      where: 'product_id = ?',
      whereArgs: [productId],
    );
    for (final r in rows) {
      final id = (r['id'] as num?)?.toInt();
      if (id == null) continue;
      await _enqueueConfig(
        txn,
        entity: _labProductAnalysis,
        table: 'lab_product_analyses',
        localId: id,
        operation: 'upsert',
        action: AuditAction.settingsUpdated,
        details: {'productId': productId, 'analysisId': r['analysis_id']},
      );
    }
  }

  Future<void> _refreshAnalysisChildren(
    DatabaseExecutor txn,
    int analysisId,
  ) async {
    final items = await txn.query(
      'lab_analysis_items',
      where: 'analysis_id = ?',
      whereArgs: [analysisId],
    );
    for (final r in items) {
      final id = (r['id'] as num?)?.toInt();
      if (id == null) continue;
      await _enqueueConfig(
        txn,
        entity: _labAnalysisItem,
        table: 'lab_analysis_items',
        localId: id,
        operation: 'upsert',
        action: AuditAction.settingsUpdated,
        details: {'analysisId': analysisId, 'inventoryId': r['inventory_id']},
      );
    }
    final links = await txn.query(
      'lab_field_chemical_links',
      where: 'analysis_id = ?',
      whereArgs: [analysisId],
    );
    for (final r in links) {
      final id = (r['id'] as num?)?.toInt();
      if (id == null) continue;
      await _enqueueConfig(
        txn,
        entity: _labFieldLink,
        table: 'lab_field_chemical_links',
        localId: id,
        operation: 'upsert',
        action: AuditAction.settingsUpdated,
        details: {'analysisId': analysisId, 'dynamicField': r['dynamic_field']},
      );
    }
  }

  /// Same bookkeeping as the inspections facade: bump the local sync version,
  /// snapshot the remote payload, queue it and append the audit entry - all on
  /// the caller's executor, so a failure rolls the whole test back.
  Future<void> _enqueueResult(
    DatabaseExecutor txn,
    Map<String, dynamic>? test,
  ) async {
    final id = (test?['id'] as num?)?.toInt();
    if (test == null || id == null) return;
    final current = await txn.query(
      'lab_sample_tests',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (current.isEmpty) return;
    final fresh = Map<String, dynamic>.from(current.first);
    final localVersion = (fresh['version'] as num?)?.toInt() ?? 0;
    final remoteVersion = (fresh['remote_version'] as num?)?.toInt() ?? 0;
    final isFirstPush = remoteVersion == 0;
    final nextVersion = isFirstPush
        ? 1
        : (localVersion > remoteVersion ? localVersion : remoteVersion) + 1;
    await txn.update(
      'lab_sample_tests',
      {'version': nextVersion, 'sync_state': 'queued'},
      where: 'id = ?',
      whereArgs: [id],
    );

    final snapshot = Map<String, dynamic>.from(fresh)
      ..['version'] = nextVersion
      ..['sync_state'] = 'queued';
    final ctx = SyncPayloadContext(
      organizationId: guard.organizationId,
      uid: guard.uid,
      deviceId: guard.deviceId,
      version: nextVersion,
      versionField: 'version',
    );
    final docId = _labResult.docId(snapshot);
    await queue.enqueue(
      txn,
      entityType: _labResult.type,
      entityId: docId,
      localRef: id,
      operation: isFirstPush ? 'create' : 'update',
      payload: buildRemotePayload(
        _labResult,
        snapshot,
        ctx,
        asCreate: isFirstPush,
      ),
      baseVersion: remoteVersion,
    );
    await audit.log(
      txn,
      action: AuditAction.labResultSaved,
      entityType: _labResult.type,
      entityId: docId,
      details: {
        'localId': id,
        'version': nextVersion,
        'analysisId': snapshot['analysis_id'],
        'sourceName': snapshot['source_name'],
        'sampleName': snapshot['sample_name'],
      },
    );
  }
}
