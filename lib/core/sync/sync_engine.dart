import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'audit_logger.dart';import 'audit_trail.dart';
import 'conflict_resolver.dart';
import 'entity_registry.dart';
import '../network/connectivity_service.dart';
import 'push_worker.dart';
import 'pull_worker.dart';
import 'remote/remote_data_source.dart';
import 'sync_metadata.dart';
import 'sync_queue.dart';

/// What the shell badge shows (plan §25).
class SyncStatusSnapshot {
  const SyncStatusSnapshot({
    required this.online,
    required this.syncing,
    required this.pending,
    required this.blocked,
    required this.conflicts,
    this.lastPushAt,
    this.lastPullAt,
    this.lastError,
    this.degraded = false,
  });

  final bool online;
  final bool syncing;
  final int pending;
  final int blocked;
  final int conflicts;
  final DateTime? lastPushAt;
  final DateTime? lastPullAt;
  final String? lastError;

  /// True when Firebase could not be initialized (offline-first degraded mode).
  final bool degraded;

  String get badge {
    if (!online) return 'Offline';
    if (syncing) return 'Syncing';
    if (blocked > 0) return 'Blocked $blocked';
    if (pending > 0) return 'Pending $pending';
    return 'Online';
  }
}

/// What [SyncEngine.reconcileAfterRestore] found (plan §14-P11.2).
@immutable
class RestoreReport {
  const RestoreReport({
    this.orphanedEntries = 0,
    this.requeuedRows = 0,
    this.deviceIdReplaced = false,
  });

  /// Queue entries whose local row is not in the restored file: they became
  /// visible conflicts instead of being dropped.
  final int orphanedEntries;

  /// Rows that were pushed to `queued` again so their change reaches the server.
  final int requeuedRows;

  /// The restored file carried another device's id, which was replaced.
  final bool deviceIdReplaced;

  bool get isClean => orphanedEntries == 0 && requeuedRows == 0 && !deviceIdReplaced;
}

/// Orchestrates the offline-first lifecycle (plan §9.3, §13):
/// timer every 60s · immediate run when connectivity returns · manual "sync
/// now" · dashboard-driven 5-minute pulls.
class SyncEngine {
  SyncEngine({
    required this.pushWorker,
    required this.pullWorker,
    required this.queue,
    required this.metadata,
    required this.audit,
    required this.connectivity,
    this.auditPullWorker,
    this.trail,
    this.timerInterval = const Duration(seconds: 60),
    this.dashboardInterval = const Duration(minutes: 5),
  });

  final PushWorker pushWorker;
  final PullWorker pullWorker;
  final SyncQueue queue;
  final SyncMetadata metadata;
  final AuditLogger audit;
  final ConnectivityService connectivity;

  /// One recovery sweep per process, not per cycle: [SyncQueue.recoverStalled]
  /// is cheap but touches every stranded row, and the point is to clean up after
  /// *startup*, not on every manual "sync now".
  bool _stalledRecovered = false;

  /// Hands rows stranded by a crashed push back to the pending pool.
  ///
  /// A row only reaches `in_flight` via [SyncQueue.claim], and the settlement
  /// that would move it on never runs if the process dies in between — leaving a
  /// permanently un-drainable row that also cannot be retried by hand, because
  /// the Sync screen only surfaces `failed`/`conflict`.
  ///
  /// Best-effort: a failure here must never abort the data cycle, so the error
  /// goes through the same reporting path as the rest of [syncNow].
  Future<void> _recoverStalledRows() async {
    if (_stalledRecovered) return;
    try {
      final recovered = await queue.recoverStalled();
      if (recovered > 0) {
        await _markErrorSafely('Recovered $recovered push(es) interrupted by an app exit.');
      }
    } on Object catch (e) {
      await _markErrorSafely('Push recovery failed: $e');
    } finally {
      _stalledRecovered = true;
    }
  }

  /// The audit trail is pulled on its own (`audit.read` is a separate
  /// permission, and the collection is append-only), never as part of the data
  /// cycle.
  final PullWorker? auditPullWorker;

