import 'dart:async';

import '../auth/permissions.dart';
import '../auth/session_source.dart';
import '../database/database_helper.dart';
import '../sync/sync_metadata.dart';
import '../sync/sync_data_changes.dart';
import '../sync/sync_run_scope.dart';
import 'command_outbox.dart';
import 'central_projection.dart';
import 'central_sync_transport.dart';
import 'domain_manifest.dart';

class CentralSyncDriver {
  CentralSyncDriver({
    required this.databaseHelper,
    required this.source,
    required this.projection,
    required this.transport,
    required this.outbox,
    required this.metadata,
    this.interval = const Duration(seconds: 20),
    this.onError,
  });

  final DatabaseHelper databaseHelper;
  final SessionSource source;
  final CentralProjection projection;
  final CentralSyncTransport transport;
  final CommandOutbox outbox;
  final SyncMetadata metadata;
  final Duration interval;
  Timer? _timer;
  bool _running = false;
  bool _needsSnapshot = false;
  Future<int>? _flight;
  SyncRunScope? _activeScope;
  Future<void> Function()? onApplied;
  void Function(Object error)? onError;

  void start() {
    if (_timer != null) return;
    unawaited(_scheduledSync());
    _timer = Timer.periodic(interval, (_) {
      unawaited(_scheduledSync());
    });
  }

  Future<void> _scheduledSync() async {
    try {
      await syncNow();
    } on Object {
      // _sync records the visible failure and reports it through onError.
    }
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
          'organization_id = ? AND uid = ? AND role = ? AND bootstrap_state = ?',
      whereArgs: [
        session.organizationId,
        session.uid,
        session.rolesKey,
        'ready',
      ],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : (rows.single['applied_sequence'] as num).toInt();
  }

  Future<int> syncNow({int? throughSequence, bool forceSnapshot = false}) {
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
      final manifest = await buildDomainManifest(db);
      scope.check();
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
      }
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
      if (error is CentralSyncGap) _needsSnapshot = true;
      if (error is! SyncRunCancelled) {
        onError?.call(error);
        try {
          await metadata.markError('$error');
        } on Object {
          // Preserve the original transport or projection failure.
        }
      }
      rethrow;
    } finally {
      if (identical(_activeScope, scope)) _activeScope = null;
      _running = false;
    }
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
        if (permission == null || !session.can(permission)) continue;
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
