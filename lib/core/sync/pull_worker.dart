import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../auth/app_session.dart';
import '../auth/permissions.dart';
import '../auth/session_source.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'conflict_resolver.dart';
import 'entity_registry.dart';
import 'remote/remote_data_source.dart';
import 'sync_metadata.dart';
import 'sync_queue.dart';
import 'sync_run_scope.dart';
import 'sync_cursor_time.dart';

/// Outcome of one `pull_worker` pass.
class PullReport {
  const PullReport({
    required this.applied,
    required this.skipped,
    required this.pushedBack,
    required this.hasMore,
    this.failed = 0,
    this.error,
  });

  final int applied;
  final int skipped;
  final int pushedBack;
  final bool hasMore;

  /// Documents the local schema refused. They are counted and reported, never
  /// thrown: see [PullWorker._applyPage].
  final int failed;
  final String? error;

  static const PullReport empty = PullReport(
    applied: 0,
    skipped: 0,
    pushedBack: 0,
    hasMore: false,
  );
}

/// Downloads remote changes page by page and applies them locally
/// (plan §9.3). No Firestore-side filtering/search is ever used — this is a
/// pure `orderBy('updatedAt').orderBy(documentId)` cursor walk.
class PullWorker {
  PullWorker({
    required this.queue,
    required this.metadata,
    required this.remote,
    required this.conflicts,
    SessionSource? source,
    this.pageSize = 300,
    this.maxPagesPerCycle = 5,
    List<SyncEntity>? entities,
    this.quietPermissionErrors = false,
    this.marksPullTimestamp = true,
  }) : source = source ?? SessionSource.empty(),
       entities = _dependenciesFirst(entities ?? syncEntities);
  final SyncQueue queue;
  final SyncMetadata metadata;
  SyncMetadata? _cycleMetadata;
  SyncMetadata get _runMetadata => _cycleMetadata ?? metadata;
  final RemoteDataSource remote;
  final ConflictResolver conflicts;

  SessionSource source;

  /// The entities this pass walks. The normal cycle uses every entry of
  /// `syncEntities`; the audit trail is pulled by its own instance so that a
  /// member without `audit.read` cannot break the data cycle with a
  /// permission-denied on `auditLogs`.
  final List<SyncEntity> entities;

  /// A permission-denied is a *permission*, not a failure: the entry is skipped
  /// and no error is recorded (the badge must not turn red because a viewer is
  /// not allowed to read the audit trail).
  final bool quietPermissionErrors;

  /// Only the main data cycle owns `last_pull_at` (the badge shows it); the
  /// dedicated audit pass must not move the "last synced" marker.
  final bool marksPullTimestamp;

  /// Reference rows must land before the rows that point at them.
  ///
  /// `inspections.material_id` is a per-device autoincrement id resolved by
  /// code at apply time (see `_localRow`), but the referenced material still
  /// has to exist locally first — otherwise every sample of a fresh install
  /// fails its foreign key while the material sits later in the same cycle.
  /// Ranked explicitly (stable: original index breaks ties) so `sample` never
  /// walks before `users` / `referenceMaterials` / `labConfig`.
  static List<SyncEntity> _dependenciesFirst(List<SyncEntity> input) {
    int rank(SyncEntity e) {
      if (e.localTable == 'users') return 0;
      if (e.type == 'parameter' || e.type == 'organizationSetting') return 1;
      if (e.type == 'materialBound') return 3;
      if (e.type == 'qcSop') return 4;
      if (e.type == 'qcSopRevision' || e.type == 'qcSopRead') return 5;
      if (e.collection == SyncCollection.referenceMaterials) return 1;
      if (e.collection == SyncCollection.labConfig) return 2;
      if (e.type == 'sample') return 3;
      // QC custom tables: the definition must land before its typed
      // columns, which must land before the rows whose `values_json` keys
      // name those columns (rows would otherwise render against an empty
      // field list until the next cycle).
      if (e.localTable == 'qc_custom_tables') return 4;
      if (e.localTable == 'qc_custom_table_fields') return 5;
      if (e.localTable == 'qc_custom_table_rows') return 6;
      // QC checklists + execution + NCR/CAPA (plan P8): strict parent-first
      // order — templates → sections → items → inspections → responses →
      // task logs → findings → capa. A child without its parent throws a
      // transient `MissingParentException`, so explaining here saves whole
      // retry rounds.
      if (e.localTable == 'qc_templates') return 7;
      if (e.localTable == 'qc_sections') return 8;
      if (e.localTable == 'qc_items') return 9;
      if (e.localTable == 'qc_inspections') return 10;
      if (e.localTable == 'qc_task_log') return 11;
      if (e.localTable == 'qc_responses') return 12;
      if (e.localTable == 'qc_findings_nc') return 13;
      if (e.localTable == 'qc_capa') return 14;
      return 4;
    }

    final indexed = [for (var i = 0; i < input.length; i++) (i, input[i])];
    indexed.sort((a, b) {
      final byRank = rank(a.$2).compareTo(rank(b.$2));
      if (byRank != 0) return byRank;
      return a.$1.compareTo(b.$1);
    });
    return [for (final e in indexed) e.$2];
  }