  /// Retention (plan §9.7) is driven from the same cycle.
  final AuditTrail? trail;

  final Duration timerInterval;
  final Duration dashboardInterval;

  final StreamController<SyncStatusSnapshot> _status =
      StreamController<SyncStatusSnapshot>.broadcast();

  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _timer;
  Timer? _dashboardTimer;
  bool _running = false;
  bool _inFlight = false;
  bool _disposed = false;
  bool _degraded = false;

  /// Single-flight guard: never two cycles at once.
  bool get isSyncing => _inFlight;

  Stream<SyncStatusSnapshot> get status => _status.stream;

  void start() {
    if (_running || _disposed) return;
    _running = true;
    connectivity.start();
    _connectivitySubscription = connectivity.onStatusChange.listen((online) {
      if (online) {
        unawaited(syncNow(reason: 'connectivity'));
      } else {
        unawaited(_emit());
      }
    });
    _timer = Timer.periodic(timerInterval, (_) => unawaited(syncNow(reason: 'timer')));
    unawaited(syncNow(reason: 'start'));
  }

  /// Dashboard visible: pull at most every 5 minutes (plan §9.3).
  void onDashboardVisible() {
    if (_disposed) return;
    _dashboardTimer?.cancel();
    _dashboardTimer = Timer.periodic(
      dashboardInterval,
      (_) => unawaited(syncNow(reason: 'dashboard', pullOnly: true)),
    );
    unawaited(syncNow(reason: 'dashboard', pullOnly: true));
  }

  void onDashboardHidden() {
    _dashboardTimer?.cancel();
    _dashboardTimer = null;
  }

  /// Push first, then pull: local edits must reach the server before remote
  /// changes are compared against them.
  Future<SyncStatusSnapshot> syncNow({String reason = 'manual', bool pullOnly = false}) async {
    // A status read is a reporting concern, never a reason to fail a cycle. The
    // counters go through the memoized sync queue, so a database that is being
    // closed underneath us (an organization switch, a restore) makes
    // `_current()` throw `DatabaseException(error database_closed)`. That used
    // to escape here as an *unhandled* exception, because the `try` below only
    // wrapped the push/pull work - the badge killed the app on startup.
    if (_disposed || _inFlight) return _safeCurrent();
    if (!connectivity.isOnline) {
      await _emit();
      return _safeCurrent();
    }
    _inFlight = true;
    await _emit();
    try {
      await _recoverStalledRows();
      if (!pullOnly) {
        await pushWorker.runOnce();
      }
      await pullWorker.runOnce();
      // The audit trail and its retention must never fail the data cycle.
      await _auditMaintenance();
    } on Object catch (e) {
      await _markErrorSafely('$e');
    } finally {
      _inFlight = false;
      await _emit();
    }
    return _safeCurrent();
  }

  /// [SyncStatusSnapshot] or a best-effort empty one; never throws.
  Future<SyncStatusSnapshot> _safeCurrent() async {
    try {
      return await _current();
    } on Object {
      return SyncStatusSnapshot(
        online: connectivity.isOnline,
        syncing: _inFlight,
        pending: 0,
        blocked: 0,
        conflicts: 0,
        degraded: _degraded,
      );
    }
  }

  Future<void> _markErrorSafely(String message) async {
    try {
      await metadata.markError(message);
    } on Object {
      // The metadata write needs the same database that just failed; a failure
      // here must not replace the original error with a second one.
    }
  }

  /// Pull the audit documents of the other devices, then apply the retention
  /// policy. Every failure here is swallowed on purpose: a member without
  /// `audit.read`, or a revoked device, must not turn the sync badge red.
  Future<void> _auditMaintenance() async {
    try {
      await auditPullWorker?.runOnce();
    } on Object catch (e) {
      debugPrint('[sync] audit pull skipped: $e');
    }
    try {
      await trail?.runRetention();
    } on Object catch (e) {
      debugPrint('[sync] audit retention skipped: $e');
    }
  }

