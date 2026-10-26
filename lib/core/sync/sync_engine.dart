import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'audit_logger.dart';
import 'audit_trail.dart';
import 'conflict_resolver.dart';
import 'entity_registry.dart';
import '../network/connectivity_service.dart';
import '../utils/app_dates.dart';
import 'push_worker.dart';
import 'pull_worker.dart';
import 'remote/remote_data_source.dart';
import 'sync_metadata.dart';
import 'sync_queue.dart';
import 'sync_data_changes.dart';
import 'sync_run_scope.dart';
import 'sync_cycle_lease.dart';

/// What the shell badge shows (plan §25).
class SyncStatusSnapshot {
  const SyncStatusSnapshot({
    required this.online,
    required this.syncing,
    required this.pending,
    required this.blocked,
    required this.conflicts,
    this.failed = 0,
    this.pullIncomplete = false,
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
  final int failed;
  final bool pullIncomplete;
  final DateTime? lastPushAt;
  final DateTime? lastPullAt;
  final String? lastError;

  /// True when Firebase could not be initialized (offline-first degraded mode).
  final bool degraded;

  /// Fully synced (plan §10): no pending/in-flight/failed/blocked/conflicts
  /// AND a successful recent pull+push. Never true on errors or offline.
  bool get fullySynced =>
      online &&
      !syncing &&
      !pullIncomplete &&
      pending == 0 &&
      blocked == 0 &&
      conflicts == 0 &&
      failed == 0 &&
      lastPushAt != null &&
      lastPullAt != null &&
      (lastError == null || lastError!.isEmpty);

  String get badge {
    if (!online) return 'Offline';
    if (syncing) return 'Syncing';
    if (degraded) return 'Degraded';
    if (failed > 0) return 'Errors $failed';
    if (blocked > 0) return 'Blocked $blocked';
    if (conflicts > 0) return 'Conflicts $conflicts';
    if (pending > 0) return 'Pending $pending';
    if (pullIncomplete) return 'Downloading';
    if (fullySynced) return 'Synced';
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

  bool get isClean =>
      orphanedEntries == 0 && requeuedRows == 0 && !deviceIdReplaced;
}

/// Orchestrates the offline-first lifecycle (plan §9.3, §13):
/// timer every 60s (idle-gated: a full walk only when the outbox is not
/// drained or the heartbeat/fallback window says something changed) ·
/// immediate run when connectivity returns · debounced run seconds after
/// every local mutation · heartbeat probe every 10s that pulls only when
/// another device wrote · manual "sync now" · dashboard-driven 5-minute
/// pulls.
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
    this.allowPush,
    this.allowPull,
    this.allowAuditPull,
    this.timerInterval = const Duration(seconds: 60),
    this.dashboardInterval = const Duration(minutes: 5),
    this.heartbeatInterval = const Duration(seconds: 10),
    this.mutationDelay = const Duration(seconds: 2),
    this.fullPullFallback = const Duration(minutes: 15),
  });

  final bool Function()? allowPush;
  final bool Function()? allowPull;
  final bool Function()? allowAuditPull;
  final PushWorker pushWorker;
  final PullWorker pullWorker;
  final SyncQueue queue;
  final SyncMetadata metadata;
  SyncMetadata? _cycleMetadata;
  SyncMetadata get _runMetadata => _cycleMetadata ?? metadata;
  final AuditLogger audit;
  final ConnectivityService connectivity;

