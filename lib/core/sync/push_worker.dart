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

  static const PushReport empty = PushReport(pushed: 0, retried: 0, conflicts: 0, failed: 0);
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
  final RemoteDataSource remote;
  final AuditLogger audit;
  final SessionSource source;

  /// Read live: the session changes on sign-in, sign-out and org switch.
  AppSession get session => source.session;
  final int batchSize;

  /// Upper bound on simultaneous Firestore writes from one device.
  ///
  /// 8 keeps a burst of writes under the Firestore per-client limit while
  /// still overlapping the network latency, which is what the serial version
  /// was paying in full.
  final int maxConcurrency;

  int get effectiveConcurrency => min(maxConcurrency, batchSize);

  Future<PushReport> runOnce() async {
    if (!remote.isSignedIn) return PushReport.empty;
    final entries = await queue.claim(limit: batchSize);
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
        settlements.add(QueueSettlement.conflict(
          entry,
          direction: 'push_rejected',
          error: 'Unknown entity type ${entry.entityType}',
        ));
        conflicts++;
        continue;
      }
      if (!_allowedLocally(entity)) {
        settlements.add(QueueSettlement.conflict(
          entry,
          direction: 'push_rejected',
          error: 'Permission ${entity.permission} is not granted',
        ));
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

    for (var i = 0; i < results.length; i++) {
      final entry = sendable[i];
      final result = results[i];
      switch (result.kind) {
        case PushResultKind.success:
          settlements.add(QueueSettlement.done(entry, remoteVersion: result.version));
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
              settlements.add(QueueSettlement.retry(entry, auto.error ?? 'auto-rebase deferred'));
              retried++;
              lastError = auto.error;
            }
            continue;
          }
          settlements.add(QueueSettlement.conflict(
            entry,
            direction: 'push_rejected',
            // Never throws: sanitized + try/catch inside. Previously a raw
            // Firestore Timestamp here crashed the entire batch.
            remotePayload: SyncCodec.tryEncodeMap(result.remote),
            error: result.error,
          ));
          final target = entry;
          audits.add(() => _logConflict(target, result.error ?? 'permission denied'));
          conflicts++;
          lastError = result.error;
        case PushResultKind.payloadTooLarge:
          settlements.add(QueueSettlement.conflict(
            entry,
            direction: 'payload_too_large',
            error: result.error,
          ));
          final target = entry;
          audits.add(() => _logConflict(target, result.error ?? 'payload too large'));
          conflicts++;
          lastError = result.error;
        case PushResultKind.retryable:
          settlements.add(QueueSettlement.retry(entry, result.error ?? 'unknown error'));
          retried++;
          lastError = result.error;
      }
    }

    // Phase 3: one commit for the whole batch. Writing each outcome as it
    // arrived meant an fsync per entry, and a crash midway left the queue
    // describing a push that had already happened.
    await queue.settleAll(settlements);
    for (final audit in audits) {
      await audit();
    }

    if (pushed > 0) {
      await metadata.markPush(DateTime.now());
      await metadata.markError(null);
      // Wake the other devices: their 10 s heartbeat probes notice this bump
      // within seconds instead of on their 60 s timer. Best-effort — a failed
      // bump never fails the push that earned it.
      await _bumpHeartbeat(lastEntity);
    } else if (lastError != null) {
      await metadata.markError(lastError);
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
      await remote.writeHeartbeat(
        organizationId: organizationId,
        data: {
          'lastWriteBy': session.uid,
          if (lastEntity case final entity) 'lastEntity': entity,
          'version': DateTime.now().millisecondsSinceEpoch,
        },
      );
      final beat = await remote.readHeartbeat(organizationId);
      if (beat.exists) {
        await metadata.set(
          SyncMetadata.heartbeatSeenMarkerKey,
          '${beat.data['lastWriteAt'] ?? beat.updatedAt ?? ''}#${beat.version}',
        );
      }
    } on Object {
      // Heartbeat is a notification, not data: never fail the push over it.
    }
  }

  /// Per-entry guard: the data-source contract returns [PushResult], but a
  /// hostile map (raw Timestamp) or a throwing implementation must not escape
  /// as an unhandled exception and strand the batch in `in_flight`.
  Future<PushResult> _pushOneGuarded(QueueEntry entry) async {    try {
      return await _pushOne(entry);
    } on Object catch (e) {
      return PushResult.retryable('$e');
    }
  }

  /// The remote call for one entry, tombstone or document.
  Future<PushResult> _pushOne(QueueEntry entry) {
    final entity = entry.entity;
    if (entity == null) {
      // Unreachable from [runOnce]: unresolvable entities are rejected locally
      // before they reach the send phase.
      return Future.value(PushResult.retryable('Unknown entity type ${entry.entityType}'));
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

  Future<PushResult> _pushDocument(SyncEntity entity, QueueEntry entry) async {
    final organizationId = session.organizationId;
    if (organizationId.isEmpty) {
      return PushResult.retryable('no organization bound');
    }
    final payload = Map<String, dynamic>.from(entry.payload);
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
      baseVersion: entry.baseVersion,
    );
  }

  Future<PushResult> _pushTombstone(SyncEntity entity, QueueEntry entry) async {
    final organizationId = session.organizationId;
    if (organizationId.isEmpty) return PushResult.retryable('no organization bound');
    try {
      await remote.deleteTombstone(
        organizationId: organizationId,
        collection: entity.collection,
        documentId: entry.entityId,
      );
      return PushResult.success(entry.baseVersion + 1);
    } on Object catch (e) {
      return PushResult.retryable('$e');
    }
  }

  /// Automatic version-race resolution: no human tap.
  ///
  /// A rejection that carries the current remote document whose version moved
  /// past our base is an edit/edit race, not an auth problem. Parking it for a
  /// manual keep_local/keep_remote tap (the old behavior) asked the user to
  /// decide every time two devices touched one row. Instead both sides apply
  /// the same deterministic rule, so the race converges without interaction:
  ///
  /// * remote unmoved since our last sync (`remoteVersion <= syncedVersion`)
  ///   → our queued edit is the only delta → re-push it on top;
  /// * remote moved → newest `updatedAt` wins the whole document (row-level
  ///   last-write-wins); ties and unparseable clocks break on `deviceId`.
  ///   Clocks are device-local, so skew can tilt a tie — deterministic and
  ///   audited beats silent or manual here; same-row concurrent edits are rare
  ///   (same-*document* collisions across devices are already impossible: entry
  ///   codes are device-scoped and history rows are append-only).
  ///
  /// Returns an [_AutoDecision] when this was a version race (resolved or
  /// deferred to backoff), null when it is NOT one — genuine denial, oversized,
  /// append-only entity, missing local row — those keep the manual path.
  /// Never throws: undecidable here means manual, never a crashed batch.
  Future<_AutoDecision?> _tryAutoRebase(QueueEntry entry, PushResult result) async {
    final entity = entry.entity;
    final remote = result.remote;
    if (entity == null || entity.appendOnly) return null;
    if (remote == null || remote.isEmpty) return null;
    if (entry.localRef == null) return null;
    final freshRemote = await _remoteForRace(entry, entity, result);
    if (freshRemote == null) return null;
    try {
      final db = await queue.dbHelper.database;
      final rows = await db.query(
        entity.localTable,
        where: 'id = ?',
        whereArgs: [entry.localRef],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final local = rows.first;
      final remoteVersion = (freshRemote['version'] as num?)?.toInt() ?? 0;
      final syncedVersion = (local['remote_version'] as num?)?.toInt() ?? 0;
      final bool localWins;
      if (remoteVersion <= syncedVersion) {
        // The remote document is exactly what we synced (or older): nobody
        // else changed it, our queued edit is the only delta.
        localWins = true;
      } else {
        localWins = _localIsNewer(
          localUpdatedAt: '${local['updated_at'] ?? ''}',
          remoteUpdatedAt: '${freshRemote['updatedAt'] ?? ''}',
          localDeviceId: session.deviceId,
          remoteDeviceId: '${freshRemote['deviceId'] ?? ''}',
        );
      }
      if (localWins) {
        return await _rebaseLocalWins(entry, entity, local, remoteVersion);
      }
      return await _rebaseRemoteWins(entry, entity, local, freshRemote, remoteVersion);
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
      if (_looksLikeVersionRace(entry, fresh.data, result.error)) return fresh.data;
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

  /// Newest `updatedAt` wins; ties (or unparseable clocks) break on `deviceId`
  /// so both devices reach the same verdict independently.
  bool _localIsNewer({
    required String localUpdatedAt,
    required String remoteUpdatedAt,
    required String localDeviceId,
    required String remoteDeviceId,
  }) {
    final local = DateTime.tryParse(localUpdatedAt);
    final remote = DateTime.tryParse(remoteUpdatedAt);
    if (local != null && remote != null && local != remote) {
      return local.isAfter(remote);
    }
    if (localDeviceId.isNotEmpty || remoteDeviceId.isNotEmpty) {
      return localDeviceId.compareTo(remoteDeviceId) >= 0;
    }
    return true;
  }

  /// Re-push the current local row on top of [remoteVersion].
  Future<_AutoDecision> _rebaseLocalWins(
    QueueEntry entry,
    SyncEntity entity,
    Map<String, Object?> local,
    int remoteVersion,
  ) async {
    final organizationId = session.organizationId;
    if (organizationId.isEmpty) {
      return _AutoDecision.retry('no organization bound');
    }
    final payload = buildRemotePayload(
      entity,
      Map<String, Object?>.from(local).cast<String, dynamic>(),
      SyncPayloadContext(
        organizationId: organizationId,
        uid: session.uid,
        deviceId: session.deviceId,
        version: remoteVersion,
        versionField: 'version',
      ),
    );
    final retry = await remote.setDocument(
      organizationId: organizationId,
      collection: entity.collection,
      documentId: entry.entityId,
      data: payload,
      baseVersion: remoteVersion,
    );
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
    if (retry.kind == PushResultKind.payloadTooLarge) return const _AutoDecision.manual();
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
    final columns = await availableColumns(db, entity.localTable);
    final row = remoteToLocalRow(
      entity,
      Map<String, dynamic>.from(remote),
      organizationId: session.organizationId,
    )..['sync_state'] = 'synced';
    if (columns.contains('updated_at') && '${remote['updatedAt'] ?? ''}'.isNotEmpty) {
      row['updated_at'] = '${remote['updatedAt']}';
    }
    await db.update(
      entity.localTable,
      {
        for (final e in row.entries)
          if (e.key != 'id' && columns.contains(e.key)) e.key: e.value,
      },
      where: 'id = ?',
      whereArgs: [local['id']],
    );
    await _auditAuto(
      entry,
      'auto-rebase-remote',
      'remote v$remoteVersion newer, applied locally',
    );
    return _AutoDecision.settled(
      QueueSettlement.done(entry, remoteVersion: remoteVersion),
    );
  }

  Future<void> _auditAuto(QueueEntry entry, String strategy, String detail) async {
    final db = await queue.dbHelper.database;
    await tracedTransaction(db, 'push.auditAuto', (txn) async {
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
    final permission = entity.permission;
    if (permission == null) return true;
    final parsed = Permission.byId(permission);
    if (parsed == null) return true;
    return session.can(parsed);
  }

  Future<void> _auditDenied(QueueEntry entry) async {
    final db = await queue.dbHelper.database;
    await tracedTransaction(db, 'push.auditDenied', (txn) async {
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
    await tracedTransaction(db, 'push.auditConflict', (txn) async {
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
  const _AutoDecision.manual()
      : settlement = null,
        error = null;

  final QueueSettlement? settlement;
  final String? error;
}