  /// Read live: the session changes on sign-in, sign-out and org switch.
  AppSession get _session => _scope?.session ?? source.session;
  SyncRunScope? _scope;
  Future<PullReport>? _running;
  bool Function()? cycleIsCurrent;
  void cancel() => _scope?.cancel();
  void _checkScope() {
    _scope?.check();
    if (cycleIsCurrent != null && !cycleIsCurrent!()) {
      throw const SyncRunCancelled();
    }
  }

  final int pageSize;

  /// 5 × 300 = 1500 documents per cycle (plan §9.8).
  final int maxPagesPerCycle;

  Future<PullReport> runOnce() => _running ??= _runScoped().whenComplete(() {
    _running = null;
    _scope = null;
    _cycleMetadata = null;
    _columnCache.clear();
    _userIds.clear();
  });

  Future<PullReport> _runScoped() async {
    _columnCache.clear();
    _userIds.clear();
    _scope = SyncRunScope(source, queue.dbHelper);
    try {
      final db = await queue.dbHelper.database;
      _checkScope();
      _cycleMetadata = metadata.bind(db);
      return await _runOnce();
    } on SyncRunCancelled {
      return PullReport.empty;
    }
  }

  Future<PullReport> _runOnce() async {
    _checkScope();
    if (!remote.isSignedIn) return PullReport.empty;
    final organizationId = _session.organizationId;
    if (organizationId.isEmpty) return PullReport.empty;

    var applied = 0;
    var skipped = 0;
    var pushedBack = 0;
    var failed = 0;
    var hasMore = false;
    String? error;

    // Documents refused this pass (usually a foreign key to a reference row
    // that lands later in the same cycle). Retried verbatim at the end of
    // the cycle instead of being dropped by the advancing cursor.
    final failedDocs = <({SyncEntity entity, RemoteDocument doc})>[];

    // Several lab-settings entities share the remote `labConfig` collection.
    // Walking it once per *entity* used to download the whole collection nine
    // times per cycle, each walk discarding the documents belonging to the
    // other eight tables. Each collection is now walked once per cycle and the
    // same pages are fanned out to every entity positioned on it (plan §9.3);
    // per-entity dependency order is preserved by the groups' first-appearance
    // order (see `_dependenciesFirst`).
    final db = await queue.dbHelper.database;
    _checkScope();
    // One SQLite round trip for the whole cursor set. A root-handle read per
    // entity (41 entities) made a no-change heartbeat walk compete with the
    // foreground UI for dozens of separate FFI calls.
    final savedCursors = await _runMetadata.readAll([
      for (final entity in entities) SyncMetadata.cursorKey(entity.type),
    ]);
    _checkScope();
    PullCursor savedCursor(SyncEntity entity) {
      final raw = savedCursors[SyncMetadata.cursorKey(entity.type)];
      if (raw == null || raw.isEmpty) return const PullCursor('', '');
      try {
        return PullCursor.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } on Object {
        return const PullCursor('', '');
      }
    }

    final groups = <String, List<SyncEntity>>{};
    for (final entity in entities) {
      final permission = switch (entity.collection) {
        SyncCollection.members => Permission.usersRead,
        SyncCollection.samples ||
        SyncCollection.referenceMaterials ||
        SyncCollection.parameters ||
        SyncCollection.materialBounds => Permission.samplesRead,
        SyncCollection.labResults ||
        SyncCollection.labConfig ||
        SyncCollection.inventoryItems ||
        SyncCollection.inventoryTransactions ||
        SyncCollection.inventoryLots ||
        SyncCollection.equipment ||
        SyncCollection.equipmentEvents ||
        SyncCollection.worksheets ||
        SyncCollection.consumption ||
        SyncCollection.stockAdjustments ||
        SyncCollection.productBatchSamples => Permission.labResultsRead,
        SyncCollection.qualityChecks ||
        SyncCollection.qcCustomTables ||
        SyncCollection.qcCustomTableFields ||
        SyncCollection.qcCustomTableRows ||
        SyncCollection.qcTemplates ||
        SyncCollection.qcSections ||
        SyncCollection.qcItems ||
        SyncCollection.qcInspections ||
        SyncCollection.qcResponses ||
        SyncCollection.qcTaskLogs ||
        SyncCollection.qcFindingsNc ||
        SyncCollection.qcCapa ||
        SyncCollection.qcSops ||
        SyncCollection.qcSopRevisions ||
        SyncCollection.qcSopReads => Permission.qcRead,
        SyncCollection.organizationSettings => Permission.reportsRead,
        SyncCollection.auditLogs => Permission.auditRead,
        _ => null,
      };
      if (_session.isSignedIn &&
          permission != null &&
          !_session.can(permission)) {
        continue;
      }
      groups.putIfAbsent(entity.collection.name, () => []).add(entity);
    }

    for (final members in groups.values) {
      _checkScope();
      // The per-page fetch reads the *earliest* member cursor so a member that
      // lags behind cannot lose stream positions the others have advanced
      // past. Cursors are cached per cycle (not re-read per page) and
      // refreshed whenever an advance writes them.
      var groupHasMore = false;
      final cursors = {
        for (final member in members) member.type: savedCursor(member),
      };
      PullCursor cursorOf(SyncEntity entity) => cursors[entity.type]!;

      for (var page = 0; page < maxPagesPerCycle; page++) {
        _checkScope();
        // The fetch position is purely the earliest member cursor — never the
        // ('', '') seed, which would be "earlier than everything" and would
        // pin every page to the head of the stream.
        PullCursor? walk;
        for (final member in members) {
          final current = cursorOf(member);
          if (walk == null || _cursorEarlier(current, walk)) walk = current;
        }
        final walkCursor = walk ?? const PullCursor('', '');
        late RemotePage result;
        try {
          result = await remote.listSince(
            organizationId: organizationId,
            collection: members.first.collection,
            startAtTs: walkCursor.timestamp,
            startAtId: walkCursor.documentId,
            limit: pageSize,
          );
        } on Object catch (e) {
          if (quietPermissionErrors && _isPermissionDenied(e)) {
            // No permission for this collection on this device: stop walking
            // it and keep every cursor where it is.
            break;
          }
          error = '$e';
          break;
        }
        _checkScope();
        groupHasMore = result.hasMore;
        if (result.documents.isEmpty) {
          break;
        }

        for (final member in members) {
          final memberCursor = cursorOf(member);
          final accepts = member.accepts;
          final memberDocs = [
            for (final document in result.documents)
              if ((accepts == null || accepts(document)) &&
                  _cursorEarlier(memberCursor, _cursorOf(document)))
                document,
          ];
          // Documents another member owns are not re-downloaded here anymore;
          // they count as skipped exactly as the per-entity walk did.
          skipped += result.documents.length - memberDocs.length;
          if (memberDocs.isEmpty) {
            // Nothing of this page belongs to this member; the old walk
            // advanced its cursor across the whole page anyway.
            await _advanceCursor(
              cursors,
              member,
              _cursorOf(result.documents.last),
            );
            continue;
          }
          if (member.type == 'productBatchSample') {
            for (var i = 0; i < memberDocs.length; i++) {
              memberDocs[i] = await _prepareLegacyBatchLink(
                db,
                organizationId,
                memberDocs[i],
              );
            }
          }
          // One transaction for the whole page instead of one per document.
          // A page is at most `pageSize` (300) rows, so a single commit is
          // bounded work, and the page either lands completely or not at all --
          // which is what the cursor below assumes when it advances.
          final outcomes = await tracedTransaction(
            db,
            'pull.applyPage(${member.type})',
            (txn) async {
              _checkScope();
              final outcomes = await _applyPage(
                txn,
                member,
                memberDocs,
                organizationId,
              );
              _checkScope();
              return outcomes;
            },
          );
          for (var i = 0; i < outcomes.length; i++) {
            switch (outcomes[i]) {
              case _ApplyOutcome.applied:
                applied++;
              case _ApplyOutcome.skipped:
                skipped++;
              case _ApplyOutcome.pushedBack:
                pushedBack++;
              case _ApplyOutcome.failed:
                failed++;
                failedDocs.add((entity: member, doc: memberDocs[i]));
            }
          }
          // Advance the cursor only past the contiguous successful prefix.
          // Advancing past a failed document would skip it forever (until its
          // version bumps): the retry below re-fetches verbatim, but if the
          // retry also fails the cursor must still point before it so the next
          // cycle re-attempts it. Cursors never move backwards: a member whose
          // own walk had already advanced past this page simply keeps its
          // position.
          final firstFailed = outcomes.indexWhere(
            (o) => o == _ApplyOutcome.failed,
          );
          if (firstFailed == -1) {
            await _advanceCursor(cursors, member, _cursorOf(memberDocs.last));
          } else if (firstFailed > 0) {
            await _advanceCursor(
              cursors,
              member,
              _cursorOf(memberDocs[firstFailed - 1]),
            );
          }
        }
        if (!result.hasMore) break;
      }
      hasMore = hasMore || groupHasMore;
    }

    if (failedDocs.isNotEmpty) {
      // Dependencies pulled later in this same cycle (materials, products,
      // members) unblock the failures above: the documents are already in
      // hand, so they are re-applied verbatim before any network round trip
      // is spent on them. Anything still failing is re-fetched live (bounded,
      // 200) in case the remote copy moved on during the cycle.
      final retried = await _retryFailedDocs(organizationId, failedDocs);
      applied += retried.applied;
      failed -= retried.resolved;
    }

    _checkScope();
    if (marksPullTimestamp) {
      await _runMetadata.set(
        SyncMetadata.pullIncompleteKey,
        hasMore || error != null || failed > 0 ? '1' : '0',
      );
      if (!hasMore && error == null && failed == 0) {
        await _runMetadata.markPull(DateTime.now());
      }
    }
    if (error != null) {
      await _runMetadata.markError(error);
    } else if (failed > 0) {
      // Per-document schema failures used to stay inside PullReport only: the
      // badge kept saying "Synced" while remote rows were skipped every cycle.
      await _runMetadata.markError(
        'Pull skipped $failed document(s): local schema refused them. '
        'See "[sync] pull skipped" logs.',
      );
    }
    return PullReport(
      applied: applied,
      skipped: skipped,
      pushedBack: pushedBack,
      hasMore: hasMore,
      failed: failed,
      error: error,
    );
  }