  /// Hands rows stranded by a crashed push back to the pending pool.
  ///
  /// A row only reaches `in_flight` via [SyncQueue.claim], and the settlement
  /// that would move it on never runs if the process dies in between — leaving a
  /// permanently un-drainable row that also cannot be retried by hand, because
  /// the Sync screen only surfaces `failed`/`conflict`.
  ///
  /// Runs at the head of **every** cycle, not once per process: only then can a
  /// batch stranded by a mid-cycle OS kill (or a mobile suspension whose
  /// in-flight future never resumed) be recovered on the next app launch, and a
  /// row stranded by an org switch can be recovered without a restart. The sweep
  /// is a single indexed `status = 'in_flight'` read that finds nothing on the
  /// normal path, so the earlier once-per-process concern (manual "sync now"
  /// storms) was guarding a cost that does not exist. Single-flight [syncNow]
  /// means no live claim can overlap this.
  ///
  /// Best-effort: a failure here must never abort the data cycle, so the error
  /// goes through the same reporting path as the rest of [syncNow].
  Future<void> _recoverStalledRows(void Function() checkCurrent) async {
    try {
      await queue.recoverEnvelopeUpgrade(checkCurrent: checkCurrent);
      final recovered = await queue.recoverStalled(checkCurrent: checkCurrent);
      if (recovered > 0) {
        await _markErrorSafely(
          'Recovered $recovered push(es) interrupted by an app exit.',
        );
      }
    } on Object catch (e) {
      await _markErrorSafely('Push recovery failed: $e');
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

  /// How often the shared heartbeat document is probed for other devices'
  /// writes (see [_pollHeartbeat]). One tiny document read per interval.
  final Duration heartbeatInterval;

  /// Coalescing window for [scheduleSync]: a burst of local writes (an import,
  /// a form save + its history rows) triggers one cycle, not one per row.
  final Duration mutationDelay;

  /// Maximum idle age of the last full pull walk before the 60 s timer runs
  /// one unconditionally — the safety net for a heartbeat bump that was lost
  /// with its push. Idle minutes in between cost only the pending/blocked
  /// count and the tiny heartbeat probe, never a full tree walk.
  final Duration fullPullFallback;

  /// Mobile-only hook: fired after a pull that applied remote rows.
  /// Wired by the service locator to `NotificationController.refresh`;
  /// null in tests and on desktop.
  Future<void> Function()? onPullApplied;

  final StreamController<SyncStatusSnapshot> _status =
      StreamController<SyncStatusSnapshot>.broadcast();

  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _timer;
  Timer? _dashboardTimer;
  Timer? _heartbeatTimer;
  Timer? _mutationTimer;
  int _lifecycleGeneration = 0;
  bool _lastPullComplete = false;
  bool _heartbeatPolling = false;
  bool _mutationNeedsPush = false;
  bool _deferredMutation = false;
  bool _deferredPush = false;
  bool _running = false;
  bool _inFlight = false;
  bool _disposed = false;
  bool _degraded = false;
  DateTime? _lastFullCycleAt;

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
    _timer = Timer.periodic(timerInterval, (_) => unawaited(_timerTick()));
    _heartbeatTimer = Timer.periodic(
      heartbeatInterval,
      (_) => unawaited(_pollHeartbeat()),
    );
    unawaited(syncNow(reason: 'start'));
  }

  /// A local mutation landed in the outbox ([SyncQueue.onEnqueued]: every
  /// repository funnels through `enqueue`). Push it within seconds instead of
  /// making the user wait for the 60 s timer or tap "sync now".
  ///
  /// Debounced and coalesced: safe to call per write, even in import loops.
  /// Quiet when stopped/disposed; the start/connectivity/timer triggers cover
  /// anything scheduled while offline or before [start].
  void scheduleSync({bool pullOnly = false}) {
    if (_disposed || !_running) return;
    _mutationNeedsPush = _mutationNeedsPush || !pullOnly;
    _mutationTimer?.cancel();
    _mutationTimer = Timer(mutationDelay, () {
      if (_disposed || !_running) return;
      final onlyPull = !_mutationNeedsPush;
      _mutationNeedsPush = false;
      unawaited(syncNow(reason: 'mutation', pullOnly: onlyPull));
    });
  }

  /// The 60 s timer leg, idle-gated.
  ///
  /// The old behavior ran a full cycle (push + pull walk + audit/parity
  /// maintenance) every [timerInterval] forever, so a device left on the
  /// dashboard burned a whole pull per minute although nothing had changed
  /// anywhere. Now: work happens only when the outbox is not drained (a
  /// failed push retried in place must not wait out the fallback window),
  /// when the last full walk is older than [fullPullFallback], or when
  /// [_pollHeartbeat] sees a marker bump — which is exactly the "another
  /// device pushed" signal the heartbeat contract already carries.
  Future<void> _timerTick() async {
    if (_disposed || !_running || _inFlight) return;
    try {
      if (!connectivity.isOnline) {
        await _emit();
        return;
      }
      final last = _lastFullCycleAt;
      if (last == null || DateTime.now().difference(last) >= fullPullFallback) {
        await syncNow(reason: 'timer');
        return;
      }
      final counts = await queue.countBadge();
      if (counts.pending > 0 ||
          counts.blocked > 0 ||
          counts.failed > 0 ||
          counts.conflicts > 0) {
        await syncNow(reason: 'timer');
        return;
      }
      await _pollHeartbeat();
    } on Object {
      // The timer never surfaces its own failures; the next tick retries.
    }
  }

  /// Heartbeat leg of the realtime story: one tiny `meta/state` read per
  /// [heartbeatInterval]; a full pull walk happens only when the heartbeat
  /// advanced past what this device has seen — i.e. another device pushed.
  ///
  /// A marker is acknowledged only after a complete successful pull. Failed
  /// and partial walks leave it pending for the next heartbeat probe.
  Future<void> _pollHeartbeat() async {
    if (_disposed || !_running || _inFlight || _heartbeatPolling) return;
    if (!connectivity.isOnline || !pushWorker.remote.isSignedIn) return;
    final organizationId = pushWorker.session.organizationId;
    if (organizationId.isEmpty) return;
    final scope = SyncRunScope(pushWorker.source, queue.dbHelper);
    _heartbeatPolling = true;
    try {
      final db = await queue.dbHelper.database;
      scope.check();
      final probeMetadata = metadata.bind(db);
      final beat = await pushWorker.remote.readHeartbeat(organizationId);
      if (!beat.exists) return;
      final marker = _heartbeatMarker(beat);
      if (marker.isEmpty || marker.startsWith('#')) return;
      final seen = await probeMetadata.get(SyncMetadata.heartbeatSeenMarkerKey);
      if (seen == marker) return;
      scope.check();
      if (_disposed || !_running || _inFlight) return;
      _lastPullComplete = false;
      await syncNow(reason: 'heartbeat', pullOnly: true);
      scope.check();
      if (_lastPullComplete && _running && !_disposed) {
        await probeMetadata.set(SyncMetadata.heartbeatSeenMarkerKey, marker);
        await probeMetadata.markHeartbeatSeen(DateTime.now());
      }
    } on Object {
      // An unconsumed marker remains visible for the next probe.
    } finally {
      _heartbeatPolling = false;
    }
  }

  /// Identity of a heartbeat write: the server's `lastWriteAt` plus the
  /// document version, so two pushes inside one millisecond still differ.
  /// The meta/state document carries no `updatedAt` envelope field — the
  /// timestamp lives in `lastWriteAt` (see the rules' `hasOnly` list).
  static String _heartbeatMarker(RemoteDocument beat) =>
      '${beat.data['lastWriteAt'] ?? beat.updatedAt ?? ''}#${beat.version}';

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

  /// Stops every timer and the connectivity subscription (plan §3/§8).
  /// Called on sign-out / leave so no heartbeat, push or pull runs after the
  /// company database is unbound. The engine is single-flight safe to restart
  /// via [start] on the next active bind.
  void stop() {
    _lifecycleGeneration++;
    pushWorker.cancel();
    pullWorker.cancel();
    auditPullWorker?.cancel();
    _lastFullCycleAt = null;
    _lastSnapshot = null;
    _lastProblems = null;
    _mutationNeedsPush = false;
    _deferredMutation = false;
    _deferredPush = false;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _dashboardTimer?.cancel();
    _dashboardTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _mutationTimer?.cancel();
    _mutationTimer = null;
    unawaited(_connectivitySubscription?.cancel());
    _connectivitySubscription = null;
  }

  /// Push first, then pull: local edits must reach the server before remote
  /// changes are compared against them.
  Future<SyncStatusSnapshot> syncNow({
    String reason = 'manual',
    bool pullOnly = false,
  }) async {
    // A status read is a reporting concern, never a reason to fail a cycle. The
    // counters go through the memoized sync queue, so a database that is being
    // closed underneath us (an organization switch, a restore) makes
    // `_current()` throw `DatabaseException(error database_closed)`. That used
    // to escape here as an *unhandled* exception, because the `try` below only
    // wrapped the push/pull work - the badge killed the app on startup.
    if (_disposed) return _safeCurrent();
    if (_inFlight) {
      if (reason == 'mutation') {
        _deferredMutation = true;
        _deferredPush = _deferredPush || !pullOnly;
      }
      return _safeCurrent();
    }
    if (!connectivity.isOnline) {
      await _emit();
      return _safeCurrent();
    }
    final generation = _lifecycleGeneration;
    final scope = SyncRunScope(pushWorker.source, queue.dbHelper);
    SyncCycleLease? lease;
    void checkRun() {
      scope.check();
      if (lease != null && !lease.held) throw const SyncRunCancelled();
      if (generation != _lifecycleGeneration || _disposed) {
        throw const SyncRunCancelled();
      }
    }

    _inFlight = true;
    _lastPullComplete = false;
    await _emit();
    try {
      checkRun();
      final db = await queue.dbHelper.database;
      scope.check();
      _cycleMetadata = metadata.bind(db);
      final acquired = SyncCycleLease(db);
      if (!await acquired.acquire()) throw const SyncRunCancelled();
      lease = acquired;
      pushWorker.cycleIsCurrent = () => acquired.held && scope.isCurrent;
      pullWorker.cycleIsCurrent = () => acquired.held && scope.isCurrent;
      auditPullWorker?.cycleIsCurrent = () => acquired.held && scope.isCurrent;
      checkRun();
      if (!pullOnly) await _recoverStalledRows(checkRun);
      checkRun();
      if (!pushWorker.remote.isSignedIn) {
        await _runMetadata.set(SyncMetadata.pullIncompleteKey, '1');
        await _runMetadata.markError(
          'Authentication is required to verify synchronization.',
        );
        throw const SyncRunCancelled();
      }
      String? pushError;
      if (!pullOnly && (allowPush?.call() ?? true)) {
        // One runOnce claims at most 400 rows: an 800-row desktop import left
        // half the queue pending while the badge already said "Synced".
        // Drain (bounded) so one manual "Sync now" actually finishes the push.
        for (var i = 0; i < 5; i++) {
          final pushReport = await pushWorker.runOnce();
          checkRun();
          pushError ??= pushReport.lastError;
          if (pushReport.pushed == 0) break;
        }
      }
      checkRun();
      final pullEnabled = allowPull?.call() ?? true;
      final pullReport = pullEnabled
          ? await pullWorker.runOnce()
          : PullReport.empty;
      checkRun();
      _lastPullComplete =
          pullEnabled &&
          pullReport.error == null &&
          pullReport.failed == 0 &&
          !pullReport.hasMore;
      if (_lastPullComplete && pushError == null) {
        await _runMetadata.markError(null);
      } else if (pushError != null &&
          pullReport.error == null &&
          pullReport.failed == 0) {
        await _runMetadata.markError(pushError);
      }
      if (pullReport.applied > 0) SyncDataChanges.notify();
      if (pullReport.applied > 0) {
        try {
          await onPullApplied?.call();
        } on Object catch (e) {
          debugPrint('[sync] onPullApplied skipped: $e');
        }
      }
      // The audit trail and its retention must never fail the data cycle.
      checkRun();
      if (pullEnabled || (allowAuditPull?.call() ?? true)) {
        await _auditMaintenance(pullAudit: allowAuditPull?.call() ?? true);
      }
      // Same for the parity sweep: best-effort, never aborts the cycle.
      checkRun();
      if (pullEnabled) await _parityMaintenance();
      // A completed walk counts as "full and recent" for the timer gate,
      // whatever reason started it (dashboard, heartbeat, manual…).
      checkRun();
      if (_lastPullComplete) _lastFullCycleAt = DateTime.now();
    } on SyncRunCancelled {
      // The response belongs to an earlier session/file, not the new one.
    } on Object catch (e) {
      await _markErrorSafely('$e');
    } finally {
      await lease?.release();
      _cycleMetadata = null;
      pushWorker.cycleIsCurrent = null;
      pullWorker.cycleIsCurrent = null;
      auditPullWorker?.cycleIsCurrent = null;
      _inFlight = false;
      if (_deferredMutation &&
          generation == _lifecycleGeneration &&
          scope.isCurrent) {
        final push = _deferredPush;
        _deferredMutation = false;
        _deferredPush = false;
        scheduleSync(pullOnly: !push);
      }
      await _emit();
    }
    // Problem bell (mobile-only): when conflicts/blocked/failed CHANGE, tell
    // the owner that some records never reached the other side — including
    // the "cloud-only row stayed invisible" days (a row that only failed to
    // pull is an error, not silence). Desktop leaves the hook null.
    await _notifyProblems();
    return _safeCurrent();
  }

  /// Mobile-only hook: fired when the unresolved problem total changes
  /// between two cycles. Wired by the service locator to
  /// `NotificationService.notifySyncProblems`; null on desktop/tests.
  void Function(int conflicts, int blocked, int failed)? onProblemsChanged;
  int? _lastProblems;

  Future<void> _notifyProblems() async {
    final hook = onProblemsChanged;
    if (hook == null) return;
    try {
      final snapshot = await _current();
      final total = snapshot.conflicts + snapshot.blocked + snapshot.failed;
      if (total == _lastProblems) return;
      // Stash before firing: a crash inside the consumer must not resurface
      // the same count on every cycle for the rest of the session.
      _lastProblems = total;
      if (total > 0) {
        hook(snapshot.conflicts, snapshot.blocked, snapshot.failed);
      }
    } on Object {
      // Reporting concern only; the badge on the shell already shows it.
    }
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
      await _runMetadata.markError(message);
    } on Object {
      // The metadata write needs the same database that just failed; a failure
      // here must not replace the original error with a second one.
    }
  }

