import 'dart:math';

import '../auth/app_session.dart';
import '../auth/session_source.dart';
import '../auth/permissions.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'audit_logger.dart';
import 'entity_registry.dart';
import 'remote/remote_data_source.dart';
import 'sync_codec.dart';
import 'sync_metadata.dart';
import 'sync_queue.dart';
import 'sync_run_scope.dart';

/// Outcome of one `push_worker` pass.
class PushReport {
  const PushReport({
    required this.pushed,
    required this.retried,
    required this.conflicts,
    required this.failed,
    this.lastError,
  });

  final int pushed;
  final int retried;
  final int conflicts;
  final int failed;
  final String? lastError;

  static const PushReport empty = PushReport(
    pushed: 0,
    retried: 0,
    conflicts: 0,
    failed: 0,
  );
}

/// Pushes `sync_queue` rows to the remote backend (plan §9.3).
///
/// Classification of failures is the whole point of this class:
/// * success            → delete row, bump `remote_version`
/// * permission-denied  → `sync_conflicts` (never retried automatically)
/// * payload too large  → `sync_conflicts` with `payload_too_large`
/// * anything transient  → exponential backoff
class PushWorker {
  PushWorker({
    required this.queue,
    required this.metadata,
    required this.remote,
    required this.audit,
    required this.source,
    this.batchSize = 400,
    this.maxConcurrency = 8,
  });

  final SyncQueue queue;
  final SyncMetadata metadata;
  SyncMetadata? _cycleMetadata;
  SyncMetadata get _runMetadata => _cycleMetadata ?? metadata;
  final RemoteDataSource remote;
  final AuditLogger audit;
  final SessionSource source;

  /// Read live: the session changes on sign-in, sign-out and org switch.
  AppSession get session => _scope?.session ?? source.session;

  SyncRunScope? _scope;
  Future<PushReport>? _running;

  bool Function()? cycleIsCurrent;
  void cancel() => _scope?.cancel();
  void _checkScope() {
    _scope?.check();
    if (cycleIsCurrent != null && !cycleIsCurrent!()) {
      throw const SyncRunCancelled();
    }
  }

  final int batchSize;

  /// Upper bound on simultaneous Firestore writes from one device.
  ///
  /// 8 keeps a burst of writes under the Firestore per-client limit while
  /// still overlapping the network latency, which is what the serial version
  /// was paying in full.
  final int maxConcurrency;

  int get effectiveConcurrency => min(maxConcurrency, batchSize);

  Future<PushReport> runOnce() => _running ??= _runScoped().whenComplete(() {
    _running = null;
    _scope = null;
    _cycleMetadata = null;
  });

  Future<PushReport> _runScoped() async {
    _scope = SyncRunScope(source, queue.dbHelper);
    try {
      final db = await queue.dbHelper.database;
      _checkScope();
      _cycleMetadata = metadata.bind(db);
      return await _runOnce();
    } on SyncRunCancelled {
      return PushReport.empty;
    }
  }