  PullCursor _cursorOf(RemoteDocument document) => PullCursor(
    document.cursorTimestamp ?? document.updatedAt ?? '',
    document.id,
  );

  /// Writes [target] into the per-cycle cache and the persistent store, never
  /// moving a member cursor backwards over its own history.
  Future<void> _advanceCursor(
    Map<String, PullCursor> cursors,
    SyncEntity member,
    PullCursor target,
  ) async {
    _checkScope();
    final current = cursors[member.type];
    if (current != null && !_cursorEarlier(current, target)) return;
    cursors[member.type] = target;
    await _runMetadata.setCursor(member.type, target);
  }

  /// Cursor-stream order: `(updatedAt, documentId)`, the same (ts, id) key
  /// `listSince` walks by; ISO timestamps compare lexicographically.
  bool _cursorEarlier(PullCursor a, PullCursor b) {
    final byTime = SyncCursorTime.compare(a.timestamp, b.timestamp);
    if (byTime != 0) return byTime < 0;
    return a.documentId.compareTo(b.documentId) < 0;
  }

  /// Re-applies documents that failed mid-cycle.
  ///
  /// Runs after every collection was walked, so a sample that failed on a
  /// missing material succeeds once the material entity landed. The verbatim
  /// in-hand copy is reused first: this same cycle just downloaded it, so a
  /// network round trip per document buys nothing when the failure was a
  /// local dependency order problem (the usual case). Only documents still
  /// failing after the in-hand pass are re-fetched live (so a remote copy
  /// that moved on during the cycle is honoured).
  ///
  /// Returns how many were applied vs stopped failing (skipped/pushed-back
  /// also count as resolved: the row is now coherent with the server).
  Future<({int applied, int resolved})> _retryFailedDocs(
    String organizationId,
    List<({SyncEntity entity, RemoteDocument doc})> docs,
  ) async {
    var applied = 0;
    var resolved = 0;
    final db = await queue.dbHelper.database;
    final stillFailing = <({SyncEntity entity, RemoteDocument doc})>[];

    // Pass 1 — in-hand reruns, one transaction for the whole batch.
    if (docs.isNotEmpty) {
      try {
        final outcomes = await tracedTransaction(
          db,
          'pull.retryInHand(${docs.length})',
          (txn) async => [
            for (final entry in docs.take(200))
              await _applyDocument(
                txn,
                entry.entity,
                entry.doc,
                organizationId,
              ),
          ],
        );
        for (var i = 0; i < outcomes.length; i++) {
          switch (outcomes[i]) {
            case _ApplyOutcome.applied:
              applied++;
              resolved++;
            case _ApplyOutcome.skipped:
            case _ApplyOutcome.pushedBack:
              resolved++;
            case _ApplyOutcome.failed:
              stillFailing.add(docs[i]);
          }
        }
      } on Object catch (_) {
        // The batch transaction failed wholesale (schema/lock edge): every
        // in-hand entry goes through the live pass below, which contains
        // per-document failures one row at a time.
        for (var i = 0; i < docs.length; i++) {
          stillFailing.add(docs[i]);
        }
      }
    }

    // Pass 2 — verbatim live re-fetch for whatever still fails.
    for (final entry in stillFailing.take(200)) {
      RemoteDocument current;
      try {
        current = await remote.getDocument(
          organizationId: organizationId,
          collection: entry.entity.collection,
          documentId: entry.doc.id,
        );
      } on Object {
        continue;
      }
      _checkScope();
      if (!current.exists) continue;
      final outcome = await _applyRetryDoc(
        db,
        organizationId,
        entry.entity,
        entry.doc.id,
        current,
      );
      if (outcome == null) continue;
      switch (outcome) {
        case _ApplyOutcome.applied:
          applied++;
          resolved++;
        case _ApplyOutcome.skipped:
        case _ApplyOutcome.pushedBack:
          resolved++;
        case _ApplyOutcome.failed:
          break; // unreachable: _applyDocument reports failures by throwing
      }
    }
    return (applied: applied, resolved: resolved);
  }

