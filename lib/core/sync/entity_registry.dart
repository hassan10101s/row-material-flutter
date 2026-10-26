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
    this.pkColumn = 'id',
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

  /// Name of the local table's primary-key column.
  ///
  /// Almost every synced table calls it `id`; the user-authored QC tables
  /// (`qc_custom_table*`) do not — their keys are `table_id`/`field_id`/
  /// `row_id`. Every place the sync stack addresses the local row (queue
  /// settlement, pull apply, auto-rebase, backfill) must go through this
  /// instead of writing `id` verbatim: `UPDATE qc_custom_tables ... WHERE
  /// id = ?` is a "no such column" on those tables, and it would leave the
  /// local row permanently `queued` after every successful push.
  final String pkColumn;

  /// Remote document id derived from a local row.
  final String Function(Map<String, dynamic> row) docId;

  /// Fields a client is allowed to change after creation — must match the
  /// Fields a client is allowed to change after creation — m must match the
  /// `hasOnly([...])` list in `firestore.rules` for this collection.
  final Set<String> mutableFields;

  /// Append-only collections are never updated or deleted remotely.
  final bool appendOnly;

  /// Permission required to push this entity.
  final String? permission;

  /// Optional payload shaping (defaults to snake→amel row copy).
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

/// Shared business records and configuration. Device preferences stay local.
final List<SyncEntity> syncEntities = [
  for (final spec in const [
    (
      'parameter',
      SyncCollection.parameters,
      'parameters',
      'id',
      'lab_results.update',
    ),
    (
      'materialBound',
      SyncCollection.materialBounds,
      'material_parameter_bounds',
      'id',
      'lab_results.update',
    ),
    (
      'organizationSetting',
      SyncCollection.organizationSettings,
      'organization_settings',
      'id',
      'reports.create',
    ),
    ('qcSop', SyncCollection.qcSops, 'qc_sops', 'sop_id', 'qc.write'),
    (
      'qcSopRevision',
      SyncCollection.qcSopRevisions,
      'qc_sop_revisions',
      'rev_id',
      'qc.write',
    ),
    ('qcSopRead', SyncCollection.qcSopReads, 'qc_sop_reads', 'id', 'qc.write'),
  ])
    SyncEntity(
      type: spec.$1,
      collection: spec.$2,
      localTable: spec.$3,
      pkColumn: spec.$4,
      naturalKeyIdentity: true,
      usesLocalIdAsRef: false,
      docId: remoteIdDocId,
      permission: spec.$5,
      mutableFields: const {},
    ),
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
      'batchRemoteId',
      'batchEntryCode',
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
    type: 'nutritionFormulation',
    collection: SyncCollection.labConfig,
    localTable: 'nutrition_formulations',
    naturalKeyIdentity: true,
    docId: (row) => 'nf_${row['remote_id'] ?? row['id']}',
    accepts: (document) => document.id.startsWith('nf_'),
    permission: 'formulations.update',
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
      'roles',
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
    type: 'inventoryLot',
    collection: SyncCollection.inventoryLots,
    localTable: 'inventory_lots',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'lab_results.update',
    mutableFields: {
      'inventoryRemoteId',
      'lotNo',
      'qtyReceived',
      'qtyRemaining',
      'expiryDate',
      'supplier',
      'note',
      'receivedAt',
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
      'serialNumber',
      'description',
      'lastCalibrationDate',
      'nextCalibrationDate',
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
  // NIR فلديشن settings: each reset appends a new row, and the doc id
  // (`lc_nir_validation_settings_<id>`) keeps the row↔doc mapping so the
  // same-content seeds converge version-wise like the other lab-config
  // tables. Never updated or tombstoned by the app.
  SyncEntity(
    type: 'nirValidationSettings',
    collection: SyncCollection.labConfig,
    localTable: 'nir_validation_settings',
    docId: labConfigDocId('nir_validation_settings'),
    accepts: labConfigSelector('nir_validation_settings'),
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
  // ── QC user-authored tables (the QC settings feature). The first QC
  // family in the sync scope: `remote_id` is the doc id, parents are
  // pushed as definitions before columns before rows (see
  // `PullWorker._dependenciesFirst`), and each child stamps its parent's
  // `remote_id` (`tableRemoteId`) so `resolveRemoteRowRefs` can remap the
  // per-device `table_id` foreign key. Row payloads carry `valuesJson`
  // whose keys are the COLUMN remote ids — device-independent on purpose.
  SyncEntity(
    type: 'qcCustomTable',
    collection: SyncCollection.qcCustomTables,
    localTable: 'qc_custom_tables',
    pkColumn: 'table_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'title',
      'description',
      'sortOrder',
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
    type: 'qcCustomTableField',
    collection: SyncCollection.qcCustomTableFields,
    localTable: 'qc_custom_table_fields',
    pkColumn: 'field_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'tableId',
      'tableRemoteId',
      'label',
      'colType',
      'required',
      'sortOrder',
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
    type: 'qcCustomTableRow',
    collection: SyncCollection.qcCustomTableRows,
    localTable: 'qc_custom_table_rows',
    pkColumn: 'row_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'tableId',
      'tableRemoteId',
      'valuesJson',
      'note',
      'recordedAt',
      'recordedBy',
      'recordedByName',
      'localId',
      'remoteId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  // ── QC checklists + execution + NCR/CAPA (plan P8). Same contract as
  // the custom tables above: `remote_id` is the doc id, children stamp their
  // parent's remote identity (`templateRemoteId`, `inspectionRemoteId`, ...)
  // and `resolveRemoteRowRefs` remaps the per-device autoincrement foreign
  // keys on pull. `qc_templates` and `qc_inspections` carry a business
  // `version` column that collides with the sync envelope field of the same
  // name — the business value travels under `businessVersion` (special case
  // in `buildRemotePayload` / `remoteToLocalRow`).
  SyncEntity(
    type: 'qcTemplate',
    collection: SyncCollection.qcTemplates,
    localTable: 'qc_templates',
    pkColumn: 'template_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'name',
      'code',
      'type',
      'dept',
      'site',
      'category',
      'description',
      'isPublished',
      'isArchived',
      'requiresApprovalOnSubmit',
      'allowNa',
      'enforceEvidenceOnFail',
      'blockSubmitIfCriticalFail',
      'ownerId',
      'publishedBy',
      'publishedAt',
      'effectiveDate',
      'expiryDate',
      'tags',
      'revisionNote',
      'recurrence',
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
    type: 'qcSection',
    collection: SyncCollection.qcSections,
    localTable: 'qc_sections',
    pkColumn: 'section_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'templateId',
      'templateRemoteId',
      'title',
      'description',
      'orderIndex',
      'isCollapsible',
      'requiredAll',
      'conditionalRuleJson',
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
    type: 'qcItem',
    collection: SyncCollection.qcItems,
    localTable: 'qc_items',
    pkColumn: 'item_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'sectionId',
      'sectionRemoteId',
      'templateId',
      'templateRemoteId',
      'label',
      'itemType',
      'orderIndex',
      'required',
      'allowNa',
      'isCritical',
      'requireEvidenceIfFail',
      'requireEvidenceIfValue',
      'defaultValue',
      'optionsJson',
      'unit',
      'minValue',
      'maxValue',
      'tolerance',
      'toleranceType',
      'validationRuleJson',
      'conditionalShowJson',
      'failTriggerJson',
      'helpText',
      'defectCode',
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
    type: 'qcInspection',
    collection: SyncCollection.qcInspections,
    localTable: 'qc_inspections',
    pkColumn: 'inspection_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'templateId',
      'templateRemoteId',
      'templateVersion',
      'refType',
      'refId',
      'lotNo',
      'batchNo',
      'poNo',
      'grnNo',
      'qtyInspected',
      'qtyUnit',
      'dept',
      'site',
      'location',
      'line',
      'workCenter',
      'status',
      'resultOverall',
      'scorePct',
      'hasNc',
      'ncCount',
      'criticalNcCount',
      'majorNcCount',
      'minorNcCount',
      'inspectorId',
      'inspectorName',
      'reviewerId',
      'reviewerName',
      'approvedBy',
      'approvedByName',
      'submittedAt',
      'reviewedAt',
      'approvedAt',
      'rejectedAt',
      'closedAt',
      'inspectionDate',
      'startAt',
      'endAt',
      'shift',
      'remarks',
      'reviewComments',
      'rejectionReason',
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
    type: 'qcResponse',
    collection: SyncCollection.qcResponses,
    localTable: 'qc_responses',
    pkColumn: 'resp_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'inspectionId',
      'inspectionRemoteId',
      'itemId',
      'itemRemoteId',
      'sectionId',
      'sectionRemoteId',
      'result',
      'value',
      'valueType',
      'notes',
      'photosJson',
      'signatureBase64',
      'measuredAt',
      'measuredValue',
      'defectCode',
      'isCriticalFailure',
      'answeredBy',
      'answeredByName',
      'localId',
      'remoteId',
      'version',
      'updatedAt',
      'updatedBy',
      'deviceId',
      'deletedAt',
    },
  ),
  // Append-only done-log (زر إنجاز المهمة): one row per press, no edit path,
  // so only `create` is legal in the rules and on push.
  SyncEntity(
    type: 'qcTaskLog',
    collection: SyncCollection.qcTaskLogs,
    localTable: 'qc_task_log',
    pkColumn: 'log_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    appendOnly: true,
    mutableFields: const <String>{},
  ),
  SyncEntity(
    type: 'qcFindingNc',
    collection: SyncCollection.qcFindingsNc,
    localTable: 'qc_findings_nc',
    pkColumn: 'finding_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'inspectionId',
      'inspectionRemoteId',
      'itemId',
      'itemRemoteId',
      'respId',
      'respRemoteId',
      'code',
      'severity',
      'category',
      'description',
      'status',
      'type',
      'dueDate',
      'assignedTo',
      'assignedToName',
      'assignedAt',
      'rootCause',
      'actionPlan',
      'proposedAction',
      'qtyAffected',
      'qtyUnit',
      'disposition',
      'verifiedBy',
      'verifiedByName',
      'verifiedAt',
      'closedAt',
      'closedBy',
      'rejectedAt',
      'rejectionReason',
      'evidenceJson',
      'capaId',
      'capaRemoteId',
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
    type: 'qcCapa',
    collection: SyncCollection.qcCapa,
    localTable: 'qc_capa',
    pkColumn: 'capa_id',
    naturalKeyIdentity: true,
    docId: remoteIdDocId,
    permission: 'qc.write',
    mutableFields: {
      'findingId',
      'findingRemoteId',
      'capaNo',
      'type',
      'title',
      'description',
      'rootCause',
      'rootCauseMethod',
      'actionPlan',
      'actionStepsJson',
      'assignedTo',
      'assignedToName',
      'dept',
      'status',
      'priority',
      'dueAt',
      'targetCompletionAt',
      'actionCompletedAt',
      'actionCompletedBy',
      'actionCompletionNotes',
      'verifiedBy',
      'verifiedByName',
      'verifiedAt',
      'verificationNotes',
      'isEffective',
      'effectivenessCheckedAt',
      'effectivenessNotes',
      'closureNotes',
      'closedAt',
      'closedBy',
      'rejectedAt',
      'rejectionReason',
      'evidenceJson',
      'localId',
      'remoteId',
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

/// Local row → remote document payload.
///
/// Rules of the mapping (plan Â§6.1/Â§6.2):
///  * column names are converted snake_case → camelCase,
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
    if (entry.key == entity.pkColumn) {
      payload['localId'] = entry.value;
      continue;
    }
    final camel = _toCamel(entry.key);
    if (entity.type == 'member' && camel == 'rolesJson') continue;
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
  if (entity.type == 'member') {
    Object? roles;
    try {
      roles = jsonDecode('${row['roles_json'] ?? ''}');
    } on FormatException {
      roles = null;
    }
    payload['roles'] = roles is List && roles.isNotEmpty
        ? roles
        : [payload['role'] ?? 'viewer'];
  }
  final builder = entity.payloadBuilder;
  if (builder != null) {
    final custom = builder(row, ctx);
    payload
      ..clear()
      ..addAll(custom);
  }

  payload['organizationId'] = ctx.organizationId;
  payload['localId'] = row[entity.pkColumn];
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
  if (entity.collection == SyncCollection.labConfig && !asCreate) {
    payload.remove('createdBy');
  }
  // These records can be maintained by another authorized member on the
  // writing device. Preserve the server's immutable creator on partial updates.
  if (const {
    'parameter',
    'materialBound',
    'organizationSetting',
    'qcSop',
    'qcSopRevision',
    'qcSopRead',
  }.contains(entity.type)) {
    if (!asCreate) {
      payload.remove('createdBy');
    } else if (row['created_by'] is String) {
      payload['createdBy'] = row['created_by'];
    }
  }
  // `qc_templates` / `qc_inspections` carry a BUSINESS `version` column (a
  // checklist revision number, incremented on every save/duplicate). The
  // envelope `version` overwrites that key below, so the business value
  // travels under `businessVersion` and `remoteToLocalRow` restores it.
  if (entity.localTable == 'qc_templates' ||
      entity.localTable == 'qc_inspections') {
    payload['businessVersion'] = (row['version'] as num?) ?? 1;
  }
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
  // The real mapping (users.id → Firebase uid) is injected by the sync engine
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

/// One QC child foreign key that must be remapped to this device's local ids.
class QcFkSpec {
  const QcFkSpec({
    required this.refColumn,
    required this.stampColumn,
    required this.parentTable,
    required this.parentPk,
    required this.parentType,
    this.isRequired = true,
  });

  /// Local column carrying the origin device's parent pk (nullable for
  /// optional links — `qc_findings_nc.inspection_id` etc.).
  final String refColumn;

  /// Stamp column carrying the parent's cross-device `remote_id`.
  final String stampColumn;
  final String parentTable;
  final String parentPk;

  /// `SyncEntity.type` of the parent, used by `MissingParentException` so the
  /// end-of-cycle retry can fetch and apply the parent first.
  final String parentType;

  /// Whether the local column is NOT NULL (the link is required): an
  /// unresolvable required parent throws [MissingParentException] (transient
  /// retry), an unresolvable optional parent is dropped to NULL locally.
  final bool isRequired;

  String get stampFieldCamel => _toCamel(stampColumn);
}

/// Foreign keys of every QC child table (plan P8), keyed by local table.
/// Written children stamp their parents' remote ids; legacy children pushed
/// before the stamp columns existed are resolved through the deterministic
/// backfill names (`legacy_<parentTable>_<id>`) that `_backfillRemoteIds`
/// wrote on the origin device's parents.
const Map<String, List<QcFkSpec>> _qcChildFks = {
  'lab_analysis_items': [
    QcFkSpec(
      refColumn: 'inventory_id',
      stampColumn: 'inventory_remote_id',
      parentTable: 'lab_inventory',
      parentPk: 'id',
      parentType: 'inventoryItem',
    ),
  ],
  'lab_field_chemical_links': [
    QcFkSpec(
      refColumn: 'inventory_id',
      stampColumn: 'inventory_remote_id',
      parentTable: 'lab_inventory',
      parentPk: 'id',
      parentType: 'inventoryItem',
      isRequired: false,
    ),
  ],
  'lab_material_analyses': [
    QcFkSpec(
      refColumn: 'material_id',
      stampColumn: 'material_remote_id',
      parentTable: 'reference_materials',
      parentPk: 'id',
      parentType: 'referenceMaterial',
    ),
  ],
  'lab_analyses': [
    QcFkSpec(
      refColumn: 'parameter_id',
      stampColumn: 'parameter_remote_id',
      parentTable: 'parameters',
      parentPk: 'id',
      parentType: 'parameter',
      isRequired: false,
    ),
  ],
  'qc_sop_revisions': [
    QcFkSpec(
      refColumn: 'sop_id',
      stampColumn: 'sop_remote_id',
      parentTable: 'qc_sops',
      parentPk: 'sop_id',
      parentType: 'qcSop',
    ),
  ],
  'qc_sop_reads': [
    QcFkSpec(
      refColumn: 'sop_id',
      stampColumn: 'sop_remote_id',
      parentTable: 'qc_sops',
      parentPk: 'sop_id',
      parentType: 'qcSop',
    ),
  ],
  'material_parameter_bounds': [
    QcFkSpec(
      refColumn: 'material_id',
      stampColumn: 'material_remote_id',
      parentTable: 'reference_materials',
      parentPk: 'id',
      parentType: 'referenceMaterial',
    ),
    QcFkSpec(
      refColumn: 'parameter_id',
      stampColumn: 'parameter_remote_id',
      parentTable: 'parameters',
      parentPk: 'id',
      parentType: 'parameter',
    ),
  ],
  'qc_sections': [
    QcFkSpec(
      refColumn: 'template_id',
      stampColumn: 'template_remote_id',
      parentTable: 'qc_templates',
      parentPk: 'template_id',
      parentType: 'qcTemplate',
    ),
  ],
  'qc_items': [
    QcFkSpec(
      refColumn: 'section_id',
      stampColumn: 'section_remote_id',
      parentTable: 'qc_sections',
      parentPk: 'section_id',
      parentType: 'qcSection',
    ),
    QcFkSpec(
      refColumn: 'template_id',
      stampColumn: 'template_remote_id',
      parentTable: 'qc_templates',
      parentPk: 'template_id',
      parentType: 'qcTemplate',
    ),
  ],
  'qc_inspections': [
    QcFkSpec(
      refColumn: 'template_id',
      stampColumn: 'template_remote_id',
      parentTable: 'qc_templates',
      parentPk: 'template_id',
      parentType: 'qcTemplate',
    ),
  ],
  'qc_responses': [
    QcFkSpec(
      refColumn: 'inspection_id',
      stampColumn: 'inspection_remote_id',
      parentTable: 'qc_inspections',
      parentPk: 'inspection_id',
      parentType: 'qcInspection',
    ),
    QcFkSpec(
      refColumn: 'item_id',
      stampColumn: 'item_remote_id',
      parentTable: 'qc_items',
      parentPk: 'item_id',
      parentType: 'qcItem',
    ),
    QcFkSpec(
      refColumn: 'section_id',
      stampColumn: 'section_remote_id',
      parentTable: 'qc_sections',
      parentPk: 'section_id',
      parentType: 'qcSection',
    ),
  ],
  'qc_task_log': [
    QcFkSpec(
      refColumn: 'inspection_id',
      stampColumn: 'inspection_remote_id',
      parentTable: 'qc_inspections',
      parentPk: 'inspection_id',
      parentType: 'qcInspection',
    ),
    QcFkSpec(
      refColumn: 'template_id',
      stampColumn: 'template_remote_id',
      parentTable: 'qc_templates',
      parentPk: 'template_id',
      parentType: 'qcTemplate',
    ),
    QcFkSpec(
      refColumn: 'item_id',
      stampColumn: 'item_remote_id',
      parentTable: 'qc_items',
      parentPk: 'item_id',
      parentType: 'qcItem',
    ),
  ],
  'qc_findings_nc': [
    QcFkSpec(
      refColumn: 'inspection_id',
      stampColumn: 'inspection_remote_id',
      parentTable: 'qc_inspections',
      parentPk: 'inspection_id',
      parentType: 'qcInspection',
      // All finding links are nullable by schema (standalone findings, links
      // added after the fact, CAPA created after the finding).
      isRequired: false,
    ),
    QcFkSpec(
      refColumn: 'item_id',
      stampColumn: 'item_remote_id',
      parentTable: 'qc_items',
      parentPk: 'item_id',
      parentType: 'qcItem',
      isRequired: false,
    ),
    QcFkSpec(
      refColumn: 'resp_id',
      stampColumn: 'resp_remote_id',
      parentTable: 'qc_responses',
      parentPk: 'resp_id',
      parentType: 'qcResponse',
      isRequired: false,
    ),
    QcFkSpec(
      refColumn: 'capa_id',
      stampColumn: 'capa_remote_id',
      parentTable: 'qc_capa',
      parentPk: 'capa_id',
      parentType: 'qcCapa',
      isRequired: false,
    ),
  ],
  'qc_capa': [
    QcFkSpec(
      refColumn: 'finding_id',
      stampColumn: 'finding_remote_id',
      parentTable: 'qc_findings_nc',
      parentPk: 'finding_id',
      parentType: 'qcFindingNc',
    ),
  ],
};

/// Published parent contract for the central validator and schema parity check.
List<QcFkSpec> sharedParentSpecs(SyncEntity entity) =>
    List<QcFkSpec>.unmodifiable(_qcChildFks[entity.localTable] ?? const []);

/// Stamp parent identities for both live writes and legacy backfill. Numeric
/// foreign keys are meaningful only inside their originating SQLite file.
Future<void> stampSharedParents(
  DatabaseExecutor txn,
  SyncEntity entity,
  Map<String, dynamic> row,
) async {
  if (entity.localTable == 'product_batch_samples') {
    final parents = await txn.query(
      'inspections',
      columns: const ['remote_id', 'entry_code'],
      where: "id = ? AND inspection_kind = 'product'",
      whereArgs: [row['batch_id']],
      limit: 1,
    );
    if (parents.isEmpty) {
      // An orphaned legacy row must not abort the entire backfill page.
      // PushWorker keeps this individual row pending until its real product
      // header is available; never fabricate a link to a raw inspection.
      return;
    }
    final parent = parents.single;
    row['batch_entry_code'] = '${parent['entry_code'] ?? ''}';
    final remote = '${parent['remote_id'] ?? ''}';
    // Legacy headers can still lack a remote id. Their entry code is the
    // actual Firestore document key and remains stable across devices.
    row['batch_remote_id'] = remote.isNotEmpty
        ? remote
        : row['batch_entry_code'];
    if (row['id'] != null) {
      await txn.update(
        'product_batch_samples',
        {
          'batch_remote_id': row['batch_remote_id'],
          'batch_entry_code': row['batch_entry_code'],
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    return;
  }
  for (final fk in _qcChildFks[entity.localTable] ?? const <QcFkSpec>[]) {
    final id = row[fk.refColumn];
    if (id == null) continue;
    final parents = await txn.query(
      fk.parentTable,
      columns: [fk.parentPk, 'remote_id'],
      where: '${fk.parentPk} = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (parents.isEmpty) continue;
    var remote = '${parents.first['remote_id'] ?? ''}';
    if (remote.isEmpty) {
      remote = 'legacy_${fk.parentTable}_$id';
      await txn.update(
        fk.parentTable,
        {'remote_id': remote},
        where: '${fk.parentPk} = ?',
        whereArgs: [id],
      );
    }
    row[fk.stampColumn] = remote;
  }
}

/// Remap the per-device parent keys of a QC child row, in place (plan P8).
///
/// For every link: the parent's cross-device identity comes from the stamp
/// column (`template_remote_id` etc., carried by the payload), falling back
/// to the deterministic `legacy_<parentTable>_<id>` backfill name for rows
/// pushed before the stamping existed. A missing *required* parent throws
/// [MissingParentException] so the cycle retries after fetching it; an
/// unresolvable *optional* parent is dropped to NULL on this device — the
/// linkage is lost, the row itself is kept (never link the wrong parent, the
/// per-device autoincrement ids collide by construction).
Future<void> _resolveQcFks(
  DatabaseExecutor txn,
  Map<String, dynamic> resolved,
  Map<String, dynamic> doc,
  List<QcFkSpec> fks,
) async {
  for (final fk in fks) {
    final link = (resolved[fk.refColumn] as num?)?.toInt();
    if (link == null || link <= 0) {
      resolved[fk.refColumn] = null;
      continue;
    }
    var parentRemote =
        '${doc[fk.stampFieldCamel] ?? doc[fk.stampColumn] ?? resolved[fk.stampColumn] ?? ''}';
    if (parentRemote.isEmpty) {
      parentRemote = 'legacy_${fk.parentTable}_$link';
    }
    final parent = await txn.query(
      fk.parentTable,
      columns: [fk.parentPk],
      where: 'remote_id = ?',
      whereArgs: [parentRemote],
      limit: 1,
    );
    if (parent.isEmpty) {
      if (!fk.isRequired) {
        // Optional by schema (standalone findings, links added after the
        // fact): keep the row, drop the dangling pointer.
        resolved[fk.refColumn] = null;
        continue;
      }
      throw MissingParentException(
        fk.parentType,
        parentRemote,
        '${fk.parentTable} $parentRemote not synced yet',
      );
    }
    resolved[fk.refColumn] = (parent.first[fk.parentPk] as num).toInt();
    resolved[fk.stampColumn] = parentRemote;
  }
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
    if (entity.localTable == 'qc_sops' && column == 'created_by') continue;
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
    final parentRemote =
        '${doc['equipmentRemoteId'] ?? doc['equipment_remote_id'] ?? resolved['equipment_remote_id'] ?? ''}';
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
      throw MissingParentException(
        'equipment',
        parentRemote,
        'lab equipment $parentRemote not synced yet',
      );
    }
    resolved['equipment_id'] = (parent.first['id'] as num).toInt();
    resolved['equipment_remote_id'] = parentRemote;
    return;
  }

  if (entity.localTable == 'inventory_lots') {
    // Same cross-device parent rule as equipment events: `inventory_id` is
    // per-device, so remap through `inventory_remote_id` stamped at receive
    // time. Missing parent => transient: the item lands in the same cycle.
    var parentRemote =
        '${doc['inventoryRemoteId'] ?? doc['inventory_remote_id'] ?? resolved['inventory_remote_id'] ?? ''}';
    if (parentRemote.isEmpty) {
      // Legacy rows pushed before the parent-identity stamping carry no
      // parent link in their payload. Salvage, in order:
      //  1. this device's own lot row (matched by the doc's remote id),
      //     whose healed `inventory_remote_id` the open-time guarantee
      //     (`_healLegacyLotParentIds`) filled from the parent item;
      //  2. the deterministic legacy backfill name of the parent item
      //     (`legacy_lab_inventory_<id>`) that `_backfillRemoteIds` wrote on
      //     the origin device for the same legacy roll.
      final ownRemote = '${resolved['remote_id'] ?? ''}';
      if (ownRemote.isNotEmpty) {
        final mine = await txn.query(
          'inventory_lots',
          columns: const ['inventory_remote_id'],
          where: 'remote_id = ?',
          whereArgs: [ownRemote],
          limit: 1,
        );
        if (mine.isNotEmpty) {
          parentRemote = '${mine.first['inventory_remote_id'] ?? ''}';
        }
      }
      if (parentRemote.isEmpty) {
        final legacyItem = (resolved['inventory_id'] as num?)?.toInt();
        if (legacyItem != null && legacyItem > 0) {
          parentRemote = 'legacy_lab_inventory_$legacyItem';
        }
      }
    }
    if (parentRemote.isEmpty) {
      throw StateError('transient: inventory lot without parent identity');
    }
    final parent = await txn.query(
      'lab_inventory',
      columns: const ['id'],
      where: 'remote_id = ?',
      whereArgs: [parentRemote],
      limit: 1,
    );
    if (parent.isEmpty) {
      throw MissingParentException(
        'inventoryItem',
        parentRemote,
        'lab inventory $parentRemote not synced yet',
      );
    }
    resolved['inventory_id'] = (parent.first['id'] as num).toInt();
    resolved['inventory_remote_id'] = parentRemote;
    return;
  }

  if (entity.localTable == 'lab_consumption_log') {
    // Lot linkage is per-device: remap `lot_id` through the stamped
    // `lot_remote_id`. Unresolvable (lot not synced yet, or a legacy row
    // without one) => keep the human-readable `lot_no` snapshot and clear
    // the pointer rather than linking the wrong lot. `inventory_id` keeps
    // its historical behavior (written raw, like the other ledger tables).
    final lotRemote =
        '${doc['lotRemoteId'] ?? doc['lot_remote_id'] ?? resolved['lot_remote_id'] ?? ''}';
    if (lotRemote.isEmpty) {
      resolved['lot_id'] = null;
      return;
    }
    final lot = await txn.query(
      'inventory_lots',
      columns: const ['id', 'inventory_id'],
      where: 'remote_id = ?',
      whereArgs: [lotRemote],
      limit: 1,
    );
    if (lot.isEmpty) {
      resolved['lot_id'] = null;
      return;
    }
    resolved['lot_id'] = (lot.first['id'] as num).toInt();
    resolved['lot_remote_id'] = lotRemote;
    return;
  }

  if (entity.localTable == 'qc_custom_table_fields' ||
      entity.localTable == 'qc_custom_table_rows') {
    // Children of a user-authored table: `table_id` is the origin device's
    // autoincrement id, so remap through the cross-device parent identity
    // (`table_remote_id`, stamped by the QC facade at write time). A
    // missing parent is transient — the table lands in the same cycle —
    // and throws so the end-of-cycle retry re-applies verbatim.
    final parentPk = SyncEntity.byType('qcCustomTable')?.pkColumn ?? 'id';
    final parentRemote =
        '${doc['tableRemoteId'] ?? doc['table_remote_id'] ?? resolved['table_remote_id'] ?? ''}';
    if (parentRemote.isEmpty) {
      throw StateError(
        'transient: QC custom table child without parent identity',
      );
    }
    final parent = await txn.query(
      'qc_custom_tables',
      columns: [parentPk],
      where: 'remote_id = ?',
      whereArgs: [parentRemote],
      limit: 1,
    );
    if (parent.isEmpty) {
      throw MissingParentException(
        'qcCustomTable',
        parentRemote,
        'qc custom table $parentRemote not synced yet',
      );
    }
    resolved['table_id'] = (parent.first[parentPk] as num).toInt();
    resolved['table_remote_id'] = parentRemote;
    return;
  }

  final qcFks = _qcChildFks[entity.localTable];
  if (qcFks != null) {
    await _resolveQcFks(txn, resolved, doc, qcFks);
    return;
  }

  if (entity.localTable == 'product_batch_samples') {
    final entryCode =
        '${doc['batchEntryCode'] ?? doc['batch_entry_code'] ?? ''}'.trim();
    if (entryCode.isNotEmpty) {
      final parents = await txn.query(
        'inspections',
        columns: const ['id', 'remote_id'],
        where: "entry_code = ? AND inspection_kind = 'product'",
        whereArgs: [entryCode],
        limit: 1,
      );
      if (parents.isEmpty) {
        throw MissingParentException(
          'sample',
          entryCode,
          'product batch $entryCode not synced yet',
        );
      }
      final parent = parents.single;
      resolved['batch_id'] = (parent['id'] as num).toInt();
      resolved['batch_entry_code'] = entryCode;
      final remote =
          '${doc['batchRemoteId'] ?? doc['batch_remote_id'] ?? parent['remote_id'] ?? ''}';
      resolved['batch_remote_id'] = remote.isEmpty ? entryCode : remote;
      return;
    }
    // `batch_id` references the product `inspections` header row: a
    // per-device autoincrement id. The writer stamps `batch_remote_id` (=
    // the header's remote_id, `legacy_inspections_<id>` for legacy
    // batches) at create time and the receiving device remaps through it.
    // A missing parent is transient — the batch header lands in the same
    // cycle or an earlier push — so the end-of-cycle retry re-applies.
    var parentRemote =
        '${doc['batchRemoteId'] ?? doc['batch_remote_id'] ?? resolved['batch_remote_id'] ?? ''}';
    if (parentRemote.isEmpty) {
      // Payloads pushed before the parent-identity stamp existed: salvage,
      // in order (same shape as the inventory-lot salvage above):
      //  1. this device's own healed row (matched by the doc's remote id),
      //     whose `batch_remote_id` the open-time guarantee
      //     (`_healBatchSampleParentIds`) filled from the parent inspection;
      //  2. the same row's `batch_id` → its parent inspection's `remote_id`,
      //     when the open-time guarantee has not run yet in this transaction
      //     or ran while the parent had no remote_id of its own;
      //  3. the deterministic legacy backfill name of the parent inspection
      //     (`legacy_inspections_<id>`) that `_backfillRemoteIds` wrote on
      //     the origin device: on an unstamped payload `batchId` is the
      //     origin device's per-device inspections pk, and that row's
      //     remote id is exactly that name. Only used when such a parent
      //     row actually exists, so a foreign doc can never bind a wrong
      //     batch (a missing parent stays a transient refusal).
      final ownRemote = '${resolved['remote_id'] ?? ''}';
      if (ownRemote.isNotEmpty) {
        final mine = await txn.query(
          'product_batch_samples',
          columns: const ['batch_id', 'batch_remote_id'],
          where: 'remote_id = ?',
          whereArgs: [ownRemote],
          limit: 1,
        );
        if (mine.isNotEmpty) {
          parentRemote = '${mine.first['batch_remote_id'] ?? ''}';
          if (parentRemote.isEmpty) {
            final ownBatch = (mine.first['batch_id'] as num?)?.toInt() ?? 0;
            if (ownBatch > 0) {
              final parent = await txn.query(
                'inspections',
                columns: const ['remote_id'],
                where: 'id = ?',
                whereArgs: [ownBatch],
                limit: 1,
              );
              if (parent.isNotEmpty) {
                parentRemote = '${parent.first['remote_id'] ?? ''}';
              }
            }
          }
        }
      }
      if (parentRemote.isEmpty) {
        final legacyBatch = (resolved['batch_id'] as num?)?.toInt() ?? 0;
        if (legacyBatch > 0) {
          final parent = await txn.query(
            'inspections',
            columns: const ['id'],
            where: 'remote_id = ?',
            whereArgs: ['legacy_inspections_$legacyBatch'],
            limit: 1,
          );
          if (parent.isNotEmpty) {
            parentRemote = 'legacy_inspections_$legacyBatch';
          }
        }
      }
    }
    if (parentRemote.isEmpty) {
      throw StateError(
        'transient: product batch sample without parent identity',
      );
    }
    final parent = await txn.query(
      'inspections',
      columns: const ['id'],
      where: "remote_id = ? AND inspection_kind = 'product'",
      whereArgs: [parentRemote],
      limit: 1,
    );
    if (parent.isEmpty) {
      throw StateError('transient: product batch $parentRemote not synced yet');
    }
    resolved['batch_id'] = (parent.first['id'] as num).toInt();
    resolved['batch_remote_id'] = parentRemote;
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

/// A pulled document cannot be applied because its cross-device parent row is
/// still missing locally — e.g. an inventory lot whose inventory item has not
/// landed yet ("transient" by design: the parent usually lands earlier in the
/// same cycle or by a later push).
///
/// Names the parent's [SyncEntity] type and the parent's remote id — for the
/// `remoteIdDocId` parents this is exactly the parent's Firestore document id
/// — so the end-of-cycle retry in `PullWorker` can fetch the parent from the
/// server and apply it before re-applying the child. Without that repair a
/// child whose parent never reached this device (a legacy origin whose item
/// push was parked as a conflict, or a parent skipped on a divergent
/// identity) re-fails once per cycle forever.
class MissingParentException implements Exception {
  const MissingParentException(
    this.parentEntity,
    this.parentRemoteId,
    this.message,
  );

  /// `SyncEntity.type` of the missing parent.
  final String parentEntity;

  /// The parent's cross-device identity (`remote_id`, == its document id for
  /// the `remoteIdDocId` entities).
  final String parentRemoteId;

  final String message;

  @override
  String toString() => 'transient: $message';
}

/// Removes the stale local rows that still hold the business [key] of an
/// `organization_settings` write, except the row identified by [keepLocalId].
///
/// `organization_settings.key` is UNIQUE across the whole table, while the
/// remote identity (`remote_id`) of the matched row can diverge from the
/// previously applied sibling that still holds this key (a setting created on
/// both devices before the organization was bound, or a key that was edited
/// remotely while a same-key sibling existed locally). The raw UPDATE then
/// aborts with code 2067 on every cycle and the document never applies.
/// Business semantics — one row per key, the remote copy is authoritative —
/// make the repair trivial: the row that keeps the write is the one that owns
/// the document's identity; the throwaway duplicate is deleted. The mirror
/// triggers keep the local `settings` copy in step automatically.
Future<void> dropStaleOrgSettingSiblings(
  DatabaseExecutor txn, {
  required Object? key,
  Object? keepLocalId,
}) async {
  final namedKey = '$key';
  if (namedKey.isEmpty || keepLocalId == null) return;
  final siblings = await txn.query(
    'organization_settings',
    columns: const ['id'],
    where: 'key = ?',
    whereArgs: [namedKey],
  );
  for (final sibling in siblings) {
    final siblingId = sibling['id'];
    if (siblingId == null || siblingId == keepLocalId) continue;
    await txn.delete(
      'organization_settings',
      where: 'id = ?',
      whereArgs: [siblingId],
    );
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
      // The document id IS the row's cross-device identity (`remote_id`,
      // comprehensive sync plan §1): match against that column, never against
      // the per-device autoincrement pk. `id = <uuid>` never matched anything,
      // so every cross-device update/delete fell through to the fragile
      // natural-key fallback (or silently no-op'd for tombstones, which carry
      // no business fields at all).
      final byRemote = await db.query(
        entity.localTable,
        columns: [entity.pkColumn],
        where: 'remote_id = ?',
        whereArgs: [entityId],
        limit: 1,
      );
      if (byRemote.isNotEmpty) {
        return (byRemote.first[entity.pkColumn] as num).toInt();
      }
      final payloadRemote = data['remoteId'] ?? data['remote_id'];
      if (payloadRemote is String &&
          payloadRemote.isNotEmpty &&
          payloadRemote != entityId) {
        final byPayload = await db.query(
          entity.localTable,
          columns: [entity.pkColumn],
          where: 'remote_id = ?',
          whereArgs: [payloadRemote],
          limit: 1,
        );
        if (byPayload.isNotEmpty) {
          return (byPayload.first[entity.pkColumn] as num).toInt();
        }
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
  // Identity hint carried by the document payload (may be empty).
  String payloadRemoteId = '';
  final payloadRemoteHint = data['remoteId'] ?? data['remote_id'];
  if (payloadRemoteHint is String) payloadRemoteId = payloadRemoteHint;
  final natural = _naturalKey(entity, entityId, data);
  if (entity.usesLocalIdAsRef &&
      localId is num &&
      (!foreign || natural == null)) {
    // Read `remote_id` alongside the pk when the column exists: the
    // coherence check below is the whole point of the pre-selection.
    var selectCols = <String>[entity.pkColumn];
    try {
      final names = (await db.rawQuery(
        'PRAGMA table_info(${entity.localTable})',
      )).map((e) => '${e['name']}').toSet();
      if (names.contains('remote_id')) {
        selectCols = [entity.pkColumn, 'remote_id'];
      }
    } on Object {
      // Legacy file: keep the plain pk select.
    }
    final rows = await db.query(
      entity.localTable,
      columns: selectCols,
      where: '${entity.pkColumn} = ?',
      whereArgs: [localId.toInt()],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      final candidate = rows.first;
      // Identity coherence: autoincrement ids collide across devices by
      // construction, so a foreign `localId` can point at an unrelated local
      // row. Accept the match only when the candidate has no cross-device
      // identity of its own (legacy row) or when it agrees with the document.
      // Otherwise fall through to the natural key / fresh-insert paths —
      // never overwrite a row that holds a different remote_id.
      final rowRemote = '${candidate['remote_id'] ?? ''}';
      final coherent =
          rowRemote.isEmpty ||
          rowRemote == entityId ||
          rowRemote == payloadRemoteId;
      if (!foreign || coherent) {
        return (candidate[entity.pkColumn] as num).toInt();
      }
    }
  }
  if (natural == null) return null;
  final rows = await db.query(
    entity.localTable,
    columns: [entity.pkColumn],
    where: natural.$1,
    whereArgs: natural.$2,
    limit: 1,
  );
  return rows.isEmpty ? null : (rows.first[entity.pkColumn] as num).toInt();
}

/// `(where, args)` of the natural key of [entity]'s local table, or null when
/// the table has no usable one (then only `localId` can match).
(String, List<Object?>)? _naturalKey(
  SyncEntity entity,
  String entityId,
  Map<String, dynamic> data,
) {
  switch (entity.localTable) {
    case 'parameters':
      final name = data['parameterName'] ?? data['parameter_name'];
      return name is String && name.isNotEmpty
          ? ('parameter_name = ? COLLATE NOCASE', [name])
          : null;
    case 'organization_settings':
      final key = data['key'];
      return key is String && key.isNotEmpty ? ('key = ?', [key]) : null;
    case 'qc_sops':
      final code = data['code'];
      return code is String && code.isNotEmpty ? ('code = ?', [code]) : null;
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
      final parentRemote =
          data['equipmentRemoteId'] ?? data['equipment_remote_id'];
      final eventDate = data['eventDate'] ?? data['event_date'];
      if (parentRemote is! String || parentRemote.isEmpty) return null;
      if (eventDate == null) return null;
      return (
        'equipment_remote_id = ? AND event_date = ?',
        [parentRemote, eventDate],
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
      if (code is String && code.isNotEmpty) {
        return ('material_code = ?', [code]);
      }
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
  if (entity.type == 'member' && document['roles'] is List) {
    row['roles_json'] = jsonEncode(document['roles']);
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
  if (entity.localTable == 'qc_templates' ||
      entity.localTable == 'qc_inspections') {
    // Business `version` vs sync `version` (see `buildRemotePayload`): the
    // business revision number lands in the local `version` column, the sync
    // version stays in `remote_version` only. Documents pushed before this
    // convention existed carry no `businessVersion` — fall back to the
    // envelope value once; the next push stamps it and it converges.
    final business = document['businessVersion'];
    row['version'] = business is num ? business : document['version'];
  } else {
    row['version'] = document['version'];
  }
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
  // `createdAt` is write-once on the server, but the local mirror must keep it
  // too: `_withDefaults` otherwise stamps a row pulled from another device with
  // `nowIso()`, so a sample created last month shows today's date locally and
  // every receiver disagrees about when it was created. The envelope value wins
  // over the local default; the caller filters it against the real columns, so
  // tables without `created_at` (e.g. the qualityCheck history log) are
  // unaffected.
  final createdAt = document['createdAt'] ?? document['created_at'];
  if (createdAt is String && createdAt.isNotEmpty) {
    row['created_at'] = createdAt;
  }
  if (entity.localTable == 'audit_logs' && row['organization_id'] == null) {
    final org = '${organizationId ?? document['organizationId'] ?? ''}';
    if (org.isNotEmpty) row['organization_id'] = org;
  }
  return row;
}
