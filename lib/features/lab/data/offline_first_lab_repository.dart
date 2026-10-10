import 'package:sqflite/sqflite.dart';

import '../../../core/auth/permissions.dart';
import '../../../core/constants/app_errors.dart';
import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/entity_registry.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../organizations/data/member_write_guard.dart';
import '../domain/lab_local_repository.dart';
import '../domain/lab_result_repository.dart';
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
    implements LabResultRepository, LabLocalRepository,
        LabConfigurationRepository {
  OfflineFirstLabRepository({
    required super.dbHelper,
    required this.guard,
    required this.queue,
    required this.audit,
  });

  final WriteGuard guard;
  final SyncQueue queue;
  final AuditLogger audit;

  static final SyncEntity _labResult =
      syncEntities.firstWhere((e) => e.type == 'labResult');
  static final SyncEntity _labProduct =
      syncEntities.firstWhere((e) => e.type == 'labProduct');
  static final SyncEntity _labAnalysis =
      syncEntities.firstWhere((e) => e.type == 'labAnalysis');
  static final SyncEntity _labConstant =
      syncEntities.firstWhere((e) => e.type == 'labConstant');
  static final SyncEntity _labAnalysisItem =
      syncEntities.firstWhere((e) => e.type == 'labAnalysisItem');
  static final SyncEntity _labFieldLink =
      syncEntities.firstWhere((e) => e.type == 'labFieldLink');
  static final SyncEntity _labProductAnalysis =
      syncEntities.firstWhere((e) => e.type == 'labProductAnalysis');

  // ── §9.4 writes: Inventory (device-local, still guarded) ────────────

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
    final db = await dbHelper.database;
    return db.transaction((txn) async {
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
      return item;
    });
  }

  @override
  Future<Map<String, dynamic>> updateInventoryItem(
    int itemId,
    Map<String, dynamic> fields, [
    DatabaseExecutor? executor,
  ]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final item = await super.updateInventoryItem(itemId, fields, txn);
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'inventoryItem',
        entityId: 'inv_$itemId',
        details: {
          'localId': itemId,
          'fields': fields.keys.toList(),
        },
      );
      return item;
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
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      final item = await super.adjustStock(
        itemId: itemId,
        newQty: newQty,
        reason: reason,
        user: user,
        deltaQty: deltaQty,
        executor: txn,
      );
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
      return item;
    });
  }

  // ── Equipment (device-local registry, guarded + audited, never synced) ──

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
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipment',
        entityId: 'eq_${item['id']}',
        details: {'localId': item['id'], 'name': item['name']},
      );
      return item;
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
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipment',
        entityId: 'eq_$equipmentId',
        details: {'localId': equipmentId, 'fields': fields.keys.toList()},
      );
      return item;
    });
  }

  @override
  Future<void> deleteEquipment(int equipmentId,
      [DatabaseExecutor? executor]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      await super.deleteEquipment(equipmentId, txn);
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
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipmentEvent',
        entityId: 'eqev_${event['id']}',
        details: {'localId': event['id'], 'equipmentId': equipmentId},
      );
      return event;
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
      await audit.log(
        txn,
        action: AuditAction.settingsUpdated,
        entityType: 'labEquipmentEvent',
        entityId: 'eqev_$eventId',
        details: {'localId': eventId, 'fields': fields.keys.toList()},
      );
      return event;
    });
  }

  @override
  Future<void> deleteEquipmentEvent(int eventId,
      [DatabaseExecutor? executor]) async {
    _check(Permission.labResultsUpdate);
    final db = await dbHelper.database;
    return db.transaction((txn) async {
      await super.deleteEquipmentEvent(eventId, txn);
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
        details: {
          'localId': productId,
          'fields': fields.keys.toList(),
        },
      );
      if (fields.containsKey('ranges') ||
          fields.containsKey('chemical_reference')) {
        await _refreshRangesForProduct(txn, productId);
      }
    });
    return product;
  }

  @override
  Future<Map<String, dynamic>> deleteProduct(int productId, [
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
        details: {
          'materialId': materialId,
          'saved': result['saved'],
        },
      );
      return result;
    });
  }

  /// Derive the canonical reference (parameters, per-material bounds and linked
  /// analyses) from the materials themselves. Local-only, like the reference,
  /// and deliberately role-agnostic (mirrors `ensureDefaultAnalyses`, which
  /// also runs during organization bootstrap).
  @override
  Future<Map<String, dynamic>> syncReferenceAnalyses(
      [DatabaseExecutor? executor]) async {
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
  Future<Map<String, dynamic>> deleteAnalysis(int analysisId, [
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
  Future<Map<String, dynamic>> deleteGlobalConstant(int constantId, [
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
    final current = await txn.query(table, where: 'id = ?', whereArgs: [localId], limit: 1);
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
      {
        'version': nextVersion,
        'sync_state': 'queued',
      },
      where: 'id = ?',
      whereArgs: [localId],
    );
    final snapshot = Map<String, dynamic>.from(fresh)
      ..['version'] = nextVersion
      ..['sync_state'] = 'queued'
      ..['config_type'] = _configTypeOf(table)
      ..['payload'] = Map<String, dynamic>.from(fresh)
      ..['updated_at'] = fresh['updated_at'] ?? DateTime.now().toIso8601String()
      ..['updated_by'] = fresh['updated_by'] ?? guard.email
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
      payload: buildRemotePayload(entity, snapshot, ctx,
          asCreate: isFirstPush || operation == 'tombstone'),
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

  Future<void> _refreshRangesForProduct(DatabaseExecutor txn, int productId) async {
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

  Future<void> _refreshAnalysisChildren(DatabaseExecutor txn, int analysisId) async {
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
      DatabaseExecutor txn, Map<String, dynamic>? test) async {
    final id = (test?['id'] as num?)?.toInt();
    if (test == null || id == null) return;
    final current = await txn.query('lab_sample_tests',
        where: 'id = ?', whereArgs: [id], limit: 1);
    if (current.isEmpty) return;
    final fresh = Map<String, dynamic>.from(current.first);
    final localVersion = (fresh['version'] as num?)?.toInt() ?? 0;
    final remoteVersion = (fresh['remote_version'] as num?)?.toInt() ?? 0;
    final isFirstPush = remoteVersion == 0;
    final nextVersion = isFirstPush
        ? 1
        : (localVersion > remoteVersion ? localVersion : remoteVersion) + 1;
    await txn.update('lab_sample_tests', {
      'version': nextVersion,
      'sync_state': 'queued',
    }, where: 'id = ?', whereArgs: [id]);

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
      payload: buildRemotePayload(_labResult, snapshot, ctx, asCreate: isFirstPush),
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