  /// Applies a whole page inside [txn], returning the outcome per document in
  /// the same order. Runs sequentially because sqflite serialises statements on
  /// a single connection anyway, and the per-document `Future` bookkeeping in
  /// [_userIds]/[_columnCache] is keyed on the transaction.
  Future<List<_ApplyOutcome>> _applyPage(
    DatabaseExecutor txn,
    SyncEntity entity,
    List<RemoteDocument> documents,
    String organizationId,
  ) async {
    // A document the local schema cannot hold is contained to itself.
    //
    // `txn` is one transaction for the whole page, so a `NOT NULL` / `CHECK` /
    // `UNIQUE` violation used to roll back every document in the page and
    // surface as a thrown exception from `runOnce` - the sync engine reported
    // a hard error, the cursor never advanced, and the same bad document
    // blocked the cycle forever, silently withholding every healthy change
    // behind it. The page still commits; the offending row is counted as
    // [PullReport.failed] and left for a later version of itself to fix.
    final outcomes = <_ApplyOutcome>[];
    for (final document in documents) {
      try {
        outcomes.add(
          await _applyDocument(txn, entity, document, organizationId),
        );
      } on Object catch (e) {
        // ignore: avoid_print
        print('[sync] pull skipped ${entity.type}/${document.id}: $e');
        outcomes.add(_ApplyOutcome.failed);
      }
    }
    _checkScope();
    return outcomes;
  }