  Future<PushReport> _runOnce() async {
    _checkScope();
    if (!remote.isSignedIn) return PushReport.empty;
    final entries = await queue.claim(
      limit: batchSize,
      uid: session.uid,
      checkCurrent: _checkScope,
    );
    _checkScope();
    if (entries.isEmpty) return PushReport.empty;

    var pushed = 0;
    var retried = 0;
    var conflicts = 0;
    var failed = 0;
    String? lastError;
    String? lastEntity;

    // Phase 1: the purely local rejections. They cost no network round-trip, so
    // they are settled on their own instead of occupying a concurrency slot.
    final sendable = <QueueEntry>[];
    final settlements = <QueueSettlement>[];
    final audits = <Future<void> Function()>[];

    for (final entry in entries) {
      final entity = entry.entity;
      if (entity == null) {
        settlements.add(
          QueueSettlement.conflict(
            entry,
            direction: 'push_rejected',
            error: 'Unknown entity type ${entry.entityType}',
          ),
        );
        conflicts++;
        continue;
      }
      final actor = QueueEntry.payloadOwner(
        entry.entityType,
        entry.operation,
        entry.payload,
      );
      if (entry.ownerUid != session.uid || actor != session.uid) {
        settlements.add(
          QueueSettlement.conflict(
            entry,
            direction: 'owner_unknown',
            error:
                'Queued change has no verified matching owner; review required.',
          ),
        );
        conflicts++;
        continue;
      }
      if (!_allowedLocally(entity)) {
        settlements.add(
          QueueSettlement.conflict(
            entry,
            direction: 'push_rejected',
            error: 'Permission ${entity.permission} is not granted',
          ),
        );
        final target = entry;
        audits.add(() => _auditDenied(target));
        conflicts++;
        continue;
      }
      sendable.add(entry);
    }

    // Phase 2: the network round-trips, at most [maxConcurrency] in flight.
    // They were fully serial, so a 400-row batch paid 400 round-trip latencies
    // back to back. Entities are independent documents, so overlapping them is
    // safe; the cap keeps the socket pool and the Firestore rate limit in view.
    // Each push is individually guarded: a poisoned remote map or a throwing
    // data-source must degrade to retry/conflict for that entry, never abort
    // the whole 400-row batch (the old jsonEncode(Timestamp) crash did).
    final results = await _mapWithConcurrency(
      sendable,
      effectiveConcurrency,
      (entry) => _pushOneGuarded(entry),
    );

    _checkScope();
    for (var i = 0; i < results.length; i++) {
      _checkScope();
      final entry = sendable[i];
      final result = results[i];
      switch (result.kind) {
        case PushResultKind.success:
          settlements.add(
            QueueSettlement.done(entry, remoteVersion: result.version),
          );
          pushed++;
          lastEntity = entry.entityType;
          lastError = null;
        case PushResultKind.permissionDenied:
          // Version races resolve themselves (see _tryAutoRebase): only a
          // genuine denial becomes a manual conflict row.
          final auto = await _tryAutoRebase(entry, result);
          if (auto != null) {
            if (auto.settlement != null) {
              settlements.add(auto.settlement!);
              pushed++;
              lastEntity = entry.entityType;
              lastError = null;
            } else {
              settlements.add(
                QueueSettlement.retry(
                  entry,
                  auto.error ?? 'auto-rebase deferred',
                ),
              );
              retried++;
              lastError = auto.error;
            }
            continue;
          }
          settlements.add(
            QueueSettlement.conflict(
              entry,
              direction: 'push_rejected',
              // Never throws: sanitized + try/catch inside. Previously a raw
              // Firestore Timestamp here crashed the entire batch.
              remotePayload: SyncCodec.tryEncodeMap(result.remote),
              error: result.error,
            ),
          );
          final target = entry;
          audits.add(
            () => _logConflict(target, result.error ?? 'permission denied'),
          );
          conflicts++;
          lastError = result.error;
        case PushResultKind.payloadTooLarge:
          settlements.add(
            QueueSettlement.conflict(
              entry,
              direction: 'payload_too_large',
              error: result.error,
            ),
          );
          final target = entry;
          audits.add(
            () => _logConflict(target, result.error ?? 'payload too large'),
          );
          conflicts++;
          lastError = result.error;
        case PushResultKind.retryable:
          settlements.add(
            QueueSettlement.retry(entry, result.error ?? 'unknown error'),
          );
          retried++;
          lastError = result.error;
      }
    }

    // Phase 3: one commit for the whole batch. Writing each outcome as it
    // arrived meant an fsync per entry, and a crash midway left the queue
    // describing a push that had already happened.
    _checkScope();
    await queue.settleAll(settlements, checkCurrent: _checkScope);
    _checkScope();
    for (final audit in audits) {
      await audit();
    }

    _checkScope();
    if (pushed > 0) {
      await _runMetadata.markPush(DateTime.now());
      await _runMetadata.markError(null);
      // Wake the other devices: their 10 s heartbeat probes notice this bump
      // within seconds instead of on their 60 s timer. Best-effort — a failed
      // bump never fails the push that earned it.
      await _bumpHeartbeat(lastEntity);
    } else if (lastError != null) {
      await _runMetadata.markError(lastError);
    }
    if (failed > 0) {
      lastError = 'failed';
    }
    return PushReport(
      pushed: pushed,
      retried: retried,
      conflicts: conflicts,
      failed: failed,
      lastError: lastError,
    );
  }