  /// Pull the audit documents of the other devices, then apply the retention
  /// policy. Every failure here is swallowed on purpose: a member without
  /// `audit.read`, or a revoked device, must not turn the sync badge red.
  Future<void> _auditMaintenance({bool pullAudit = true}) async {
    if (pullAudit) {
      try {
        await auditPullWorker?.runOnce();
      } on Object catch (e) {
        debugPrint('[sync] audit pull skipped: $e');
      }
    }
    try {
      await trail?.runRetention();
    } on Object catch (e) {
      debugPrint('[sync] audit retention skipped: $e');
    }
  }

  /// Receiving-side parity sweep (plan §9.3-cross).
  ///
  /// Cursor-based pulls are deltas: any cursor that once advanced past a
  /// document it failed to apply — a schema rejection, a database error, an
  /// old bug — hides that document forever behind the cursor, and the device
  /// stays out of sync while the badge shows "Synced". This sweep re-verifies
  /// one entire collection per cycle by clearing that entity's pull cursor,
  /// so the next pull walks it from the beginning: already-applied rows
  /// re-fetch and skip cheaply (`remoteVersion == syncedVersion`), hidden
  /// rows come back, and locally queued edits are untouched.
  ///
  /// Triggers (checked once per cycle): a pull that reported skipped
  /// documents ("Pull skipped" in `last_error`), or `last_full_sync_at`
  /// being unset (never verified) or older than [parityInterval]. One
  /// entity per cycle keeps the cost bounded; after the last entity the
  /// sweep stamps `last_full_sync_at`.
  static const Duration parityInterval = Duration(days: 7);