  Future<_ApplyOutcome> _applyDocument(
    DatabaseExecutor txn,
    SyncEntity entity,
    RemoteDocument document,
    String organizationId,
  ) async {
    _checkScope();
    {
      // Several entities may share one remote collection (every lab-settings
      // table lives in `labConfig`), so the first question is whether this
      // document is ours at all. Applying another table's document would
      // overwrite an unrelated local row that happens to share the id.
      final accepts = entity.accepts;
      if (accepts != null && !accepts(document)) return _ApplyOutcome.skipped;
      // `localId` first, then the natural key: a document written on another
      // device carries an id that means nothing in this database. Our own
      // device id lets the lookup tell the two cases apart (see findLocalRef).
      final available = await _availableColumns(txn, entity);
      final localRef = await findLocalRef(
        txn,
        entity,
        document.id,
        document.data,
        localDeviceId: _session.deviceId,
        columns: available,
      );
      final existing = localRef == null
          ? const <Map<String, Object?>>[]
          : await txn.query(
              entity.localTable,
              where: '${entity.pkColumn} = ?',
              whereArgs: [localRef],
              limit: 1,
            );
      _checkScope();
      final remoteVersion = document.version;
      if (existing.isNotEmpty &&
          remoteVersion <
              ((existing.first['remote_version'] as num?)?.toInt() ?? 0)) {
        return _ApplyOutcome.skipped;
      }

      // A tombstone is intentionally a partial remote document. It must not
      // go through the normal INSERT/UPDATE mapper: tables have required
      // business columns while a tombstone carries only deletion and sync
      // metadata. All tables soft-delete via `deleted_at` so a later update
      // can never resurrect a hard-deleted row (lab_sample_tests used to
      // hard-DELETE here, which re-push resurrection exploited).
      final deletedAt =
          document.data['deletedAt'] ?? document.data['deleted_at'];
      if (deletedAt != null) {
        if (existing.isNotEmpty) {
          final localId = existing.first[entity.pkColumn];
          final patch = <String, Object?>{
            'deleted_at': '$deletedAt',
            'sync_state': 'synced',
            'remote_synced_at': nowIso(),
          };
          final cols = await _availableColumns(txn, entity);
          if (cols.contains('active')) patch['active'] = 0;
          if (cols.contains('is_active')) patch['is_active'] = 0;
          patch.removeWhere((k, _) => !cols.contains(k));
          final remoteVersion = document.version;
          if (cols.contains('version')) {
            patch['version'] = remoteVersion;
          }
          if (cols.contains('remote_version')) {
            patch['remote_version'] = remoteVersion;
          }
          await txn.update(
            entity.localTable,
            patch,
            where: '${entity.pkColumn} = ?',
            whereArgs: [localId],
          );
        }
        // A server deletion is terminal. Keep no stale edit that could try
        // to restore this record after the tombstone was applied.
        await txn.delete(
          'sync_queue',
          where: 'entity_type = ? AND entity_id = ?',
          whereArgs: [entity.type, document.id],
        );
        await txn.update(
          'sync_conflicts',
          {'resolution': 'remote_deleted', 'resolved_at': nowIso()},
          where: 'entity_type = ? AND entity_id = ? AND resolution IS NULL',
          whereArgs: [entity.type, document.id],
        );
        return _ApplyOutcome.applied;
      }

      if (existing.isEmpty) {
        final row = await _localRow(
          txn,
          entity,
          remoteToLocalRow(
            entity,
            document.data,
            organizationId: organizationId,
          ),
        );
        // A foreign document's `localId` is the origin device's row id and
        // must never become our primary key (see `naturalKeyIdentity`):
        // inserting with it would REPLACE our unrelated row of that id.
        if (entity.naturalKeyIdentity) row.remove(entity.pkColumn);
        row['remote_synced_at'] = nowIso();
        row['sync_state'] = 'synced';
        row.removeWhere(
          (key, value) => value == null && _nullableColumns.contains(key),
        );
        await txn.insert(
          entity.localTable,
          _withDefaults(entity, row, await _availableColumns(txn, entity)),
          conflictAlgorithm: entity.type == 'productBatchSample'
              ? ConflictAlgorithm.abort
              : ConflictAlgorithm.replace,
        );
        await _repointAfterMaterialApply(txn, entity, document);
        return _ApplyOutcome.applied;
      }

      final local = existing.first;
      final localVersion = (local['version'] as num?)?.toInt() ?? 0;
      final syncedVersion = (local['remote_version'] as num?)?.toInt() ?? 0;
      final queued = await txn.query(
        'sync_queue',
        columns: ['id'],
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [entity.type, entity.docId(local)],
        limit: 1,
      );
      final hasLocalEdits =
          queued.isNotEmpty ||
          (local['sync_state'] == 'queued') ||
          (local['sync_state'] != 'conflict' &&
              localVersion > syncedVersion &&
              syncedVersion > 0);

      if (remoteVersion == syncedVersion &&
          (!hasLocalEdits || queued.isNotEmpty)) {
        if (entity.type == 'productBatchSample') {
          final link = <String, dynamic>{
            'batch_id': local['batch_id'],
            'remote_id': local['remote_id'],
          };
          await resolveRemoteRowRefs(
            txn,
            entity,
            link,
            document.data,
            ensureProductSentinel: (exec) =>
                queue.dbHelper.ensureProductSentinelMaterialId(exec),
          );
          if (link.entries.any((entry) => local[entry.key] != entry.value)) {
            await txn.update(
              entity.localTable,
              link,
              where: '${entity.pkColumn} = ?',
              whereArgs: [local[entity.pkColumn]],
            );
            return _ApplyOutcome.applied;
          }
        }
        await _healDivergentIdentity(txn, entity, document, local);
        return _ApplyOutcome.skipped;
      }
      if (hasLocalEdits) {
        // Device-local version counters do not order concurrent edits from
        // different devices. A pull must never overwrite an unacknowledged
        // queued payload, including a first create still at local version 1.
        if (queued.isNotEmpty) return _ApplyOutcome.skipped;
        // Preserve untracked legacy values for inspection, but never invent
        // an outbound operation under the account that happens to be signed in.
        await txn.insert('sync_conflicts', {
          'entity_type': entity.type,
          'entity_id': document.id,
          'direction': 'legacy_local_archive',
          'local_payload': jsonEncode(local),
          'remote_payload': jsonEncode(document.data),
          'detected_at': nowIso(),
          'resolution': 'archived_unqueued',
          'resolved_at': nowIso(),
        });
      }

      final row = await _localRow(
        txn,
        entity,
        remoteToLocalRow(entity, document.data, organizationId: organizationId),
      );
      row['remote_synced_at'] = nowIso();
      row['sync_state'] = 'synced';
      // `organization_settings.key` is UNIQUE across the whole table; a stale
      // same-key sibling would abort the UPDATE with code 2067 every cycle
      // and the document would never apply. See
      // `dropStaleOrgSettingSiblings` for the full rationale.
      if (entity.localTable == 'organization_settings') {
        await dropStaleOrgSettingSiblings(
          txn,
          key: row['key'],
          keepLocalId: local[entity.pkColumn],
        );
      }
      await txn.update(
        entity.localTable,
        _withDefaults(entity, row, await _availableColumns(txn, entity))
          ..remove(entity.pkColumn),
        where: '${entity.pkColumn} = ?',
        whereArgs: [local[entity.pkColumn]],
      );
      await _repointAfterMaterialApply(txn, entity, document);
      return _ApplyOutcome.applied;
    }
  }