  /// What a restore reconciliation found, so the UI can tell the user what
  /// happened instead of silently losing a sample (plan §14-P11.2).
  static const RestoreReport emptyRestore = RestoreReport();

  /// Keep the local queue honest after a backup restore (plan §14-P11.2).
  ///
  /// A restored file is coherent with itself (rows + queue + cursors were copied
  /// together), but the **server** has moved on since the backup was taken:
  ///
  ///  * a queued row whose local copy vanished (a backup older than the write, or
  ///    a file restored onto another device) is **surfaced as a conflict** - it
  ///    is never deleted, a sample must not disappear without an explanation;
  ///  * a queued row whose `base_version` is behind the server will be rejected
  ///    by the Rules' optimistic version check, and the push worker turns that
  ///    into the same kind of conflict row;
  ///  * the **device id belongs to the installation, not to the backup**: the
  ///    restored one is replaced, otherwise two devices would push under the
  ///    same id and `devices/{id}` would be ambiguous.
  Future<RestoreReport> reconcileAfterRestore() async {
    final db = await queue.dbHelper.database;
    var orphaned = 0;
    var requeued = 0;
    var deviceIdReplaced = false;

    // A restore on another device carries that device's id.
    final currentDeviceId = pushWorker.session.deviceId;
    if (currentDeviceId.isNotEmpty) {
      final stored = await metadata.get(SyncMetadata.deviceIdKey);
      if (stored.isNotEmpty && stored != currentDeviceId) {
        await metadata.set(SyncMetadata.deviceIdKey, currentDeviceId);
        deviceIdReplaced = true;
      }
    }

    final rows = await db.query(
      'sync_queue',
      columns: ['id', 'entity_type', 'entity_id', 'local_ref', 'base_version', 'status'],
      where: "status IN ('pending','in_flight')",
    );

    // One `id IN (...)` query per table instead of one per queue row. The old
    // loop asked the shared background isolate once per entry, so a restore
    // with a few hundred queued rows spent that many round trips on a lookup
    // whose answer is a set membership test.
    final refsByTable = <String, Set<int>>{};
    for (final row in rows) {
      final entity = SyncEntity.byType('${row['entity_type']}');
      final localRef = (row['local_ref'] as num?)?.toInt();
      if (entity == null || localRef == null) continue;
      refsByTable.putIfAbsent(entity.localTable, () => <int>{}).add(localRef);
    }
    final presentRefs = <String, Set<int>>{};
    for (final entry in refsByTable.entries) {
      presentRefs[entry.key] = await _existingRefs(db, entry.key, entry.value);
    }

    for (final row in rows) {
      final entity = SyncEntity.byType('${row['entity_type']}');
      final localRef = (row['local_ref'] as num?)?.toInt();
      if (entity == null || localRef == null) continue;
      if (!(presentRefs[entity.localTable]?.contains(localRef) ?? false)) {
        // The restored copy does not contain the row: surface it instead of
        // dropping data silently.
        await db.insert('sync_conflicts', {
          'entity_type': '${row['entity_type']}',
          'entity_id': '${row['entity_id']}',
          'direction': 'push_rejected',
          'local_payload': null,
          'remote_payload': null,
          'detected_at': DateTime.now().toIso8601String(),
          'resolution': null,
          'resolved_at': null,
        });
        await db.update(
          'sync_queue',
          {'status': 'conflict', 'last_error': 'Missing after restore'},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        orphaned++;
        continue;
      }
      // The row is there: make sure it is queued for a push even if the queue
      // entry was interrupted mid-flight, so a restored backup cannot strand a
      // change that the server never saw. The state is not read back per row
      // either: anything not already `queued` is stamped, which is idempotent.
      await db.update(
        entity.localTable,
        {'sync_state': 'queued'},
        where: 'id = ?',
        whereArgs: [localRef],
      );
      requeued++;
    }
    await queue.purgeSolved();
    return RestoreReport(
      orphanedEntries: orphaned,
      requeuedRows: requeued,
      deviceIdReplaced: deviceIdReplaced,
    );
  }

  /// Which of [refs] exist in [table], as one `id IN (...)` query.
  ///
  /// SQLite caps a host parameter at 999, so long lists are chunked rather than
  /// silently truncated.
  static Future<Set<int>> _existingRefs(
    DatabaseExecutor db,
    String table,
    Set<int> refs,
  ) async {
    const chunkSize = 500;
    final present = <int>{};
    final all = refs.toList(growable: false);
    for (var offset = 0; offset < all.length; offset += chunkSize) {
      final end =
          offset + chunkSize < all.length ? offset + chunkSize : all.length;
      final chunk = all.sublist(offset, end);
      final found = await db.query(
        table,
        columns: ['id'],
        where: 'id IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
      for (final row in found) {
        present.add((row['id'] as num).toInt());
      }
    }
    return present;
  }

  void markDegraded({bool value = true}) {
    _degraded = value;
    unawaited(_emit());
  }

  /// The status snapshot, in **three** round trips instead of six.
  ///
  /// `_emit` runs on every sync trigger, every connectivity change and on a
  /// timer, so this is the hottest read in the app. Each `await` below used to be
  /// its own message to the one shared background isolate, holding the
  /// connection's non-reentrant lock for the duration - and the conflicts count
  /// came from `listConflicts(limit: 1000)`, which pulled a thousand whole rows
  /// across the isolate boundary to produce an integer.
  Future<SyncStatusSnapshot> _current() async {
    // Parallel, not sequential: each of these is a message to the single FFI
    // isolate, and awaiting them one after another doubles the badge latency
    // whenever the connection is busy (bootstrap, dashboard load). Neither
    // holds the lock while the other runs, so overlapping is safe.
    final results = await Future.wait([
      queue.countBadge(),
      metadata.readAll([
        SyncMetadata.lastPullAtKey,
        SyncMetadata.lastPushAtKey,
        SyncMetadata.lastErrorKey,
      ]),
    ]);
    final badge = results[0] as SyncQueueCounts;
    final keys = results[1] as Map<String, String>;
    final lastError = keys[SyncMetadata.lastErrorKey] ?? '';
    return SyncStatusSnapshot(
      online: connectivity.isOnline,
      syncing: _inFlight,
      pending: badge.pending,
      blocked: badge.blocked,
      conflicts: badge.conflicts,
      lastPushAt: _asDate(keys[SyncMetadata.lastPushAtKey]),
      lastPullAt: _asDate(keys[SyncMetadata.lastPullAtKey]),
      lastError: lastError.isEmpty ? null : lastError,
      degraded: _degraded,
    );
  }

  static DateTime? _asDate(String? iso) =>
      (iso == null || iso.isEmpty) ? null : DateTime.tryParse(iso);


  Future<void> _emit() async {
    if (_disposed || _status.isClosed) return;
    // Never throws: `_emit` is reached from `unawaited` call sites
    // (`markDegraded`, the connectivity handler, the timers), where an escaping
    // exception would become an unhandled error instead of a stale badge.
    final snapshot = await _safeCurrent();
    if (_disposed || _status.isClosed) return;
    _status.add(snapshot);
  }

  Future<void> dispose() async {
    _disposed = true;
    _running = false;
    _timer?.cancel();
    _dashboardTimer?.cancel();
    await _connectivitySubscription?.cancel();
    await _status.close();
  }
}

/// Factory used by the service locator: keeps `SyncEngine` construction in one
/// place while the workers stay independently testable.
SyncEngine buildSyncEngine({
  required PushWorker pushWorker,
  required PullWorker pullWorker,
  required SyncQueue queue,
  required SyncMetadata metadata,
  required AuditLogger audit,
  required ConnectivityService connectivity,
  required ConflictResolver conflicts,
  required RemoteDataSource remote,
  PullWorker? auditPullWorker,
  AuditTrail? trail,
}) =>
    SyncEngine(
      pushWorker: pushWorker,
      pullWorker: pullWorker,
      queue: queue,
      metadata: metadata,
      audit: audit,
      connectivity: connectivity,
      auditPullWorker: auditPullWorker,
      trail: trail,
    );
