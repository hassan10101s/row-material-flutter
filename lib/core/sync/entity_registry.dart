import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'remote/remote_data_source.dart';
import 'sync_codec.dart';

/// The single contract between `push_worker`, `pull_worker` and the local
/// tables (plan Â§9.2). Adding a table to the sync scope = adding one entry.
class SyncEntity {
  const SyncEntity({
    required this.type,
    required this.collection,
    required this.localTable,
    required this.docId,
    required this.mutableFields,
    this.appendOnly = false,
    this.permission,
    this.payloadBuilder,
    this.usesLocalIdAsRef = true,
    this.naturalKeyIdentity = false,
    this.accepts,
  });

  /// Stable identifier used in `sync_queue.entity_type`.
  final String type;

  /// Firestore collection under `organizations/{orgId}/`.
  final SyncCollection collection;

  /// Local SQLite table.
  final String localTable;

  /// Remote document id derived from a local row.
  final String Function(Map<String, dynamic> row) docId;

  /// Fields a client is allowed to change after creation â€” must match the
  /// `hasOnly([...])` list in `firestore.rules` for this collection.
  final Set<String> mutableFields;

  /// Append-only collections are never updated or deleted remotely.
  final bool appendOnly;

  /// Permission required to push this entity.
  final String? permission;

  /// Optional payload shaping (defaults to snakeâ†’camel row copy).
  final Map<String, dynamic> Function(
    Map<String, dynamic> row,
    SyncPayloadContext ctx,
  )?
  payloadBuilder;

  /// Whether the envelope's `localId` may be used to find the local row of a
  /// remote document.
  ///
  /// True for every table this application creates and consumes: the
  /// `localId` *is* the local primary key, and the natural key resolves the
  /// documents written by another device. It is **false** for the audit trail,
  /// whose rows are born on the device that wrote them - there the `localId`
  /// of a document written elsewhere is the primary key of an unrelated local
  /// row, and matching on it would silently overwrite that row.
  final bool usesLocalIdAsRef;

  /// Whether the table's natural key is its true cross-device identity.
  ///
  /// When true, a pulled document that matches nothing locally is inserted
  /// with a FRESH local id: the envelope's `localId` is the origin device's
  /// row id and means nothing here. Inserting with it (plus
  /// `ConflictAlgorithm.replace`) would overwrite the unrelated local row
  /// that happens to hold that id — autoincrement ids collide across devices
  /// by construction (both devices' first inspection is row 1).
  ///
  /// False for the lab-config tables, whose document ids (`lc_<table>_<id>`)
  /// ARE the origin row id: keeping it preserves the doc↔row mapping, and
  /// same-content seeds converge version-wise instead of duplicating.
  final bool naturalKeyIdentity;

  /// Whether a *pulled* document belongs to this entity.
  ///
  /// Null (the default) accepts every document of [collection], which is
  /// correct for the entities that own a collection outright. It is required
  /// whenever several entities share one collection: the seven lab-settings
  /// tables all live in `labConfig`, so a collection query hands every
  /// lab-config document to every one of those entities. Without a
  /// discriminator each entity writes the whole collection into its own table —
  /// `localId` collides across tables, so unrelated rows overwrite each other,
  /// and a document whose payload does not fit the target table aborts on a
  /// `NOT NULL` violation. The document id already names its table
  /// (`lc_<table>_<id>`, see [labConfigDocId]), which is the reliable signal
  /// because it cannot be absent from the document.
  final bool Function(RemoteDocument document)? accepts;

  static SyncEntity? byType(String type) {
    for (final e in syncEntities) {
      if (e.type == type) return e;
    }
    // The audit outbox has no entry in `syncEntities` (it is never pulled back
    // into a local table) but its rows are pushed like any other document, so
    // the push worker has to be able to resolve it.
    if (type == auditLogEntity.type) return auditLogEntity;
    return null;
  }

  static SyncEntity? byCollection(SyncCollection collection) {
    for (final e in syncEntities) {
      if (e.collection == collection) return e;
    }
    return null;
  }
}

/// Context handed to [SyncEntity.payloadBuilder] for every push.
class SyncPayloadContext {
  const SyncPayloadContext({
    required this.organizationId,
    required this.uid,
    required this.deviceId,
    required this.version,
    required this.versionField,
  });

  final String organizationId;
  final String uid;
  final String deviceId;
  final int version;
  final String versionField;
}

String qcDocId(Map<String, dynamic> row) =>
    'qc_${row['inspection_id']}_${row['version']}';

String labTestDocId(Map<String, dynamic> row) => 'lt_${row['id']}';

