import 'package:sqflite/sqflite.dart';

import '../../../core/sync/audit_logger.dart';
import '../../../core/sync/entity_registry.dart';
import '../../../core/sync/sync_queue.dart';
import '../../../core/sync/sync_write.dart' as sync_write;
import '../../organizations/data/member_write_guard.dart';

/// One static parent-identity stamp of a QC child table (see
/// [QcSyncWriter.stampParents]).
class ParentLinkRef {
  const ParentLinkRef(
    this.stampColumn,
    this.parentTable,
    this.parentPk,
    this.linkColumn,
  );

  /// The stamp column the writer sets (e.g. `template_remote_id`).
  final String stampColumn;

  /// The parent table and its primary key column.
  final String parentTable;
  final String parentPk;

  /// The child's own link column (e.g. `template_id`).
  final String linkColumn;
}

/// The sync seam of the QC facades (plan P8).
///
/// Every enqueue helper the QC write paths need in one class, mirroring the
/// contract [OfflineFirstQcCustomTablesRepository] already runs under:
///
///  * [stampedRow] — fresh row from disk with a guaranteed cross-device
///    identity (`remote_id`: UUID for new writes, `legacy_<table>_<pk>`
///    for rows written before the sync went live) written back to disk, so
///    the queue entry and the local row always agree.
///  * [parentRemoteId] — the parent's cross-device identity for the child
///    stamp columns (`template_remote_id`, `inspection_remote_id`, ...); the
///    parent row gets its identity stamped here too, because a legacy
///    parent that never pushed would leave the child unpullable.
///  * [enqueue] — `sync_write.enqueueLocalChange` inside the caller's
///    transaction, best-effort: the business write never rolls back because
///    the outbox hiccuped (the backfill repairs the bookkeeping later).
///
/// Sync is **guarded by default**: [enabled] requires a bound organization
/// and a signed-in uid (the same `WriteGuard` the facades authorise with).
class QcSyncWriter {
  QcSyncWriter({required this.queue, required this.guard, this.syncAudit});

  final SyncQueue queue;
  final WriteGuard guard;
  final AuditLogger? syncAudit;

  static SyncEntity _entity(String type) =>
      SyncEntity.byType(type) ??
      (throw StateError('Unknown sync entity: $type'));

  // ── Shared parent-stamp specs (write side of `_qcChildFks`) ───────────
  static const ParentLinkRef _templateLink = ParentLinkRef(
    'template_remote_id',
    'qc_templates',
    'template_id',
    'template_id',
  );
  static const ParentLinkRef _sectionLink = ParentLinkRef(
    'section_remote_id',
    'qc_sections',
    'section_id',
    'section_id',
  );
  static const ParentLinkRef _itemLink = ParentLinkRef(
    'item_remote_id',
    'qc_items',
    'item_id',
    'item_id',
  );
  static const ParentLinkRef _inspectionLink = ParentLinkRef(
    'inspection_remote_id',
    'qc_inspections',
    'inspection_id',
    'inspection_id',
  );
  static const ParentLinkRef _respLink = ParentLinkRef(
    'resp_remote_id',
    'qc_responses',
    'resp_id',
    'resp_id',
  );
  static const ParentLinkRef _findingLink = ParentLinkRef(
    'finding_remote_id',
    'qc_findings_nc',
    'finding_id',
    'finding_id',
  );

  /// Parent stamps per child entity type, keyed by the `SyncEntity.type`.
  static const Map<String, List<ParentLinkRef>> _parentLinks = {
    'qcSection': [_templateLink],
    'qcItem': [_sectionLink, _templateLink],
    'qcInspection': [_templateLink],
    'qcResponse': [_inspectionLink, _itemLink, _sectionLink],
    'qcTaskLog': [_inspectionLink, _templateLink, _itemLink],
    'qcFindingNc': [
      _inspectionLink,
      _itemLink,
      _respLink,
      // `capa_id` mirrors a CAPA created afterwards; the writer of the CAPA
      // does not update stale findings, so the stamp stays empty there and
      // the pull side drops the nullable pointer.
    ],
    'qcCapa': [_findingLink],
  };

  /// True when the row may be queued: organization bound + signed in. On a
  /// false return the facades skip synchronisation entirely (the backfill
  /// service re-queues the rows once an account binds).
  bool get enabled => guard.organizationId.isNotEmpty && guard.uid.isNotEmpty;

  /// Sentinel key [stampedRow] sets on the returned row when it had to mint
  /// the `remote_id` itself — proof the row was never pushed (a push back,
  /// a pull or an ack would have left an identity on it). [operationFor]
  /// reads it to classify the row a `create` instead of `update`.
  static const freshStampKey = '__qc_fresh_remote_stamp__';