  Future<void> _parityMaintenance() async {
    try {
      final entities = pullWorker.entities;
      if (entities.isEmpty) return;
      var pending = await _runMetadata.get(SyncMetadata.parityPendingKey);
      if (pending != '1') {
        if (!await _parityDue()) return;
        await _runMetadata.set(SyncMetadata.parityPendingKey, '1');
        await _runMetadata.set(SyncMetadata.parityIndexKey, '0');
      }
      final index =
          int.tryParse(await _runMetadata.get(SyncMetadata.parityIndexKey)) ??
          0;
      if (index >= entities.length) {
        await _runMetadata.set(SyncMetadata.parityPendingKey, '0');
        await _runMetadata.set(SyncMetadata.lastFullSyncAtKey, nowIso());
        return;
      }
      // While pulls are erroring, do not churn the cursor: re-walking from
      // the beginning while the same document keeps failing repeats the
      // failure against more documents. The sweep resumes once the error
      // clears (a successful pull removes `last_error`).
      final lastError = await _runMetadata.lastError();
      if (lastError.isNotEmpty) return;
      final entity = entities[index];
      await _runMetadata.remove(SyncMetadata.cursorKey(entity.type));
      await _runMetadata.set(SyncMetadata.parityIndexKey, '${index + 1}');
    } on Object catch (e) {
      debugPrint('[sync] parity sweep skipped: $e');
    }
  }

