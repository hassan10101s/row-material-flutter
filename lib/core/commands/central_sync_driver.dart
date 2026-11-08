import 'dart:async';

import '../auth/permissions.dart';
import '../auth/session_source.dart';
import '../database/database_helper.dart';
import '../sync/sync_metadata.dart';
import '../sync/sync_data_changes.dart';
import '../sync/sync_run_scope.dart';
import '../network/transient_network_error.dart';
import '../utils/app_exceptions.dart';
import 'command_outbox.dart';
import 'command_contract.dart';
import 'central_projection.dart';
import 'central_sync_transport.dart';
import 'domain_manifest.dart';

class CentralSyncDriver {
  static const defaultInterval = Duration(seconds: 30);

  CentralSyncDriver({
    required this.databaseHelper,
    required this.source,
    required this.projection,
    required this.transport,
    required this.outbox,
    required this.metadata,
    this.interval = defaultInterval,
    this.onError,
    this.onManualRequest,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DatabaseHelper databaseHelper;
  final SessionSource source;
  final CentralProjection projection;
  final CentralSyncReader transport;
  final CommandOutbox outbox;
  final SyncMetadata metadata;
  final Duration interval;
  final DateTime Function() _now;
  int _networkFailures = 0;
  DateTime? _nextAutomaticRead;
  bool _reportedNetworkFailure = false;
  Timer? _timer;
  bool _running = false;
  bool _needsSnapshot = false;
  Future<int>? _flight;
  SyncRunScope? _activeScope;
  int? _manifestGeneration;
  Map<String, dynamic>? _manifest;
  Future<void> Function()? onApplied;

  /// Fires once when a full cycle flips the local cache from `required`/
  /// `catching_up` to `ready`: the archive is proven current and authoring
  /// may proceed. Startup housekeeping refused by the archive gate defers
  /// itself to this transition instead of failing the bind.
  Future<void> Function()? onReady;

  void Function(Object error)? onError;
  final void Function()? onManualRequest;

  void start() {
    if (_timer != null) return;
    unawaited(refreshForeground());
    _timer = Timer.periodic(interval, (_) {
      unawaited(refreshForeground());
    });
  }

  /// Used on startup, reconnect and resume. Automatic triggers never resume a
  /// quota-paused reader; only an explicit manual request may do that.
  Future<void> refreshForeground({bool immediate = false}) async {
    if (mayPoll != null && !mayPoll!()) return;
    if (_quotaStopped) return;
    if (!immediate &&
        _nextAutomaticRead != null &&
        _now().isBefore(_nextAutomaticRead!)) {
      return;
    }
    try {
      await syncNow(resumeQuota: false);
    } on Object {
      // _sync records the visible failure and reports it through onError.
    }
  }

  bool Function()? mayPoll;
  bool _quotaStopped = false;

  void _readRecovered() {
    _quotaStopped = false;
    _networkFailures = 0;
    _nextAutomaticRead = null;
    _reportedNetworkFailure = false;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Cancels an in-flight download at the next page or record boundary. Used
  /// on sign-out so a download started under one account can never materialize
  /// into another account's freshly bound database.
  void cancelActive() => _activeScope?.cancel();

  Future<int?> currentSequence() async {
    final session = source.session;
    final rows = await (await databaseHelper.database).query(
      'central_sync_state',
      columns: const ['applied_sequence'],
      where:
          'organization_id = ? AND uid = ? AND role = ? AND bootstrap_state = ? AND protocol_schema = ?',
      whereArgs: [
        session.organizationId,
        session.uid,
        session.rolesKey,
        'ready',
        commandSchemaVersion,
      ],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : (rows.single['applied_sequence'] as num).toInt();
  }

  Future<int> syncNow({
    int? throughSequence,
    bool forceSnapshot = false,
    bool resumeQuota = true,
  }) {
    // A manual request is the only way to resume after quota exhaustion.
    if (resumeQuota) {
      _quotaStopped = false;
      onManualRequest?.call();
    }
    final current = _flight;
    if (current != null) {
      return current.then((sequence) {
        if (!forceSnapshot &&
            (throughSequence == null || sequence >= throughSequence)) {
          return sequence;
        }
        return syncNow(
          throughSequence: throughSequence,
          forceSnapshot: forceSnapshot,
          resumeQuota: false,
        );
      });
    }
    final rebuild = forceSnapshot || _needsSnapshot;
    final future = _sync(
      throughSequence: throughSequence,
      forceSnapshot: rebuild,
    );
    _flight = future;
    return future.whenComplete(() {
      if (identical(_flight, future)) _flight = null;
    });
  }

  Future<int> _sync({int? throughSequence, required bool forceSnapshot}) async {
    if (_running) return _appliedSequence();
    _running = true;
    // One scope per run: every page fetch, event apply and state transition
    // below re-checks the SAME session and database generation, so an account
    // or organization switch mid-download aborts the whole run instead of
    // applying stale pages into the new session's cache.
    final scope = SyncRunScope(source, databaseHelper);
    _activeScope = scope;
    try {
      final session = scope.session;
      if (!session.isSignedIn ||
          !session.isActiveMember ||
          !session.hasOrganization) {
        throw StateError('An active organization session is required.');
      }
      final db = await databaseHelper.database;
      if (_manifestGeneration != scope.generation) {
        final built = await buildDomainManifest(db);
        scope.check();
        _manifest = built;
        _manifestGeneration = scope.generation;
      }
      final manifest = _manifest!;
      scope.check();
      if (transport is ConsistentCentralSyncReader) {
        return await _consistentSync(
          transport as ConsistentCentralSyncReader,
          manifest,
          scope,
          forceSnapshot: forceSnapshot || _needsSnapshot,
          throughSequence: throughSequence,
        );
      }
      var rebuild = forceSnapshot || _needsSnapshot;
      // One-time migration: archives materialized from pre-fix placeholder
      // events store hash-of-placeholder payloads that can never match a
      // re-delivery or snapshot twin; only a fresh server download heals them.
      if (!rebuild && await projection.hasCommitTimePlaceholder()) {
        await projection.invalidateSnapshot();
        rebuild = true;
      }
      if (rebuild) await projection.invalidateSnapshot();
      final row = await _syncState(session.organizationId, session.uid);
      final roleMatches = row != null && row['role'] == session.rolesKey;
      final bootstrapState = roleMatches
          ? row['bootstrap_state'] as String
          : 'required';
      var cursor = roleMatches ? (row['applied_sequence'] as num).toInt() : 0;
      final initialCursor = cursor;
      var bootstrapped = false;
      if (!roleMatches || bootstrapState == 'required') {
        cursor = await _bootstrap(manifest, session.organizationId, scope);
        bootstrapped = true;
      }
      // `catching_up` resumes the event feed here without re-downloading the
      // snapshot; only a fully drained feed promotes the archive to `ready`.
      while (true) {
        scope.check();
        if (throughSequence != null && cursor >= throughSequence) break;
        final page = await transport.call({
          'mode': 'events',
          'organizationId': session.organizationId,
          'deviceId': session.deviceId,
          'afterSequence': cursor,
        });
        final events = page['events'];
        if (events is! List) throw StateError('Invalid central event page.');
        if (events.isEmpty) {
          final serverThrough =
              (page['throughSequence'] as num?)?.toInt() ?? cursor;
          if (serverThrough > cursor) {
            throw const CentralSyncGap();
          }
          break;
        }
        for (final raw in events) {
          if (raw is! Map) throw StateError('Invalid central event.');
          final event = Map<String, dynamic>.from(raw);
          final sequence = (event['sequence'] as num).toInt();
          if (sequence != cursor + 1) {
            throw const CentralSyncGap();
          }
          final recordsRaw = event['records'];
          if (recordsRaw is! List) {
            throw StateError('Invalid approved record list.');
          }
          final committedAt = event['committedAt'];
          final records = recordsRaw
              .map((rawRecord) {
                if (rawRecord is! Map) {
                  throw StateError('Invalid approved record.');
                }
                final record = Map<String, dynamic>.from(rawRecord);
                return ApprovedRecord(
                  entityType: record['entityType'] as String,
                  entityId: record['entityId'] as String,
                  version: (record['version'] as num).toInt(),
                  // Resolve legacy commit-time placeholders to the event's
                  // real approval time BEFORE hashing or storing anything, so
                  // this channel and the snapshot channel agree byte for byte.
                  data: normalizeApprovedPayload(
                    Map<String, dynamic>.from(record['data'] as Map),
                    committedAt is String ? committedAt : null,
                  ),
                );
              })
              .toList(growable: false);
          scope.check();
          await projection.applyEvent(
            sequence: sequence,
            operationId: event['operationId'] as String,
            records: records,
            scope: scope,
          );
          cursor = sequence;
          if (throughSequence != null && cursor >= throughSequence) break;
        }
        if (page['hasMore'] != true && throughSequence == null) break;
      }
      // Consistency proof for authoring: the loop above exits only at the
      // server's current head (an empty page at the head, or a final page that
      // ends exactly at it) while the same session held the whole run. An
      // explicit `throughSequence` target cannot prove that, so `ready` waits
      // for the next full cycle.
      if (throughSequence == null) {
        await projection.markReady(scope: scope);
        // The archive became provably current somewhere in this run (fresh
        // bootstrap installs `catching_up`, then this markReady promotes it,
        // or a resumed run drained the remaining events). One hook per flip.
        if (bootstrapState != 'ready') {
          try {
            await onReady?.call();
          } on Object catch (error) {
            onError?.call(error);
          }
        }
      }
      _readRecovered();
      await metadata.markPull(DateTime.now().toUtc());
      await metadata.markError(null);
      if (cursor > initialCursor || bootstrapped) {
        try {
          await onApplied?.call();
        } on Object catch (error) {
          onError?.call(error);
        }
      }
      _needsSnapshot = false;
      return cursor;
    } on Object catch (error) {
      if ('$error'.contains('RESOURCE_EXHAUSTED')) _quotaStopped = true;
      if (error is CentralSyncGap) _needsSnapshot = true;
      if (error is! SyncRunCancelled) {
        if (isTransientNetworkFailure(error)) {
          if (_networkFailures < 5) _networkFailures++;
          final delayMs =
              interval.inMilliseconds * (1 << (_networkFailures - 1));
          _nextAutomaticRead = _now().add(
            Duration(milliseconds: delayMs > 300000 ? 300000 : delayMs),
          );
          if (!_reportedNetworkFailure) onError?.call(error);
          _reportedNetworkFailure = true;
        } else {
          onError?.call(error);
        }
        try {
          await metadata.markError(
            isTransientNetworkFailure(error)
                ? TransientNetworkError(error).message
                : AppError.friendly(error),
          );
        } on Object {
          // Preserve the original transport or projection failure.
        }
      }
      rethrow;
    } finally {
      if (identical(_activeScope, scope)) _activeScope = null;
      _running = false;
      SyncDataChanges.notifyStatus();
    }
  }

  Future<int> _consistentSync(
    ConsistentCentralSyncReader reader,
    Map<String, dynamic> manifest,
    SyncRunScope scope, {
    required bool forceSnapshot,
    int? throughSequence,
  }) async {
    final session = scope.session;
    final boundary = await reader.readHead();
    scope.check();
    if (boundary.manifestVersion != manifest['manifestVersion']) {
      throw StateError('Domain manifest version mismatch');
    }
    if (throughSequence != null && boundary.sequence < throughSequence) {
      throw const CentralSyncGap();
    }
    var state = await _syncState(session.organizationId, session.uid);
    final rebuild =
        forceSnapshot ||
        state == null ||
        state['protocol_schema'] != commandSchemaVersion ||
        state['role'] != session.rolesKey ||
        state['bootstrap_state'] == 'required' ||
        await projection.hasCommitTimePlaceholder();
    if (rebuild) {
      await projection.invalidateSnapshot();
      await projection.beginBootstrap(
        manifestVersion: boundary.manifestVersion,
        h0: boundary.sequence,
        scope: scope,
      );
      final definitions = manifest['entities'] as Map;
      final types = definitions.keys.cast<String>().toList()..sort();
      if (session.can(Permission.byId('audit.read')!)) types.add('auditLog');
      for (final type in types) {
        final def = type == 'auditLog'
            ? const {'readPermission': 'audit.read'}
            : definitions[type] as Map;
        final permission = Permission.byId('${def['readPermission']}');
        if (def['privateRead'] == true ||
            permission == null ||
            !session.can(permission)) {
          continue;
        }
        String? after;
        do {
          final page = await reader.readSnapshotPage(
            type,
            boundary,
            after: after,
          );
          scope.check();
          await projection.stageRecords(page.records, scope: scope);
          after = page.nextAfter;
        } while (after != null);
      }
      await projection.installFromStaging(
        throughSequence: boundary.sequence,
        coveredOperationIds: await outbox.approvedOperationIdsThrough(
          boundary.sequence,
        ),
        scope: scope,
      );
      await projection.markReady(scope: scope);
      await onReady?.call();
      await onApplied?.call();
    } else {
      final cursor = (state['applied_sequence'] as num).toInt();
      if (cursor > boundary.sequence) throw const CentralSyncGap();
      if (cursor < boundary.sequence) {
        final changes = await reader.readChanges(cursor, boundary);
        scope.check();
        await projection.applyCycle(
          afterSequence: cursor,
          throughSequence: boundary.sequence,
          records: changes.records,
          operationIds: changes.operationIds,
          scope: scope,
        );
        await onApplied?.call();
      } else {
        await projection.markReady(scope: scope);
      }
    }
    _needsSnapshot = false;
    _readRecovered();
    await metadata.markPull(DateTime.now().toUtc());
    await metadata.markError(null);
    return boundary.sequence;
  }

  /// Disk-staged bootstrap (production acceptance 2). The download never
  /// accumulates in memory or in one giant transaction:
  ///
  /// 1. `beginSnapshot` fixes the watermark H0 (and the manifest version).
  /// 2. Every snapshot page is staged in its own small transaction, with the
  ///    run scope re-checked between pages; a crash loses at most one page.
  /// 3. A second `beginSnapshot` probe observes H1 >= H0 (a regression means
  ///    the server lost events — refuse instead of installing a partial
  ///    history).
  /// 4. Change events H0+1..H1 are merged into staging under version rules
  ///    (higher version wins; two different payloads for the SAME approved
  ///    version abort as a server inconsistency), so documents updated or
  ///    deleted mid-download converge instead of installing stale bytes.
  /// 5. One transaction installs everything from staging at cursor H1 and
  ///    removes the staging; a crash rolls the whole install back and the
  ///    next cycle retries it.
  ///
  /// The `central_bootstrap_state` row makes the run resumable: the same
  /// account, role and manifest version skip straight to step 4 with staging
  /// intact; anything else clears staging and restarts from step 1.
  Future<int> _bootstrap(
    Map<String, dynamic> manifest,
    String organizationId,
    SyncRunScope scope,
  ) async {
    final session = scope.session;
    final db = await databaseHelper.database;
    final manifestVersion = (manifest['manifestVersion'] as num).toInt();
    var h0 = 0;
    var h1 = 0;
    final stored = await db.query(
      'central_bootstrap_state',
      where: 'organization_id = ? AND uid = ?',
      whereArgs: [organizationId, session.uid],
      limit: 1,
    );
    var resumable =
        stored.length == 1 &&
        stored.single['role'] == session.rolesKey &&
        (stored.single['manifest_version'] as num).toInt() == manifestVersion &&
        (stored.single['h1'] as num).toInt() > 0;
    if (resumable) {
      // The local manifest matches, but the server's may have moved on (a
      // new entity type went live while this device was offline). Verify
      // before reusing the staged pages.
      scope.check();
      final begin = await transport.call({
        'mode': 'beginSnapshot',
        'organizationId': organizationId,
        'deviceId': session.deviceId,
      });
      if ((begin['manifestVersion'] as num?)?.toInt() != manifestVersion) {
        resumable = false;
      } else {
        h0 = (stored.single['h0'] as num).toInt();
        h1 = (stored.single['h1'] as num).toInt();
      }
    }
    if (!resumable) {
      scope.check();
      final begin = await transport.call({
        'mode': 'beginSnapshot',
        'organizationId': organizationId,
        'deviceId': session.deviceId,
      });
      if ((begin['manifestVersion'] as num?)?.toInt() != manifestVersion) {
        throw StateError(
          'The client and server domain manifests do not match.',
        );
      }
      h0 = (begin['throughSequence'] as num).toInt();
      await projection.beginBootstrap(
        manifestVersion: manifestVersion,
        h0: h0,
        scope: scope,
      );
      final definitions = manifest['entities'] as Map;
      final entityTypes = definitions.keys.cast<String>().toList()..sort();
      for (final type in entityTypes) {
        if (type == 'auditLog') continue;
        final definition = definitions[type] as Map;
        final permission = Permission.byId('${definition['readPermission']}');
        if (definition['privateRead'] == true ||
            permission == null ||
            !session.can(permission)) {
          continue;
        }
        String? after;
        do {
          scope.check();
          final page = await transport.call({
            'mode': 'snapshotPage',
            'organizationId': organizationId,
            'deviceId': session.deviceId,
            'entityType': type,
            'throughSequence': h0,
            'after': after,
          });
          if ((page['throughSequence'] as num?)?.toInt() != h0 ||
              page['records'] is! List) {
            throw StateError('Central snapshot page changed its watermark.');
          }
          final records = <ApprovedRecord>[];
          for (final raw in page['records'] as List) {
            if (raw is! Map) {
              throw StateError('Invalid central snapshot record.');
            }
            final record = Map<String, dynamic>.from(raw);
            records.add(
              ApprovedRecord(
                entityType: record['entityType'] as String,
                entityId: record['entityId'] as String,
                version: (record['version'] as num).toInt(),
                // Snapshot pages serve live documents with real timestamps; a
                // placeholder here would mean a server regression, never apply it.
                data: normalizeApprovedPayload(
                  Map<String, dynamic>.from(record['data'] as Map),
                  null,
                ),
              ),
            );
          }
          await projection.stageRecords(records, scope: scope);
          after = page['nextAfter'] as String?;
        } while (after != null);
      }
      // H1 probe: the watermark observed after the whole download. The merge
      // and install below cover H0+1..H1, so nothing committed during the
      // download is lost; the regular event loop continues from H1.
      scope.check();
      final probe = await transport.call({
        'mode': 'beginSnapshot',
        'organizationId': organizationId,
        'deviceId': session.deviceId,
      });
      if ((probe['manifestVersion'] as num?)?.toInt() != manifestVersion) {
        throw StateError('The domain manifest changed during bootstrap.');
      }
      h1 = (probe['throughSequence'] as num).toInt();
      if (h1 < h0) {
        throw StateError('The snapshot watermark regressed during bootstrap.');
      }
      await projection.updateBootstrapWatermark(h1: h1, scope: scope);
    }
    // Merge the events committed during the download into staging.
    var cursor = h0;
    while (cursor < h1) {
      scope.check();
      final page = await transport.call({
        'mode': 'events',
        'organizationId': organizationId,
        'deviceId': session.deviceId,
        'afterSequence': cursor,
      });
      final events = page['events'];
      if (events is! List) throw StateError('Invalid central event page.');
      if (events.isEmpty) throw const CentralSyncGap();
      for (final raw in events) {
        if (raw is! Map) throw StateError('Invalid central event.');
        final event = Map<String, dynamic>.from(raw);
        final sequence = (event['sequence'] as num).toInt();
        if (sequence != cursor + 1) throw const CentralSyncGap();
        final recordsRaw = event['records'];
        if (recordsRaw is! List) {
          throw StateError('Invalid approved record list.');
        }
        final committedAt = event['committedAt'];
        final records = recordsRaw
            .map((rawRecord) {
              if (rawRecord is! Map) {
                throw StateError('Invalid approved record.');
              }
              final record = Map<String, dynamic>.from(rawRecord);
              return ApprovedRecord(
                entityType: record['entityType'] as String,
                entityId: record['entityId'] as String,
                version: (record['version'] as num).toInt(),
                data: normalizeApprovedPayload(
                  Map<String, dynamic>.from(record['data'] as Map),
                  committedAt is String ? committedAt : null,
                ),
              );
            })
            .toList(growable: false);
        scope.check();
        await projection.stageRecords(records, scope: scope);
        cursor = sequence;
        if (cursor >= h1) break;
      }
    }
    await projection.installFromStaging(
      throughSequence: h1,
      coveredOperationIds: await outbox.approvedOperationIdsThrough(h1),
      scope: scope,
    );
    SyncDataChanges.notify();
    return h1;
  }

  Future<Map<String, Object?>?> _syncState(String orgId, String uid) async {
    final rows = await (await databaseHelper.database).query(
      'central_sync_state',
      where: 'organization_id = ? AND uid = ?',
      whereArgs: [orgId, uid],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
  }

  Future<int> _stateSequence(String orgId, String uid) async {
    final rows = await (await databaseHelper.database).query(
      'central_sync_state',
      columns: const ['applied_sequence'],
      where: 'organization_id = ? AND uid = ?',
      whereArgs: [orgId, uid],
      limit: 1,
    );
    return rows.isEmpty ? 0 : (rows.single['applied_sequence'] as num).toInt();
  }

  Future<int> _appliedSequence() =>
      _stateSequence(source.session.organizationId, source.session.uid);
}