  /// Fresh row of [table]/[pk]=[id] with `remote_id` guaranteed (stamped on
  /// disk when missing). Null when the row does not exist.
  Future<Map<String, dynamic>?> stampedRow(
    DatabaseExecutor txn,
    String table,
    String pk,
    Object? id,
  ) async {
    if (id == null) return null;
    final intId = id is num ? id.toInt() : int.tryParse('$id');
    if (intId == null || intId <= 0) return null;
    final rows = await txn.query(
      table,
      where: '$pk = ?',
      whereArgs: [intId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = Map<String, dynamic>.from(rows.first);
    if ('${row['remote_id'] ?? ''}'.isEmpty) {
      final intIdRow = (row[pk] as num?)?.toInt();
      row['remote_id'] = intIdRow == null
          ? sync_write.newRemoteId()
          : 'legacy_${table}_$intIdRow';
      row[freshStampKey] = true;
      try {
        await txn.update(
          table,
          {'remote_id': row['remote_id']},
          where: '$pk = ?',
          whereArgs: [intId],
        );
      } on Object {
        // Column added late: the open-time guarantee repairs on next open.
      }
    }
    return row;
  }

  /// The parent's cross-device identity for a child stamp column, ensuring
  /// the parent carries one first. Empty when the parent does not exist.
  Future<String> parentRemoteId(
    DatabaseExecutor txn,
    String parentTable,
    String parentPk,
    Object? parentLink,
  ) async {
    final parent = await stampedRow(txn, parentTable, parentPk, parentLink);
    return parent == null ? '' : '${parent['remote_id']}';
  }

  /// Stamps each parent-identity column of [child] from the link column of
  /// the same row, in place. The specs are static per child table:
  /// `ParentLinkRef(stampColumn, parentTable, parentPk, linkColumn)` — e.g.
  /// a section stamps `template_remote_id` from its `template_id`.
  ///
  /// The parent row gets its own identity stamped here first: a legacy
  /// parent that never pushed would leave the child permanently unpullable.
  /// A null/zero/absent link simply leaves the stamp unset (the pull side
  /// drops null-able pointers instead of linking the wrong device's row).
  Future<void> stampParents(
    DatabaseExecutor txn,
    Map<String, dynamic> child,
    List<ParentLinkRef> links,
  ) async {
    for (final link in links) {
      final ref = child[link.linkColumn];
      final linkId = ref is num ? ref.toInt() : int.tryParse('$ref');
      if (linkId == null || linkId <= 0) continue;
      final remote = await parentRemoteId(
        txn,
        link.parentTable,
        link.parentPk,
        linkId,
      );
      if (remote.isEmpty) continue;
      child[link.stampColumn] = remote;
    }
  }

  /// Syncs one root row (template, inspection, response, finding, CAPA):
  /// fresh row, parent stamps, enqueue. No-op without a wired writer.
  Future<void> queueRow(
    DatabaseExecutor txn, {
    required String entityType,
    required String table,
    required String pk,
    Object? id,
    String? operation,
  }) async {
    final row = await stampedRow(txn, table, pk, id);
    if (row == null) return;
    await stampParents(txn, row, _parentLinks[entityType] ?? const []);
    await enqueue(txn, entityType: entityType, row: row, operation: operation);
  }

  /// Syncs every row of [table] matching [where] — the children of a
  /// container (a template tree after `_writeTree`, or the seeded responses
  /// of a fresh sheet). Each row is stamped/queued individually with its
  /// own lifecycle-derived operation (`create`/`update`/`tombstone`/
  /// skip), so retired-but-never-pushed children stay skip.
  Future<void> queueChildRows(
    DatabaseExecutor txn, {
    required String table,
    required String pk,
    required String entityType,
    required String where,
    List<Object?> whereArgs = const [],
  }) async {
    final rows = await txn.query(
      table,
      columns: [pk],
      where: where,
      whereArgs: whereArgs,
      orderBy: '$pk ASC',
    );
    for (final r in rows) {
      await queueRow(
        txn,
        entityType: entityType,
        table: table,
        pk: pk,
        id: (r[pk] as num?)?.toInt(),
      );
    }
  }

  /// Decides the queue operation from the row's lifecycle state:
  /// tombstoned-and-active-remotely → `tombstone`, tombstoned-and-never-pushed
  /// → skipped (nothing remote to delete), never-pushed → `create`, else
  /// `update`. `freshStampKey` marks rows whose identity [stampedRow] minted
  /// in this very call — they never pushed, whatever their lifecycle branch.
  String? operationFor(Map<String, dynamic> row) {
    if (row[freshStampKey] != null) {
      return '${row['deleted_at'] ?? ''}'.isEmpty ? 'create' : null;
    }
    final deleted = '${row['deleted_at'] ?? ''}'.isNotEmpty;
    final hasRemote = '${row['remote_id'] ?? ''}'.isNotEmpty;
    if (deleted) return hasRemote ? 'tombstone' : null;
    return hasRemote ? 'update' : 'create';
  }

  /// Enqueues one row for the push; best-effort — a transient outbox failure
  /// leaves the row flagged `queued` for the backfill instead of failing the
  /// business write. `operationFor` filtered rows skip on a null purpose.
  Future<void> enqueue(
    DatabaseExecutor txn, {
    required String entityType,
    required Map<String, dynamic> row,
    String? operation,
    String? auditAction,
  }) async {
    if (!enabled) return;
    final entity = _entity(entityType);
    final op = operation ?? operationFor(row);
    if (op == null) return;
    await sync_write.enqueueLocalChange(
      executor: txn,
      entity: entity,
      row: row,
      operation: op,
      queue: queue,
      audit: syncAudit,
      auditAction: auditAction,
      organizationId: guard.organizationId,
      uid: guard.uid,
      deviceId: guard.deviceId,
    );
  }
}