  /// Bumps the shared heartbeat after a push batch and marks it seen, so our
  /// own 10 s probe does not pull on our own writes — only other devices'
  /// bumps trigger a pull. Best-effort: failures are swallowed, the 60 s
  /// timer stays the fallback.
  Future<void> _bumpHeartbeat(String? lastEntity) async {
    final organizationId = session.organizationId;
    if (organizationId.isEmpty) return;
    try {
      _checkScope();
      await remote.writeHeartbeat(
        organizationId: organizationId,
        data: {
          'lastWriteBy': session.uid,
          if (lastEntity case final entity) 'lastEntity': entity,
          'version': DateTime.now().millisecondsSinceEpoch,
        },
      );
    } on Object {
      // Heartbeat is a notification, not data: never fail the push over it.
    }
  }

  /// Per-entry guard: the data-source contract returns [PushResult], but a
  /// hostile map (raw Timestamp) or a throwing implementation must not escape
  /// as an unhandled exception and strand the batch in `in_flight`.
  Future<PushResult> _pushOneGuarded(QueueEntry entry) async {
    try {
      return await _pushOne(entry);
    } on Object catch (e) {
      return PushResult.retryable('$e');
    }
  }

  /// The remote call for one entry, tombstone or document.
  Future<PushResult> _pushOne(QueueEntry entry) {
    _checkScope();
    final entity = entry.entity;
    if (entity == null) {
      // Unreachable from [runOnce]: unresolvable entities are rejected locally
      // before they reach the send phase.
      return Future.value(
        PushResult.retryable('Unknown entity type ${entry.entityType}'),
      );
    }
    return entry.operation == 'tombstone'
        ? _pushTombstone(entity, entry)
        : _pushDocument(entity, entry);
  }