  Future<RemoteDocument> _prepareLegacyBatchLink(
    Database db,
    String organizationId,
    RemoteDocument document,
  ) async {
    if ('${document.data['batchEntryCode'] ?? document.data['batch_entry_code'] ?? ''}'
            .isNotEmpty ||
        document.data['deletedAt'] != null) {
      return document;
    }
    try {
      final saved = await db.rawQuery(
        'SELECT i.entry_code FROM product_batch_samples s '
        'JOIN inspections i ON s.batch_id=i.id '
        "WHERE s.remote_id=? AND i.inspection_kind='product' AND s.batch_entry_code=i.entry_code LIMIT 1",
        [document.id],
      );
      String code = saved.isNotEmpty ? '${saved.single['entry_code']}' : '';
      if (code.isEmpty) {
        final localId = (document.data['batchId'] as num?)?.toInt() ?? 0;
        final deviceId = '${document.data['deviceId'] ?? ''}';
        if (localId <= 0 || deviceId.isEmpty) return document;
        final parent = await remote.findProductBatchHeader(
          organizationId: organizationId,
          deviceId: deviceId,
          localId: localId,
        );
        if (!parent.exists) return document;
        code = parent.id;
      }
      return RemoteDocument(
        id: document.id,
        data: {...document.data, 'batchEntryCode': code},
        version: document.version,
        updatedAt: document.updatedAt,
        cursorTimestamp: document.cursorTimestamp,
      );
    } on Object catch (error) {
      debugPrint('[sync] legacy batch parent lookup unavailable: $error');
      return document;
    }
  }