/// Cross-device identity for comprehensive sync (plan §1): the Firestore
/// document id IS the local `remote_id` (UUID for new rows,
/// `legacy_<table>_<id>` backfill for old rows).
String remoteIdDocId(Map<String, dynamic> row) {
  final remoteId = '${row['remote_id'] ?? ''}';
  if (remoteId.isNotEmpty) return remoteId;
  return 'legacy_${row['id']}';
}

String Function(Map<String, dynamic> row) labConfigDocId(String table) =>
    (row) => 'lc_${table}_${row['id']}';

/// Companion of [labConfigDocId] for the pull: accepts only the documents this
/// table wrote, so the entities sharing the `labConfig` collection stop
/// applying each other's rows.
bool Function(RemoteDocument document) labConfigSelector(String table) =>
    (document) => document.id.startsWith('lc_${table}_');

String userDocId(Map<String, dynamic> row) {
  final memberId = '${row['member_id'] ?? ''}';
  if (memberId.isNotEmpty) return memberId;
  return 'member_${row['id']}';
}

/// Scope of V1 (plan Â§6.3, D7): core data + lab configuration.
/// Inventory / consumption / worksheet / settings stay device-local on purpose.
final List<SyncEntity> syncEntities = [
  SyncEntity(
    type: 'sample',
    collection: SyncCollection.samples,
    localTable: 'inspections',
    naturalKeyIdentity: true,
    docId: (row) => '${row['entry_code']}',
    permission: 'samples.update',
    mutableFields: {
      'inspectionKind',
      'productId',
      'formulaNumber',
      'batchNumber',
      'materialName',
      'materialCode',
      'inspectionDate',
      'supplier',
      'truckNumber',
      'quantity',
      'sampleTakenBy',
      'specialistName',
      'physicalResultsJson',
      'chemicalResultsJson',
      'physicalReferenceJson',
      'chemicalReferenceJson',
      'sampleNamesJson',
      'snapshotJson',
      // NOTE: no `reportHtml` — derived artifact, rebuilt locally (see
      // `buildRemotePayload`). Kept out so documents stay small and
      // re-renders never churn the sync payload.
      'decisionStatus',
      'decisionReason',
      'followUpNote',
      'rejectedQuantity',
      'decisionVersion',
      'expiryDate',
      'localId',
      'payloadBytes',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'qualityCheck',
    collection: SyncCollection.qualityChecks,
    localTable: 'inspection_status_history',
    naturalKeyIdentity: true,
    docId: qcDocId,
    permission: 'qc.approve',
    appendOnly: true,
    mutableFields: const {},
  ),
  SyncEntity(
    type: 'labResult',
    collection: SyncCollection.labResults,
    localTable: 'lab_sample_tests',
    naturalKeyIdentity: true,
    docId: labTestDocId,
    permission: 'lab_results.update',
    mutableFields: {
      'analysisId',
      'sourceType',
      'sourceRefId',
      'sourceName',
      'sampleName',
      'resultText',
      'dynamicValues',
      'entryCode',
      'worksheetRowId',
      'testedBy',
      'testedAt',
      'localId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'productBatchSample',
    collection: SyncCollection.productBatchSamples,
    localTable: 'product_batch_samples',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    mutableFields: {
      'batchId',
      'sampleNo',
      'sampleName',
      'sampleTaker',
      'physicalResultsJson',
      'chemicalResultsJson',
      'testedBy',
      'testedByName',
      'testedAt',
      'decisionStatus',
      'decisionReason',
      'localId',
      'remoteId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'labAnalysis',
    collection: SyncCollection.labConfig,
    localTable: 'lab_analyses',
    docId: labConfigDocId('lab_analyses'),
    accepts: labConfigSelector('lab_analyses'),
    permission: 'lab_results.update',
    mutableFields: {
      'payload',
      'configType',
      'localId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'labAnalysisItem',
    collection: SyncCollection.labConfig,
    localTable: 'lab_analysis_items',
    docId: labConfigDocId('lab_analysis_items'),
    accepts: labConfigSelector('lab_analysis_items'),
    permission: 'lab_results.update',
    mutableFields: {
      'payload',
      'configType',
      'localId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'labFieldLink',
    collection: SyncCollection.labConfig,
    localTable: 'lab_field_chemical_links',
    docId: labConfigDocId('lab_field_chemical_links'),
    accepts: labConfigSelector('lab_field_chemical_links'),
    permission: 'lab_results.update',
    mutableFields: {
      'payload',
      'configType',
      'localId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'labConstant',
    collection: SyncCollection.labConfig,
    localTable: 'lab_constants',
    docId: labConfigDocId('lab_constants'),
    accepts: labConfigSelector('lab_constants'),
    permission: 'lab_results.update',
    mutableFields: {
      'payload',
      'configType',
      'localId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'labProduct',
    collection: SyncCollection.labConfig,
    localTable: 'lab_products',
    docId: labConfigDocId('lab_products'),
    accepts: labConfigSelector('lab_products'),
    permission: 'lab_results.update',
    mutableFields: {
      'payload',
      'configType',
      'localId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'labProductAnalysis',
    collection: SyncCollection.labConfig,
    localTable: 'lab_product_analyses',
    docId: labConfigDocId('lab_product_analyses'),
    accepts: labConfigSelector('lab_product_analyses'),
    permission: 'lab_results.update',
    mutableFields: {
      'payload',
      'configType',
      'localId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'labUnit',
    collection: SyncCollection.labConfig,
    localTable: 'lab_units',
    docId: labConfigDocId('lab_units'),
    accepts: labConfigSelector('lab_units'),
    permission: 'lab_results.update',
    mutableFields: {
      'payload',
      'configType',
      'localId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'member',
    collection: SyncCollection.members,
    localTable: 'users',
    naturalKeyIdentity: true,
    docId: userDocId,
    permission: 'users.update',
    mutableFields: {
      'role',
      'status',
      'displayName',
      'activatedAt',
      'version',
      'updatedAt',
      'updatedBy',
    },
  ),
  // ── Comprehensive sync (plan §3): inventory / transactions / equipment /
  // worksheets / reference. Each gets its own collection so one edit never
  // overwrites an unrelated table, and `remote_id` is the document id.
  SyncEntity(
    type: 'inventoryItem',
    collection: SyncCollection.inventoryItems,
    localTable: 'lab_inventory',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    mutableFields: {
      'name',
      'category',
      'unit',
      'currentQty',
      'minQty',
      'description',
      'localId',
      'remoteId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'inventoryTransaction',
    collection: SyncCollection.inventoryTransactions,
    localTable: 'inventory_transactions',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    appendOnly: true,
    mutableFields: const {},
  ),
  SyncEntity(
    type: 'consumption',
    collection: SyncCollection.consumption,
    localTable: 'lab_consumption_log',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    appendOnly: true,
    mutableFields: const {},
  ),
  SyncEntity(
    type: 'stockAdjustment',
    collection: SyncCollection.stockAdjustments,
    localTable: 'lab_stock_adjustments',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    appendOnly: true,
    mutableFields: const {},
  ),
  SyncEntity(
    type: 'equipment',
    collection: SyncCollection.equipment,
    localTable: 'lab_equipment',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    mutableFields: {
      'name',
      'code',
      'manufacturer',
      'description',
      'lastCalibrationDate',
      'localId',
      'remoteId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'equipmentEvent',
    collection: SyncCollection.equipmentEvents,
    localTable: 'lab_equipment_events',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    mutableFields: {
      'equipmentId',
      'equipmentRemoteId',
      'eventType',
      'eventDate',
      'notes',
      'localId',
      'remoteId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'worksheet',
    collection: SyncCollection.worksheets,
    localTable: 'lab_worksheet',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    mutableFields: {
      'sourceType',
      'sourceRefId',
      'sourceName',
      'sampleNumber',
      'entryCode',
      'status',
      'voidReason',
      'voidedBy',
      'voidedAt',
      'localId',
      'remoteId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'referenceMaterial',
    collection: SyncCollection.referenceMaterials,
    localTable: 'reference_materials',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    mutableFields: {
      'materialName',
      'materialCode',
      'category',
      'unit',
      'active',
      'localId',
      'remoteId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  SyncEntity(
    type: 'labMaterialAnalysis',
    collection: SyncCollection.labConfig,
    localTable: 'lab_material_analyses',
    docId: labConfigDocId('lab_material_analyses'),
    accepts: labConfigSelector('lab_material_analyses'),
    permission: 'lab_results.update',
    mutableFields: {
      'payload',
      'configType',
      'localId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
];

/// Audit log rows are not part of `syncEntities` (the normal cycle does not walk
/// them) but they are pushed as documents and pulled by the dedicated audit
/// cycle of `SyncEngine`, so they get their own descriptor.
final SyncEntity auditLogEntity = SyncEntity(
  type: 'auditLog',
  collection: SyncCollection.auditLogs,
  localTable: 'audit_logs',
  naturalKeyIdentity: true,
  docId: (row) => 'al_${row['device_id']}_${row['occurred_at']}_${row['id']}',
  appendOnly: true,
  mutableFields: const {},
  usesLocalIdAsRef: false,
);

/// Local row â†’ remote document payload.
///
/// Rules of the mapping (plan Â§6.1/Â§6.2):
///  * column names are converted snake_case â†’ camelCase,
///  * `*_json` columns are carried verbatim as JSON strings,
///  * the sync envelope (`organizationId`, `version`, `updatedBy`, `deviceId`,
///    `createdAt`, `updatedAt`, `deletedAt`, `localId`) is always present.
Map<String, dynamic> buildRemotePayload(
  SyncEntity entity,
  Map<String, dynamic> row,
  SyncPayloadContext ctx, {
  bool asCreate = false,
}) {
  final payload = <String, dynamic>{};
  for (final entry in row.entries) {
    if (entry.key == 'id') {
      payload['localId'] = entry.value;
      continue;
    }
    final camel = _toCamel(entry.key);
    if (_internalColumns.contains(camel)) continue;
    // Derived artifacts are never synced, only the data they render from:
    // `report_html` (full HTML + embedded base64 logo/QR images) is rebuilt
    // locally by `refreshReportHtml` and re-rendered on demand at export.
    // Pushing it bloats every document toward the 900 kB oversized guard and
    // turns each local re-render into sync churn. The receiver keeps/regenerates
    // its own copy (`report_html` stays a local cache column).
    if (camel == 'reportHtml') continue;
    // `createdAt` is write-once and is stamped from the envelope below, so the
    // local `created_at` string must never be copied through. See the note
    // where the sentinel is written for why an update must omit it entirely.
    if (camel == 'createdAt') continue;
    payload[camel] = entry.value;
  }
  final builder = entity.payloadBuilder;
  if (builder != null) {
    final custom = builder(row, ctx);
    payload
      ..clear()
      ..addAll(custom);
  }

  payload['organizationId'] = ctx.organizationId;
  payload['localId'] = row['id'];
  payload['version'] = asCreate ? 1 : ctx.version;
  payload['updatedBy'] = ctx.uid;
  payload['deviceId'] = ctx.deviceId;
  payload['updatedAt'] = FieldTimestampSentinel.value;
  // `createdAt` is write-once. A create writes a real `Timestamp` (the
  // sentinel is swapped for `serverTimestamp()` in the remote layer), so an
  // update must NOT re-send the local ISO `String` in `row['created_at']`:
  // Rules compare `request.resource.data.createdAt == resource.data.createdAt`
  // with no type coercion, so a String-over-Timestamp update is denied for
  // `samples`, `labResults` and `labConfig` alike and the push degenerates
  // into a permanent conflict row the user cannot clear.
  //
  // Leaving the key out is sufficient because the update path uses
  // `ref.update(payload)` (a partial write) and `allow update` calls
  // `bumped()` rather than `hasEnvelope()`, whose `hasAll` list includes
  // `createdAt`. The stored Timestamp is untouched and stays identical.
  //
  // The copy loop above skips `created_at` for the same reason; without that
  // skip this line only ever *overwrote* the local string on create and let it
  // through on update.
  if (asCreate) payload['createdAt'] = FieldTimestampSentinel.value;
  payload['createdBy'] = row['created_by'] != null
      ? _uidForLocalUser(row['created_by'])
      : ctx.uid;
  payload['deletedAt'] = row['deleted_at'];
  if (entity.collection == SyncCollection.labConfig) {
    payload['configType'] = entity.localTable;
    payload['payload'] = SyncCodec.encodeMap(_stripSyncColumns(row));
  }
  if (entity.type == 'sample') {
    payload['payloadBytes'] = _payloadBytes(payload);
  }
  return payload;
}

/// Marker replaced by `FieldValue.serverTimestamp()` in the remote layer.
class FieldTimestampSentinel {
  static const String value = '__SERVER_TIMESTAMP__';
}

/// Firestore size guard without the old double-allocating
/// `jsonEncode(x).toLowerCase().codeUnits.length` (lowercased copy + code-unit
/// list, and UTF-16 units instead of bytes). Single sanitized encode.
int _payloadBytes(Map<String, dynamic> payload) => SyncCodec.byteSize(payload);

Map<String, dynamic> _stripSyncColumns(Map<String, dynamic> row) {
  const syncColumns = {
    'version',
    'remote_version',
    'remote_synced_at',
    'sync_state',
    'deleted_at',
    'remote_id',
    'device_id',
    'updated_by',
    'updated_at',
    // Derived artifacts, same rule as `reportHtml` in `buildRemotePayload`:
    // the nested labConfig `payload` must carry data only.
    'report_html',
    'last_pdf_path',
  };
  return {
    for (final entry in row.entries)
      if (!syncColumns.contains(entry.key)) entry.key: entry.value,
  };
}

String _uidForLocalUser(Object? localUserId) {
  // The real mapping (users.id â†’ Firebase uid) is injected by the sync engine
  // through `LocalUserDirectory`; the fallback keeps documents self-describing.
  return localUserId == null ? '' : 'local_$localUserId';
}

const Set<String> _internalColumns = {
  'remoteVersion',
  'remoteSyncedAt',
  'syncState',
  'passwordHash',
  'permissionsJson',
  'lastPdfPath',
};

String _toCamel(String value) {
  if (!value.contains('_')) return value;
  final parts = value.split('_');
  final buffer = StringBuffer(parts.first);
  for (final part in parts.skip(1)) {
    if (part.isEmpty) continue;
    buffer
      ..write(part[0].toUpperCase())
      ..write(part.substring(1));
  }
  return buffer.toString();
}

String camelToSnake(String value) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final ch = value[i];
    if (ch.toUpperCase() == ch && ch.toLowerCase() != ch) {
      buffer.write('_');
      buffer.write(ch.toLowerCase());
    } else {
      buffer.write(ch);
    }
  }
  return buffer.toString();
}

/// Column names of a local table (`PRAGMA table_info`).
Future<Set<String>> availableColumns(DatabaseExecutor db, String table) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  return {for (final column in info) '${column['name']}'};
}

/// Remap a remote document's foreign keys to this device's ids, in place.
///
/// The envelope carries the origin device's raw ids, which are meaningless
/// here: writing them verbatim either violates FK constraints (e.g.
/// `created_by: 'local_1'` in an INTEGER FK column, or a `material_id` this
/// device never had) or silently links the wrong row (both devices'
/// autoincrement ids collide by construction). All three remote-apply paths
/// (pull, manual keep-remote, auto-rebase) must call this before writing:
/// `doc` is the remote document (carries codes/kind), `resolved` is the
/// column-filtered local row being written.
Future<void> resolveRemoteRowRefs(
  DatabaseExecutor txn,
  SyncEntity entity,
  Map<String, dynamic> resolved,
  Map<String, dynamic> doc, {
  required Future<int> Function(DatabaseExecutor txn) ensureProductSentinel,
  Future<int> Function(String uid)? userIdFor,
}) async {
  Future<int> mapUser(String uid) async {
    if (userIdFor != null) return userIdFor(uid);
    if (uid.isEmpty || uid.startsWith('local_')) return 0;
    final rows = await txn.query(
      'users',
      columns: const ['id'],
      where: 'uid = ?',
      whereArgs: [uid],
      limit: 1,
    );
    return rows.isEmpty ? 0 : (rows.first['id'] as num).toInt();
  }

  for (final column in const ['created_by', 'changed_by']) {
    final value = resolved[column];
    if (value is String) resolved[column] = await mapUser(value);
  }

  // Person columns on lab/sync tables hold Firebase uid strings (TEXT).
  // Older code wrote raw strings like 'local_1' or emails straight into
  // INTEGER columns and crashed later in int.parse. Normalize here: map
  // known uids to local ids where the column is INTEGER-affinity, otherwise
  // keep the uid string (TEXT columns) but never keep a 'local_*' placeholder.
  for (final column in const ['tested_by', 'assigned_to', 'updated_by']) {
    final value = resolved[column];
    if (value is! String) continue;
    if (value.isEmpty || value.startsWith('local_')) {
      resolved[column] = null;
      continue;
    }
    // If the target column is TEXT-affinity (new installs + QC tables),
    // keep the uid verbatim. INTEGER-affinity legacy columns get the mapped id.
    // We cannot PRAGMA per row cheaply here, so: keep uid strings that look
    // like Firebase uids (long/alphanumeric) and map only short numeric strings.
    final asInt = int.tryParse(value);
    if (asInt != null) {
      resolved[column] = asInt;
    } else if (value.contains('@')) {
      // Email leaked into an id column (legacy offline_first_lab_repository
      // wrote guard.email): drop to null rather than poison the row.
      resolved[column] = null;
    }
    // else: keep uid string for TEXT columns.
  }

  if (entity.localTable == 'lab_equipment_events') {
    // `equipment_id` is a per-device autoincrement id: the origin device's
    // value is meaningless here. Remap through the cross-device parent
    // identity (`equipment_remote_id`), which the writer stamps at create
    // time. Missing parent => transient: the equipment master lands in the
    // same cycle and the failed-docs retry at the end picks this up.
    final parentRemote = '${doc['equipmentRemoteId'] ?? doc['equipment_remote_id'] ?? resolved['equipment_remote_id'] ?? ''}';
    if (parentRemote.isEmpty) {
      throw StateError('transient: equipment event without parent identity');
    }
    final parent = await txn.query(
      'lab_equipment',
      columns: const ['id'],
      where: 'remote_id = ?',
      whereArgs: [parentRemote],
      limit: 1,
    );
    if (parent.isEmpty) {
      throw StateError(
          'transient: lab equipment $parentRemote not synced yet');
    }
    resolved['equipment_id'] = (parent.first['id'] as num).toInt();
    resolved['equipment_remote_id'] = parentRemote;
    return;
  }

  if (entity.localTable != 'inspections') return;

  final kind =
      '${resolved['inspection_kind'] ?? doc['inspectionKind'] ?? doc['inspection_kind'] ?? 'raw'}';
  if (kind == 'product') {
    resolved['material_id'] = await ensureProductSentinel(txn);
  } else {
    final code =
        '${doc['materialCode'] ?? doc['material_code'] ?? resolved['material_code'] ?? ''}';
    final name =
        '${doc['materialName'] ?? doc['material_name'] ?? resolved['material_name'] ?? ''}';
    if (code.isEmpty && name.isEmpty) {
      if (resolved['material_id'] is! num) return; // nothing to resolve.
      // No code identity (old parked payload): keep a valid same-device link,
      // but fail loudly instead of silently linking a placeholder when the
      // numeric id points nowhere on this device.
      final id = (resolved['material_id'] as num).toInt();
      final exists = await txn.query(
        'reference_materials',
        columns: const ['id'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      if (exists.isEmpty) {
        throw StateError('unknown material id $id with no code to resolve it');
      }
    } else {
      resolved['material_id'] = await resolveMaterialIdByCodeOrName(
        txn,
        code: code,
        name: name,
      );
    }
  }
  final productId = resolved['product_id'];
  if (productId != null) {
    final exists = await txn.query(
      'lab_products',
      columns: const ['id'],
      where: 'id = ?',
      whereArgs: [(productId as num).toInt()],
      limit: 1,
    );
    if (exists.isEmpty) {
      throw StateError('transient: lab product $productId not synced yet');
    }
  }
}

/// Local id of the material identified by [code] (then [name]).
///
/// Creates a placeholder catalog row when neither matches: the alternative is
/// losing the inspection forever (the pull cursor used to run past it) or
/// linking it to an unrelated material that happens to hold the origin
/// device's numeric id. The placeholder carries the real code/name, so the
/// ledger still reads correctly; `PullWorker` re-links to the true row when
/// it arrives.
Future<int> resolveMaterialIdByCodeOrName(
  DatabaseExecutor txn, {
  required String code,
  required String name,
}) async {
  if (code.isNotEmpty) {
    final byCode = await txn.query(
      'reference_materials',
      columns: const ['id'],
      where: 'material_code = ?',
      whereArgs: [code],
      limit: 1,
    );
    if (byCode.isNotEmpty) return (byCode.first['id'] as num).toInt();
  }
  if (name.isNotEmpty) {
    final byName = await txn.query(
      'reference_materials',
      columns: const ['id'],
      where: 'material_name = ?',
      whereArgs: [name],
      limit: 1,
    );
    if (byName.isNotEmpty) return (byName.first['id'] as num).toInt();
  }
  // ignore: avoid_print
  print('[sync] creating placeholder material code=$code name=$name');
  return txn.insert('reference_materials', {
    'material_name': name.isNotEmpty ? name : 'Unknown ($code)',
    'material_code': code.isNotEmpty ? code : 'UNK',
    'physical_reference_json': '{}',
    'chemical_reference_json': '{}',
    'imported_at': DateTime.now().toIso8601String(),
    'active': 1,
  });
}

/// Local primary key of a remote document (or of a parked local payload).
///
/// Tries the envelope's `localId` first, then the natural key of the table, so
/// a document created on another device (whose `localId` is meaningless here)
/// still lands on the right row. Null ⇒ the local database has no such row.
///
/// The `localId` branch is skipped for **foreign** documents whenever the
/// table has a natural key: autoincrement ids collide across devices (both
/// devices' first inspection is row 1), so a foreign `localId` would match an
/// unrelated local row — overwriting it or swallowing the incoming document.
/// Same-device documents (`localDeviceId` unknown or equal to the doc's
/// `deviceId`) keep the legacy fast path, which also survives a locally
/// edited natural key. Tables without a natural key (lab config) always use
/// `localId`; their convergence is version-based instead.
Future<int?> findLocalRef(
  DatabaseExecutor db,
  SyncEntity entity,
  String entityId,
  Map<String, dynamic> data, {
  String? localDeviceId,
  Set<String>? columns,
}) async {
  // Comprehensive sync plan §1: `remote_id` is the cross-device identity.
  // Try it first — it matches rows created on any device, including ones
  // whose natural key was edited locally after creation.
  try {
    final cols = columns ?? await availableColumns(db, entity.localTable);
    if (cols.contains('remote_id') && entityId.isNotEmpty) {
      final byRemote = await db.query(
        entity.localTable,
        columns: ['id'],
        where: 'remote_id = ?',
        whereArgs: [entityId],
        limit: 1,
      );
      if (byRemote.isNotEmpty) return (byRemote.first['id'] as num).toInt();
      final payloadRemote = data['remoteId'] ?? data['remote_id'];
      if (payloadRemote is String &&
          payloadRemote.isNotEmpty &&
          payloadRemote != entityId) {
        final byPayload = await db.query(
          entity.localTable,
          columns: ['id'],
          where: 'remote_id = ?',
          whereArgs: [payloadRemote],
          limit: 1,
        );
        if (byPayload.isNotEmpty) return (byPayload.first['id'] as num).toInt();
      }
    }
  } on Object {
    // Column/table missing on a legacy file: fall through to legacy matching.
  }
  final localId = data['localId'];
  final docDeviceId = '${data['deviceId'] ?? ''}';
  final foreign =
      localDeviceId != null &&
      localDeviceId.isNotEmpty &&
      docDeviceId.isNotEmpty &&
      docDeviceId != localDeviceId;
  final natural = _naturalKey(entity, entityId, data);
  if (entity.usesLocalIdAsRef &&
      localId is num &&
      (!foreign || natural == null)) {
    final rows = await db.query(
      entity.localTable,
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [localId.toInt()],
      limit: 1,
    );
    if (rows.isNotEmpty) return (rows.first['id'] as num).toInt();
  }
  if (natural == null) return null;
  final rows = await db.query(
    entity.localTable,
    columns: ['id'],
    where: natural.$1,
    whereArgs: natural.$2,
    limit: 1,
  );
  return rows.isEmpty ? null : (rows.first['id'] as num).toInt();
}

/// `(where, args)` of the natural key of [entity]'s local table, or null when
/// the table has no usable one (then only `localId` can match).
(String, List<Object?>)? _naturalKey(
  SyncEntity entity,
  String entityId,
  Map<String, dynamic> data,
) {
  switch (entity.localTable) {
    case 'lab_inventory':
      final name = data['name'];
      if (name is! String || name.isEmpty) return null;
      return ('name = ?', [name]);
    case 'lab_equipment':
      final code = data['code'];
      if (code is String && code.isNotEmpty) return ('code = ?', [code]);
      final name = data['name'];
      if (name is String && name.isNotEmpty) return ('name = ?', [name]);
      return null;
    case 'lab_equipment_events':
      // Identity is `remote_id` first (see `findLocalRef`). The fallback
      // below must NOT use `equipment_id`: it is a per-device autoincrement
      // id, so the origin device's value points at an unrelated local row.
      // `equipment_remote_id` is the cross-device parent identity.
      final parentRemote = data['equipmentRemoteId'] ??
          data['equipment_remote_id'];
      final eventDate = data['eventDate'] ?? data['event_date'];
      if (parentRemote is! String || parentRemote.isEmpty) return null;
      if (eventDate == null) return null;
      return (
        'equipment_remote_id = ? AND event_date = ?',
        [parentRemote, eventDate]
      );
    case 'lab_worksheet':
      final entryCode = data['entryCode'] ?? data['entry_code'];
      final sampleNumber = data['sampleNumber'] ?? data['sample_number'];
      if (entryCode is String && entryCode.isNotEmpty) {
        return ('entry_code = ?', [entryCode]);
      }
      if (sampleNumber is String && sampleNumber.isNotEmpty) {
        return ('sample_number = ?', [sampleNumber]);
      }
      return null;
    case 'reference_materials':
      final code = data['materialCode'] ?? data['material_code'];
      if (code is String && code.isNotEmpty)
        return ('material_code = ?', [code]);
      final name = data['materialName'] ?? data['material_name'];
      if (name is String && name.isNotEmpty) {
        return ('material_name = ?', [name]);
      }
      return null;
    case 'inventory_transactions':
    case 'lab_consumption_log':
    case 'lab_stock_adjustments':
      // Append-only ledgers: no natural key — identity is `remote_id` only.
      return null;
    case 'inspections':
      // `entry_code` is UNIQUE across both kinds (raw + product share one
      // code space), so it stays the cross-device identity for both.
      return ('entry_code = ?', [entityId]);
    case 'inspection_status_history':
      final inspectionId = data['inspectionId'] ?? data['inspection_id'];
      if (inspectionId is! num) return null;
      final version = (data['version'] as num?)?.toInt() ?? 0;
      return (
        'inspection_id = ? AND version = ?',
        [inspectionId.toInt(), version],
      );
    case 'lab_sample_tests':
      final worksheetRowId = data['worksheetRowId'] ?? data['worksheet_row_id'];
      final entryCode = data['entryCode'] ?? data['entry_code'];
      if (worksheetRowId == null || entryCode == null) return null;
      return (
        'worksheet_row_id = ? AND entry_code = ?',
        [worksheetRowId, entryCode],
      );
    case 'users':
      return ('member_id = ? OR email = ?', [entityId, data['email']]);
    case 'audit_logs':
      // Append-only: the row is identified by where and when it happened, not
      // by a local id. `device_id` + `occurred_at` is unique because the remote
      // document id is built from exactly those two (`al_<deviceId>_<ts>_<id>`).
      final device = data['deviceId'] ?? data['device_id'];
      final occurredAt = data['occurredAt'] ?? data['occurred_at'];
      if (device is! String || occurredAt is! String) return null;
      if (device.isEmpty || occurredAt.isEmpty) return null;
      return ('device_id = ? AND occurred_at = ?', [device, occurredAt]);
    default:
      return null;
  }
}

/// Inverse mapping used by `pull_worker` when applying a remote document.
///
/// The result is a *local row candidate*: the caller must keep only the keys
/// that exist as columns in `entity.localTable` (see `PullWorker._localRow`).
/// The Firestore envelope carries fields no local table has - `organizationId`
/// (isolation is physical, D3), `updatedBy`, `deviceId`, `payloadBytes` - and
/// those are the session's business, not a stored column.
Map<String, dynamic> remoteToLocalRow(
  SyncEntity entity,
  Map<String, dynamic> document, {
  String? organizationId,
}) {
  final row = <String, dynamic>{};
  for (final entry in document.entries) {
    final key = entry.key;
    if (key == 'updatedAt' || key == 'createdAt') continue;
    if (key == 'payload') continue;
    if (key == 'configType') continue;
    if (key == 'localId') {
      row['id'] = entry.value;
      continue;
    }
    if (key == 'organizationId') {
      // Deliberately dropped: the local database belongs to exactly one
      // organization, so there is nowhere to store it (plan §6.5, D3).
      //
      // The audit trail is the one exception: `audit_logs.organization_id` is
      // NOT NULL because the trail of an organization is an organizational
      // record (who did what, in this organization), not a project row. It is
      // stored from the session below, never trusted from the payload.
      if (entity.localTable == 'audit_logs') {
        final org = '${organizationId ?? entry.value ?? ''}';
        if (org.isNotEmpty) row['organization_id'] = org;
      }
      continue;
    }
    row[camelToSnake(key)] = entry.value;
  }
  if (entity.collection == SyncCollection.labConfig) {
    // The nested `payload` is the business content of a lab-config document,
    // and it reaches the remote in one of two shapes: a `Map`, when it was
    // parked straight from the local row by `OfflineFirstLabRepository`
    // (`..['payload'] = Map.from(fresh)`), or a JSON `String` when it was
    // produced by a `payloadBuilder`. Unwrapping only the `String` shape meant
    // a `Map` payload was dropped whole by the `payload` skip above, and the
    // row was rebuilt from the envelope alone: on `lab_analysis_items` that is
    // `(id, unit, version, remote_version, remote_synced_at, sync_state)`,
    // because `unit` is the only payload column whose name is identical in
    // both cases. Every other column was missing, so the insert violated
    // `NOT NULL constraint failed: lab_analysis_items.analysis_id`.
    //
    // Keys are normalised so either casing lands on the real column name;
    // `camelToSnake` leaves an already-snake_case key untouched, so a payload
    // parked from the local row round-trips byte for byte.
    Object? nested = document['payload'];
    if (nested is String) {
      try {
        nested = jsonDecode(nested);
      } on Object {
        // Malformed payload: keep the envelope only.
        nested = null;
      }
    }
    if (nested is Map) {
      for (final entry in nested.entries) {
        row[camelToSnake('${entry.key}')] = entry.value;
      }
    }
  }
  row['version'] = document['version'];
  row['remote_version'] = document['version'];
  row['updated_by'] = document['updatedBy'];
  row['deleted_at'] = document['deletedAt'];
  final remoteId = document['remoteId'] ?? document['remote_id'];
  if (remoteId is String && remoteId.isNotEmpty) {
    row['remote_id'] = remoteId;
  }
  final deviceId = document['deviceId'] ?? document['device_id'];
  if (deviceId is String && deviceId.isNotEmpty) {
    row['device_id'] = deviceId;
  }
  final updatedAt = document['updatedAt'] ?? document['updated_at'];
  if (updatedAt is String && updatedAt.isNotEmpty) {
    row['updated_at'] = updatedAt;
  }
  if (entity.localTable == 'audit_logs' && row['organization_id'] == null) {
    final org = '${organizationId ?? document['organizationId'] ?? ''}';
    if (org.isNotEmpty) row['organization_id'] = org;
  }
  return row;
}