  /// Applies [action] over [items] with at most [limit] calls in flight,
  /// preserving input order in the result.
  static Future<List<R>> _mapWithConcurrency<T, R>(
    List<T> items,
    int limit,
    Future<R> Function(T item) action,
  ) async {
    if (items.isEmpty) return const [];
    final results = List<R?>.filled(items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= items.length) return;
        results[index] = await action(items[index]);
      }
    }

    final workers = min(limit, items.length);
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);
    return results.cast<R>();
  }

  Future<PushResult> _pushDocument(
    SyncEntity entity,
    QueueEntry entry, {
    int? baseVersion,
  }) async {
    final organizationId = session.organizationId;
    if (organizationId.isEmpty) {
      return PushResult.retryable('no organization bound');
    }
    final payload = Map<String, dynamic>.from(entry.payload);
    payload['deviceId'] = session.deviceId;
    if (entity.type != 'auditLog') payload['updatedBy'] = session.uid;
    // Repair pre-upgrade outbox snapshots as well as new writes. Updating
    // linkage only leaves the claimed business payload/revision untouched.
    if (entity.type == 'productBatchSample') {
      final db = await queue.dbHelper.database;
      final parents = await db.rawQuery(
        'SELECT i.id, i.entry_code, i.remote_id FROM product_batch_samples s '
        'JOIN inspections i ON i.id = s.batch_id '
        "JOIN sync_queue q ON q.id = ? AND q.revision = ? AND q.status = 'in_flight' "
        "WHERE s.remote_id = ? AND i.inspection_kind = 'product' LIMIT 1",
        [entry.id, entry.revision, entry.entityId],
      );
      if (parents.isEmpty) {
        return PushResult.retryable('product batch parent not available');
      }
      final parent = parents.single;
      final code = '${parent['entry_code'] ?? ''}';
      if (code.isEmpty) {
        return PushResult.retryable('product batch entry code missing');
      }
      final remoteId = '${parent['remote_id'] ?? ''}';
      payload['batchEntryCode'] = code;
      payload['batchRemoteId'] = remoteId.isNotEmpty ? remoteId : code;
      payload['batchId'] = parent['id'];
    }
    _checkScope();
    if (entity.appendOnly) {
      return remote.appendDocument(
        organizationId: organizationId,
        collection: entity.collection,
        documentId: entry.entityId,
        data: payload,
      );
    }
    return remote.setDocument(
      organizationId: organizationId,
      collection: entity.collection,
      documentId: entry.entityId,
      data: payload,
      baseVersion: baseVersion ?? entry.baseVersion,
    );
  }

  Future<PushResult> _pushTombstone(
    SyncEntity entity,
    QueueEntry entry, {
    int? baseVersion,
  }) async {
    final organizationId = session.organizationId;
    if (organizationId.isEmpty) {
      return PushResult.retryable('no organization bound');
    }
    var payload = Map<String, dynamic>.from(entry.payload);
    if (entry.localRef != null) {
      final db = await queue.dbHelper.database;
      _checkScope();
      final rows = await db.query(
        entity.localTable,
        where: '${entity.pkColumn} = ?',
        whereArgs: [entry.localRef],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        payload = {
          ...buildRemotePayload(
            entity,
            Map<String, dynamic>.from(rows.single),
            SyncPayloadContext(
              organizationId: organizationId,
              uid: session.uid,
              deviceId: session.deviceId,
              version: (baseVersion ?? entry.baseVersion) + 1,
              versionField: 'version',
            ),
            asCreate: true,
          ),
          ...payload,
        };
      }
    }
    _checkScope();
    payload['organizationId'] = organizationId;
    payload['deviceId'] = session.deviceId;
    payload['updatedBy'] = session.uid;
    payload['deletedAt'] ??= SyncCodec.serverTimestampPlaceholder;
    return remote.setDocument(
      organizationId: organizationId,
      collection: entity.collection,
      documentId: entry.entityId,
      data: payload,
      baseVersion: baseVersion ?? entry.baseVersion,
    );
  }

  /// Rebase only when the remote has not moved beyond an acknowledged base.
  /// A true concurrent business edit is retained as a conflict; device clocks
  /// never decide which data to discard. Server deletion remains terminal.
  Future<_AutoDecision?> _tryAutoRebase(
    QueueEntry entry,
    PushResult result,
  ) async {
    _checkScope();
    final entity = entry.entity;
    final remote = result.remote;
    if (entity == null || entity.appendOnly) return null;
    if (remote == null || remote.isEmpty) return null;
    if (entry.localRef == null) return null;
    final freshRemote = await _remoteForRace(entry, entity, result);
    if (freshRemote == null) return null;
    try {
      final db = await queue.dbHelper.database;
      _checkScope();
      final rows = await db.query(
        entity.localTable,
        where: '${entity.pkColumn} = ?',
        whereArgs: [entry.localRef],
        limit: 1,
      );
      _checkScope();
      if (!await queue.isCurrentClaim(db, entry)) {
        return _AutoDecision.retry('superseded local edit');
      }
      if (rows.isEmpty) return null;
      final local = rows.first;
      final remoteVersion = (freshRemote['version'] as num?)?.toInt() ?? 0;
      final syncedVersion = (local['remote_version'] as num?)?.toInt() ?? 0;
      final bool localWins;
      if (freshRemote['deletedAt'] != null && local['deleted_at'] == null) {
        localWins = false;
      } else if (remoteVersion <= syncedVersion) {
        // This is a stale transport base, not a competing business edit.
        localWins = true;
      } else {
        // Unsynchronised device clocks cannot prove which business edit was
        // intended to win. Preserve both payloads for explicit review instead
        // of deleting one because its wall-clock timestamp sorts earlier.
        return null;
      }
      if (localWins) {
        return await _rebaseLocalWins(entry, entity, local, remoteVersion);
      }
      return await _rebaseRemoteWins(
        entry,
        entity,
        local,
        freshRemote,
        remoteVersion,
      );
    } on Object {
      return null;
    }
  }

  /// The remote document to race against: the rejection's copy when it already
  /// proves a version race, else one fresh read (covers the narrow
  /// read-then-write race where the Rules deny after our check passed).
  /// Null ⇒ genuine denial or unreadable remote ⇒ manual path.
  Future<Map<String, dynamic>?> _remoteForRace(
    QueueEntry entry,
    SyncEntity entity,
    PushResult result,
  ) async {
    final remoteDoc = result.remote;
    if (remoteDoc == null || remoteDoc.isEmpty) return null;
    if (_looksLikeVersionRace(entry, remoteDoc, result.error)) return remoteDoc;
    // Equal versions but denied: either the race-after-read or a real auth
    // denial. One fresh read tells them apart; a failed read stays manual.
    try {
      final organizationId = session.organizationId;
      if (organizationId.isEmpty) return null;
      final fresh = await remote.getDocument(
        organizationId: organizationId,
        collection: entity.collection,
        documentId: entry.entityId,
      );
      if (!fresh.exists) return null;
      if (_looksLikeVersionRace(entry, fresh.data, result.error)) {
        return fresh.data;
      }
      return null;
    } on Object {
      return null;
    }
  }

  /// True when the denial is a version race rather than an auth problem: the
  /// rejection says so, or the remote version already differs from our base.
  bool _looksLikeVersionRace(
    QueueEntry entry,
    Map<String, dynamic> remote,
    String? error,
  ) {
    if ((error ?? '').toLowerCase().contains('version conflict')) return true;
    final remoteVersion = (remote['version'] as num?)?.toInt();
    return remoteVersion != null && remoteVersion != entry.baseVersion;
  }

  /// Re-push the current local row on top of [remoteVersion].
  Future<_AutoDecision> _rebaseLocalWins(
    QueueEntry entry,
    SyncEntity entity,
    Map<String, Object?> local,
    int remoteVersion,
  ) async {
    _checkScope();
    final db = await queue.dbHelper.database;
    _checkScope();
    if (!await queue.isCurrentClaim(db, entry)) {
      return _AutoDecision.retry('superseded local edit');
    }
    final organizationId = session.organizationId;
    if (organizationId.isEmpty) {
      return _AutoDecision.retry('no organization bound');
    }
    // Reuse exactly the first-send preparation, including stable parent
    // linkage repair and complete tombstone envelopes. Rebuilding from the
    // current business row here would mix a later edit into this old claim.
    final retry = entry.operation == 'tombstone'
        ? await _pushTombstone(entity, entry, baseVersion: remoteVersion)
        : await _pushDocument(entity, entry, baseVersion: remoteVersion);
    if (retry.isSuccess) {
      await _auditAuto(
        entry,
        'auto-rebase-local',
        'remote v$remoteVersion kept underneath, local edit re-pushed as v${retry.version}',
      );
      return _AutoDecision.settled(
        QueueSettlement.done(entry, remoteVersion: retry.version),
      );
    }
    // Denied again: still a race → backoff and rebase fresh next cycle;
    // anything else (auth, size) → manual path.
    if (retry.kind == PushResultKind.retryable) {
      return _AutoDecision.retry(retry.error ?? 'rebase push transient');
    }
    if (retry.kind == PushResultKind.payloadTooLarge) {
      return const _AutoDecision.manual();
    }
    if (_looksLikeVersionRace(entry, retry.remote ?? const {}, retry.error)) {
      return _AutoDecision.retry(retry.error ?? 'rebase race persists');
    }
    return const _AutoDecision.manual();
  }

  /// Apply the winning remote document over the local row and drain the queue.
  /// Mirrors the manual keep_remote path (same column filtering), plus stamps
  /// `updated_at` from the remote so future races compare on fresh clocks.
  Future<_AutoDecision> _rebaseRemoteWins(
    QueueEntry entry,
    SyncEntity entity,
    Map<String, Object?> local,
    Map<String, dynamic> remote,
    int remoteVersion,
  ) async {
    final db = await queue.dbHelper.database;
    _checkScope();
    final applied = await tracedTransaction(db, 'push.applyRemoteWinner', (
      txn,
    ) async {
      _checkScope();
      if (!await queue.isCurrentClaim(txn, entry)) return false;
      final columns = await availableColumns(txn, entity.localTable);
      final row = remoteToLocalRow(
        entity,
        Map<String, dynamic>.from(remote),
        organizationId: session.organizationId,
      )..['sync_state'] = 'synced';
      // Same FK-safe mapping as the pull path: origin-device ids must never be
      // written raw (they died on FK or linked the wrong row on keep-remote).
      await resolveRemoteRowRefs(
        txn,
        entity,
        row,
        Map<String, dynamic>.from(remote),
        ensureProductSentinel: (exec) =>
            queue.dbHelper.ensureProductSentinelMaterialId(exec),
      );
      if (columns.contains('updated_at') &&
          '${remote['updatedAt'] ?? ''}'.isNotEmpty) {
        row['updated_at'] = '${remote['updatedAt']}';
      }
      _checkScope();
      await txn.update(
        entity.localTable,
        {
          for (final e in row.entries)
            if (e.key != entity.pkColumn && columns.contains(e.key))
              e.key: e.value,
        },
        where: '${entity.pkColumn} = ?',
        whereArgs: [local[entity.pkColumn]],
      );
      await queue.markDone(entry, remoteVersion: remoteVersion, executor: txn);
      _checkScope();
      return true;
    });
    if (!applied) return _AutoDecision.retry('superseded local edit');
    await _auditAuto(
      entry,
      'auto-rebase-remote',
      'remote v$remoteVersion newer, applied locally',
    );
    return _AutoDecision.settled(
      QueueSettlement.done(entry, remoteVersion: remoteVersion),
    );
  }

  Future<void> _auditAuto(
    QueueEntry entry,
    String strategy,
    String detail,
  ) async {
    _checkScope();
    final db = await queue.dbHelper.database;
    await tracedTransaction(db, 'push.auditAuto', (txn) async {
      _checkScope();
      await audit.log(
        txn,
        action: AuditAction.syncConflict,
        entityType: entry.entityType,
        entityId: entry.entityId,
        details: {
          'strategy': strategy,
          'detail': detail,
          'operation': entry.operation,
          'automatic': true,
          'at': nowIso(),
        },
      );
    });
  }

  /// Local gate before spending a network round-trip (the Rules are the second
  /// layer, this is the first one).
  bool _allowedLocally(SyncEntity entity) {
    if (!session.isActiveMember || session.isOrgSuspended) return false;
    final permission = entity.permission;
    if (permission == null) return true;
    final parsed = Permission.byId(permission);
    if (parsed == null) return false;
    return !session.readOnlyDevice && session.can(parsed);
  }

  Future<void> _auditDenied(QueueEntry entry) async {
    final db = await queue.dbHelper.database;
    _checkScope();
    await tracedTransaction(db, 'push.auditDenied', (txn) async {
      _checkScope();
      await audit.log(
        txn,
        action: AuditAction.deniedEntry,
        entityType: entry.entityType,
        entityId: entry.entityId,
        details: {'reason': 'push blocked locally', 'at': nowIso()},
      );
    });
  }

  Future<void> _logConflict(QueueEntry entry, String error) async {
    final db = await queue.dbHelper.database;
    _checkScope();
    await tracedTransaction(db, 'push.auditConflict', (txn) async {
      _checkScope();
      await audit.log(
        txn,
        action: AuditAction.syncConflict,
        entityType: entry.entityType,
        entityId: entry.entityId,
        details: {'error': error, 'operation': entry.operation},
      );
    });
  }
}

/// Decision of one automatic rebase attempt (see `PushWorker._tryAutoRebase`).
///
/// A `settled` decision drains the queue entry (counts as pushed); a `retry`
/// decision sends it to backoff to converge on a later cycle; `manual` falls
/// through to the Sync-screen conflict path.
class _AutoDecision {
  const _AutoDecision.settled(this.settlement) : error = null;
  const _AutoDecision.retry(this.error) : settlement = null;
  const _AutoDecision.manual() : settlement = null, error = null;

  final QueueSettlement? settlement;
  final String? error;
}
