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
      'reportHtml',
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
int _payloadBytes(Map<String, dynamic> payload) =>
    SyncCodec.byteSize(payload);

Map<String, dynamic> _stripSyncColumns(Map<String, dynamic> row) {
  const syncColumns = {
    'version',
    'remote_version',
    'remote_synced_at',
    'sync_state',
    'deleted_at',
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
}) async {
  final localId = data['localId'];
  final docDeviceId = '${data['deviceId'] ?? ''}';
  final foreign = localDeviceId != null &&
      localDeviceId.isNotEmpty &&
      docDeviceId.isNotEmpty &&
      docDeviceId != localDeviceId;
  final natural = _naturalKey(entity, entityId, data);
  if (entity.usesLocalIdAsRef && localId is num && (!foreign || natural == null)) {
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
  if (entity.localTable == 'audit_logs' && row['organization_id'] == null) {
    final org = '${organizationId ?? document['organizationId'] ?? ''}';
    if (org.isNotEmpty) row['organization_id'] = org;
  }
  return row;
}