  /// Adopts the document's cross-device identity on a natural-key match.
  ///
  /// A document and a local row can describe the same business row while
  /// carrying different `remote_id`s (two devices that both created "the same"
  /// item before the organization was bound; the natural key names both). The
  /// version rule above then skips the update — and the local row keeps an
  /// identity no other device knows, so every child pointing at the
  /// document's identity (inventory lots of that item, equipment events)
  /// fails its parent remap in `entity_registry` on every cycle, forever.
  ///
  /// When the document's own payload proves the identity is the doc id
  /// (`remoteId == document.id`, what the `remoteIdDocId` writers stamp), the
  /// skipped row adopts it: one column, no version bump, idempotent.
  Future<void> _healDivergentIdentity(
    DatabaseExecutor txn,
    SyncEntity entity,
    RemoteDocument document,
    Map<String, Object?> local,
  ) async {
    if (!entity.naturalKeyIdentity) return;
    final docRemoteId = '${document.data['remoteId'] ?? ''}';
    if (docRemoteId.isEmpty || docRemoteId != document.id) return;
    final current = '${local['remote_id'] ?? ''}';
    if (current == document.id) return;
    final cols = await _availableColumns(txn, entity);
    if (!cols.contains('remote_id')) return;
    await txn.update(
      entity.localTable,
      {'remote_id': document.id},
      where: '${entity.pkColumn} = ?',
      whereArgs: [local[entity.pkColumn]],
    );
  }

  /// One live retry application of [document], with the missing-parent heal.
  ///
  /// Returns the outcome, or null when the document must stay failed (its
  /// local schema refused it, or the named parent has no remote copy either).
  Future<_ApplyOutcome?> _applyRetryDoc(
    Database db,
    String organizationId,
    SyncEntity entity,
    String docId,
    RemoteDocument document,
  ) async {
    try {
      return await tracedTransaction(
        db,
        'pull.retry(${entity.type})',
        (txn) => _applyDocument(txn, entity, document, organizationId),
      );
    } on MissingParentException catch (e) {
      // "Transient" only holds while the parent can still arrive on its own.
      // When it never landed, fetch it by its remote id (its document id for
      // the remoteIdDocId parents), apply it, and re-apply the child on top.
      if (!await _applyMissingParent(organizationId, e)) {
        // ignore: avoid_print
        print('[sync] pull retry skipped ${entity.type}/$docId: $e');
        return null;
      }
      try {
        return await tracedTransaction(
          db,
          'pull.retryAfterParent(${entity.type})',
          (txn) => _applyDocument(txn, entity, document, organizationId),
        );
      } on Object catch (e2) {
        // ignore: avoid_print
        print('[sync] pull retry skipped ${entity.type}/$docId: $e2');
        return null;
      }
    } on Object catch (e) {
      // ignore: avoid_print
      print('[sync] pull retry skipped ${entity.type}/$docId: $e');
      return null;
    }
  }

  /// Fetches the parent document named by [error] and applies it locally.
  ///
  /// One level deep: the parents handled here (inventory items, equipment,
  /// QC custom tables) have no parent rule of their own, so their apply
  /// cannot recurse. "Skipped" still counts as success — the
  /// [_healDivergentIdentity] above runs on that path, aligning the row's
  /// identity so the child's remap finds it.
  Future<bool> _applyMissingParent(
    String organizationId,
    MissingParentException error,
  ) async {
    final parent = SyncEntity.byType(error.parentEntity);
    if (parent == null) return false;
    try {
      _checkScope();
      final doc = await remote.getDocument(
        organizationId: organizationId,
        collection: parent.collection,
        documentId: error.parentRemoteId,
      );
      _checkScope();
      if (!doc.exists) return false;
      final outcome = await tracedTransaction(
        await queue.dbHelper.database,
        'pull.parent(${parent.type})',
        (txn) => _applyDocument(txn, parent, doc, organizationId),
      );
      return outcome != _ApplyOutcome.failed;
    } on Object {
      return false;
    }
  }

  /// Keeps only the keys that are real columns of [entity].localTable.
  ///
  /// The Firestore envelope is richer than any single local table (it always
  /// carries `organizationId`, `updatedBy`, `deviceId`, `payloadBytes`), and
  /// writing an unknown column would abort the whole transaction. Cached per
  /// table: one `PRAGMA table_info` per table per process.
  ///
  /// The two user-reference columns arrive as Firebase uids and are translated
  /// back to local `users.id` (plan §6.6): an author this device has not
  /// mirrored yet maps to the reserved row `id = 0`.
  Future<Map<String, dynamic>> _localRow(
    DatabaseExecutor txn,
    SyncEntity entity,
    Map<String, dynamic> row,
  ) async {
    final columns = _columnCache.putIfAbsent(
      entity.localTable,
      () => availableColumns(txn, entity.localTable),
    );
    final available = await columns;
    final resolved = <String, dynamic>{
      for (final entry in row.entries)
        if (available.contains(entry.key)) entry.key: entry.value,
    };
    // One shared mapper for every remote-apply path (pull, keep-remote,
    // auto-rebase): origin-device ids are remapped here, never written raw.
    // The per-cycle user cache is passed in so hundreds of docs do not pay
    // one `users` lookup each.
    await resolveRemoteRowRefs(
      txn,
      entity,
      resolved,
      row,
      ensureProductSentinel: (exec) =>
          queue.dbHelper.ensureProductSentinelMaterialId(exec),
      userIdFor: (uid) => _localUserId(txn, uid),
    );
    return resolved;
  }