  /// True when a full re-verification is due: skipped-document pull errors
  /// are live, or the last completed sweep is missing/stale.
  Future<bool> _parityDue() async {
    final lastError = await _runMetadata.lastError();
    if (lastError.contains('Pull skipped')) return true;
    final last = DateTime.tryParse(
      await _runMetadata.get(SyncMetadata.lastFullSyncAtKey),
    );
    if (last == null) return true;
    return DateTime.now().difference(last) > parityInterval;
  }

  /// Marks a full re-verification due (restore, or anything that makes the
  /// local cursors untrustworthy). The sweep then advances one entity per
  /// cycle through [SyncEngine._parityMaintenance].
  Future<void> markParityDue() async {
    try {
      await _runMetadata.set(SyncMetadata.parityPendingKey, '1');
      await _runMetadata.set(SyncMetadata.parityIndexKey, '0');
    } on Object {
      // Best-effort: the weekly trigger covers a failed write here.
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
      final stored = await _runMetadata.get(SyncMetadata.deviceIdKey);
      if (stored.isNotEmpty && stored != currentDeviceId) {
        await _runMetadata.set(SyncMetadata.deviceIdKey, currentDeviceId);
        deviceIdReplaced = true;
      }
    }

    final rows = await db.query(
      'sync_queue',
      columns: [
        'id',
        'entity_type',
        'entity_id',
        'local_ref',
        'base_version',
        'status',
      ],
      where: "status IN ('pending','in_flight')",
    );

    // One `id IN (...)` query per table instead of one per queue row. The old
    // loop asked the shared background isolate once per entry, so a restore
    // with a few hundred queued rows spent that many round trips on a lookup
    // whose answer is a set membership test.
    final refsByTable = <String, ({SyncEntity entity, Set<int> refs})>{};
    for (final row in rows) {
      final entity = SyncEntity.byType('${row['entity_type']}');
      final localRef = (row['local_ref'] as num?)?.toInt();
      if (entity == null || localRef == null) continue;
      refsByTable
          .putIfAbsent(entity.localTable, () => (entity: entity, refs: <int>{}))
          .refs
          .add(localRef);
    }
    final presentRefs = <String, Set<int>>{};
    for (final entry in refsByTable.entries) {
      presentRefs[entry.key] = await _existingRefs(
        db,
        entry.key,
        entry.value.refs,
        pkColumn: entry.value.entity.pkColumn,
      );
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
        where: '${entity.pkColumn} = ?',
        whereArgs: [localRef],
      );
      requeued++;
    }
    await queue.purgeSolved();
    // The restored file is a snapshot of the past: documents tombstoned or
    // simply updated on other devices AFTER the backup was taken may sit
    // behind this device's old cursors. Schedule a full re-verification.
    await markParityDue();
    return RestoreReport(
      orphanedEntries: orphaned,
      requeuedRows: requeued,
      deviceIdReplaced: deviceIdReplaced,
    );
  }

  /// Which of [refs] exist in [table], as one `[pk] IN (...)` query.
  ///
  /// SQLite caps a host parameter at 999, so long lists are chunked rather than
  /// silently truncated. [pkColumn] is the table's primary key (`id` for every
  /// table except the user-authored QC ones).
  static Future<Set<int>> _existingRefs(
    DatabaseExecutor db,
    String table,
    Set<int> refs, {
    String pkColumn = 'id',
  }) async {
    const chunkSize = 500;
    final present = <int>{};
    final all = refs.toList(growable: false);
    for (var offset = 0; offset < all.length; offset += chunkSize) {
      final end = offset + chunkSize < all.length
          ? offset + chunkSize
          : all.length;
      final chunk = all.sublist(offset, end);
      final found = await db.query(
        table,
        columns: [pkColumn],
        where: '$pkColumn IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
      for (final row in found) {
        present.add((row[pkColumn] as num).toInt());
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
  ///
  /// Single-flight + bounded: overlapping badge refreshes (startup stampede:
  /// engine emit, shell badge, dashboard load) share one read instead of
  /// queueing N identical pairs behind real work, and a stuck lock serves the
  /// last snapshot after [statusReadTimeout] instead of wedging every awaiter.
  /// The parked read still completes and refreshes the cache for the next
  /// emit; only the waiting is cut short.
  Future<SyncStatusSnapshot> _current() {
    final flight = _currentFlight;
    if (flight != null) return flight;
    final next = _readCurrent()
        .then((snapshot) {
          _lastSnapshot = snapshot;
          return snapshot;
        })
        .timeout(statusReadTimeout, onTimeout: _fallbackSnapshot);
    _currentFlight = next;
    // Clearing is observed (not awaited): the derived future must not go
    // unhandled when the shared read itself fails — every awaiter already
    // receives the error through `next`.
    unawaited(
      next.then<void>(
        (_) {
          if (identical(_currentFlight, next)) _currentFlight = null;
        },
        onError: (_) {
          if (identical(_currentFlight, next)) _currentFlight = null;
        },
      ),
    );
    return next;
  }

  /// In-flight status read shared by overlapping refreshes.
  Future<SyncStatusSnapshot>? _currentFlight;

  /// Last good snapshot, served when the database does not answer in time.
  SyncStatusSnapshot? _lastSnapshot;

  /// Budget for one badge read. Past it the UI keeps the last snapshot
  /// instead of wedging: the parked SQLite call still completes (and updates
  /// the cache for the next emit), but no awaiter hangs on a stuck lock.
  /// Kept under sqflite's own 10s lock warning.
  static const Duration statusReadTimeout = Duration(seconds: 8);

  SyncStatusSnapshot _fallbackSnapshot() =>
      _lastSnapshot ??
      SyncStatusSnapshot(
        online: connectivity.isOnline,
        syncing: _inFlight,
        pending: 0,
        blocked: 0,
        conflicts: 0,
        degraded: _degraded,
      );

  Future<SyncStatusSnapshot> _readCurrent() async {
    final generation = queue.dbHelper.connectionGeneration;
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
        SyncMetadata.pullIncompleteKey,
      ]),
    ]);
    if (generation != queue.dbHelper.connectionGeneration) {
      throw const SyncRunCancelled();
    }
    final badge = results[0] as SyncQueueCounts;
    final keys = results[1] as Map<String, String>;
    final lastError = keys[SyncMetadata.lastErrorKey] ?? '';
    return SyncStatusSnapshot(
      online: connectivity.isOnline,
      syncing: _inFlight,
      pending: badge.pending,
      blocked: badge.blocked,
      conflicts: badge.conflicts,
      failed: badge.failed,
      pullIncomplete: keys[SyncMetadata.pullIncompleteKey] == '1',
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
    stop();
    _disposed = true;
    _running = false;
    _timer?.cancel();
    _dashboardTimer?.cancel();
    _heartbeatTimer?.cancel();
    _mutationTimer?.cancel();
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
  bool Function()? allowPush,
  bool Function()? allowPull,
  bool Function()? allowAuditPull,
  Duration timerInterval = const Duration(seconds: 60),
  Duration heartbeatInterval = const Duration(seconds: 10),
  Duration mutationDelay = const Duration(seconds: 2),
}) {
  final engine = SyncEngine(
    allowPush: allowPush,
    allowPull: allowPull,
    allowAuditPull: allowAuditPull,
    timerInterval: timerInterval,
    heartbeatInterval: heartbeatInterval,
    mutationDelay: mutationDelay,
    pushWorker: pushWorker,
    pullWorker: pullWorker,
    queue: queue,
    metadata: metadata,
    audit: audit,
    connectivity: connectivity,
    auditPullWorker: auditPullWorker,
    trail: trail,
  );
  // Every local mutation funnels through `enqueue`, so this one hook turns
  // all of them — inspections, lab, reference, members — into a debounced
  // push seconds later. Set here (not in the locator) so tests get it too.
  queue.onEnqueued = engine.scheduleSync;
  return engine;
}