  /// Re-link inspections after a catalog row lands (no-op for other tables).
  Future<void> _repointAfterMaterialApply(
    DatabaseExecutor txn,
    SyncEntity entity,
    RemoteDocument document,
  ) async {
    if (entity.localTable != 'reference_materials') return;
    final code =
        '${document.data['materialCode'] ?? document.data['material_code'] ?? ''}';
    await _repointInspectionsToMaterial(txn, code);
  }

  /// Point inspections at a freshly arrived catalog row and drop placeholders
  /// left behind by reference resolution (see `resolveMaterialIdByCodeOrName`).
  ///
  /// Runs after every successful `reference_materials` apply: rows whose code
  /// matches but whose `material_id` points nowhere (or at a placeholder) are
  /// re-linked, then placeholder rows no inspection references are removed.
  Future<void> _repointInspectionsToMaterial(
    DatabaseExecutor txn,
    String code,
  ) async {
    if (code.isEmpty) return;
    final target = await txn.query(
      'reference_materials',
      columns: ['id'],
      where: 'material_code = ?',
      whereArgs: [code],
      limit: 1,
    );
    if (target.isEmpty) return;
    final targetId = (target.first['id'] as num).toInt();
    await txn.rawUpdate(
      'UPDATE inspections SET material_id = ? '
      'WHERE material_code = ? AND material_id <> ? '
      'AND material_id NOT IN (SELECT id FROM reference_materials)',
      [targetId, code, targetId],
    );
    await txn.rawDelete(
      'DELETE FROM reference_materials WHERE material_code = ? AND id <> ? '
      'AND id NOT IN (SELECT material_id FROM inspections)',
      [code, targetId],
    );
  }

  /// Real columns of [entity].localTable, cached for the length of the cycle.
  Future<Set<String>> _availableColumns(
    DatabaseExecutor txn,
    SyncEntity entity,
  ) => _columnCache.putIfAbsent(
    entity.localTable,
    () => availableColumns(txn, entity.localTable),
  );

  /// Firebase uid → local `users.id`, cached for the length of the cycle.
  Future<int> _localUserId(DatabaseExecutor txn, String uid) async {
    if (uid.isEmpty) return 0;
    final byUid = _userIds.putIfAbsent(uid, () async {
      final rows = await txn.query(
        'users',
        where: 'uid = ?',
        whereArgs: [uid],
        limit: 1,
      );
      return rows.isEmpty ? 0 : (rows.first['id'] as num).toInt();
    });
    return byUid;
  }

  final Map<String, Future<Set<String>>> _columnCache = {};
  final Map<String, Future<int>> _userIds = {};

  static const Set<String> _nullableColumns = {
    'photo_url',
    'member_id',
    'uid',
    'display_name',
    'updated_by',
    'deleted_at',
  };

  /// Local defaults for columns the remote document does not carry.
  ///
  /// Only the tables that really have the column get it: `qualityCheck` maps
  /// onto `inspection_status_history`, which is a history log with its own
  /// `changed_at` and no `created_at`/`updated_at` at all. Writing a column
  /// that does not exist aborts the whole pull transaction, so the extra
  /// timestamps are filtered against the real schema.
  static Map<String, dynamic> _withDefaults(
    SyncEntity entity,
    Map<String, dynamic> row,
    Set<String> available,
  ) {
    Map<String, dynamic> withTimestamps() => {
      ...row,
      if (available.contains('created_at'))
        'created_at': row['created_at'] ?? nowIso(),
      if (available.contains('updated_at'))
        'updated_at': row['updated_at'] ?? nowIso(),
    };

    switch (entity.localTable) {
      case 'inspections':
        return {
          ...withTimestamps(),
          'decision_status': row['decision_status'] ?? 'PENDING',
          'created_by': row['created_by'] ?? 0,
          'created_by_name': row['created_by_name'] ?? '',
        };
      case 'users':
        return {
          ...row,
          'full_name': row['full_name'] ?? '',
          'status': row['status'] ?? 'invited',
          'permissions_json': row['permissions_json'] ?? '[]',
          'version': row['version'] ?? 1,
          'created_at': row['created_at'] ?? nowIso(),
        };
      default:
        return withTimestamps();
    }
  }
}

enum _ApplyOutcome { applied, skipped, pushedBack, failed }

bool _isPermissionDenied(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('permission-denied') ||
      text.contains('permission_denied') ||
      text.contains('permission denied') ||
      text.contains('unauthenticated');
}
