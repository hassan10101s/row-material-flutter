import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../auth/session_source.dart';
import '../auth/permissions.dart';
import '../database/database_helper.dart';
import '../sync/entity_registry.dart';
import '../sync/sync_data_changes.dart';
import '../sync/sync_run_scope.dart';
import 'command_contract.dart';
import 'domain_manifest.dart';
import 'central_qc_audit_cache.dart';

class ApprovedRecord {
  const ApprovedRecord({
    required this.entityType,
    required this.entityId,
    required this.version,
    required this.data,
  });
  final String entityType;
  final String entityId;
  final int version;
  final Map<String, dynamic> data;
}

/// The pre-fix server wire format stamped event after-images with this literal
/// instead of the real approval time (وقت الاعتماد). Fresh events carry real
/// timestamps; the driver still resolves any legacy placeholder against the
/// event's `committedAt` so an event-delivered version and a snapshot-delivered
/// version of the same record stay byte-identical and hash identically.
const String centralCommitTimePlaceholder = '__CENTRAL_EVENT_COMMIT_TIME__';

/// Deep-copies [data], replacing every commit-time placeholder with
/// [committedAt]. Throws when a placeholder exists but no approval time is
/// known — storing such a record would corrupt the version fingerprint.
Map<String, dynamic> normalizeApprovedPayload(
  Map<String, dynamic> data,
  String? committedAt,
) {
  Object? walk(Object? value) {
    if (value is String && value == centralCommitTimePlaceholder) {
      if (committedAt == null || committedAt.isEmpty) {
        throw StateError(
          'An approved after-image carries an unresolved commit-time placeholder',
        );
      }
      return committedAt;
    }
    // Nested maps are rebuilt as Map<String, dynamic> - the fingerprint's
    // canonicalizer rejects loosely-typed maps, and a rebuild that silently
    // changed the container type would make twin payloads hash differently.
    if (value is Map) {
      return {
        for (final entry in value.entries) '${entry.key}': walk(entry.value),
      };
    }
    if (value is List) return [for (final value in value) walk(value)];
    return value;
  }

  return {for (final entry in data.entries) entry.key: walk(entry.value)};
}

bool _containsCommitTimePlaceholder(Object? value) {
  if (value is String) return value == centralCommitTimePlaceholder;
  if (value is Map) return value.values.any(_containsCommitTimePlaceholder);
  if (value is List) return value.any(_containsCommitTimePlaceholder);
  return false;
}

/// Materializes only trusted server after-images. Identity allocation, business
/// rows, immutable snapshots and the event checkpoint share one transaction.
class CentralProjection {
  CentralProjection({required this.databaseHelper, required this.source});
  final DatabaseHelper databaseHelper;
  final SessionSource source;
  Map<String, dynamic>? _manifest;
  int? _generation;

  Future<void> invalidateSnapshot() async {
    final session = source.session;
    if (!session.isSignedIn || !session.hasOrganization) {
      throw StateError('An active organization session is required');
    }
    final db = await databaseHelper.database;
    await db.delete(
      'central_sync_state',
      where: 'organization_id = ? AND uid = ?',
      whereArgs: [session.organizationId, session.uid],
    );
  }

  /// Access reductions clear canonical data immediately, even if the next
  /// authorized download fails. Durable drafts and operation receipts remain.
  Future<void> clearForAccessChange() async {
    final scope = SyncRunScope(source, databaseHelper);
    final db = await databaseHelper.database;
    await db.transaction((txn) async {
      scope.check();
      await _wipeCanonical(txn, scope);
      await txn.delete('central_bootstrap_staging');
      await txn.delete('central_bootstrap_state');
      scope.check();
    });
    SyncDataChanges.notify();
  }

  /// One-time migration flag: archives materialized from pre-fix placeholder
  /// events cannot be reconciled locally (their stored payload hash covers the
  /// placeholder bytes), so the caller invalidates the snapshot and re-downloads
  /// it from the server, which now serves real timestamps on every channel.
  Future<bool> hasCommitTimePlaceholder() async {
    final session = source.session;
    if (!session.isSignedIn || !session.hasOrganization) return false;
    final db = await databaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM central_approved_records '
      'WHERE instr(payload, ?) > 0',
      [centralCommitTimePlaceholder],
    );
    return (rows.single['n'] as num).toInt() > 0;
  }

  Future<void> applyEvent({
    required int sequence,
    required String operationId,
    required List<ApprovedRecord> records,
    SyncRunScope? scope,
  }) async {
    if (sequence < 1 || operationId.isEmpty) {
      throw ArgumentError('Invalid change event');
    }
    final run = scope ?? SyncRunScope(source, databaseHelper);
    final db = await databaseHelper.database;
    await _prepare(db, run);
    var applied = false;
    await db.transaction((txn) async {
      run.check();
      final state = await txn.query(
        'central_sync_state',
        where: 'organization_id = ? AND uid = ?',
        whereArgs: [run.session.organizationId, run.session.uid],
      );
      // `catching_up` accepts events too: the post-snapshot catch-up feed is
      // what proves the archive complete before `ready` is granted.
      final bootstrapState = state.length == 1
          ? state.single['bootstrap_state'] as String
          : '';
      if (state.length != 1 ||
          state.single['role'] != run.session.rolesKey ||
          (bootstrapState != 'ready' && bootstrapState != 'catching_up')) {
        throw StateError('The canonical cache has not completed bootstrap');
      }
      final previous = state.single['applied_sequence'] as int;
      if (sequence <= previous) return;
      if (sequence != previous + 1) {
        throw StateError('A change event is missing; checkpoint retained');
      }
      await _apply(txn, records, run);
      await txn.update(
        'central_sync_state',
        {
          'applied_sequence': sequence,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'organization_id = ? AND uid = ?',
        whereArgs: [run.session.organizationId, run.session.uid],
      );
      await txn.delete(
        'central_command_entities',
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
      run.check();
      applied = true;
    });
    if (applied) SyncDataChanges.notify();
  }

  /// All after-images at one readTime are applied together. Older pointer
  /// events are never materialized as if they contained a later version.
  Future<void> applyCycle({
    required int afterSequence,
    required int throughSequence,
    required List<ApprovedRecord> records,
    required Set<String> operationIds,
    required SyncRunScope scope,
  }) async {
    if (throughSequence < afterSequence) {
      throw const FormatException('Regressed boundary');
    }
    final db = await databaseHelper.database;
    await _prepare(db, scope);
    await db.transaction((txn) async {
      scope.check();
      final rows = await txn.query(
        'central_sync_state',
        where: 'organization_id = ? AND uid = ?',
        whereArgs: [scope.session.organizationId, scope.session.uid],
      );
      if (rows.length != 1 ||
          rows.single['role'] != scope.session.rolesKey ||
          rows.single['applied_sequence'] != afterSequence ||
          !const [
            'ready',
            'catching_up',
          ].contains(rows.single['bootstrap_state'])) {
        throw StateError('Canonical cursor changed during read');
      }
      await _apply(txn, records, scope);
      await txn.update(
        'central_sync_state',
        {
          'applied_sequence': throughSequence,
          'bootstrap_state': 'ready',
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        where: 'organization_id = ? AND uid = ?',
        whereArgs: [scope.session.organizationId, scope.session.uid],
      );
      await _releaseCoveredLocks(txn, operationIds);
      scope.check();
    });
    if (records.isNotEmpty) SyncDataChanges.notify();
  }

  /// Materializes the downloaded snapshot pages. It deliberately stores
  /// `catching_up`, not `ready`: authoring stays blocked until the driver has
  /// also applied every change event the server committed during the download
  /// and proven the feed drained (see [markReady]).
  Future<void> installSnapshot({
    required int throughSequence,
    required List<ApprovedRecord> records,
    Set<String> coveredOperationIds = const {},
    SyncRunScope? scope,
  }) async {
    if (throughSequence < 0) throw ArgumentError('Invalid snapshot watermark');
    final run = scope ?? SyncRunScope(source, databaseHelper);
    final db = await databaseHelper.database;
    await _prepare(db, run);
    await db.transaction((txn) async {
      run.check();
      await _assertReplaceable(txn, run);
      await _wipeCanonical(txn, run);
      await _apply(txn, records, run);
      await _installState(txn, run, throughSequence);
      await _releaseCoveredLocks(txn, coveredOperationIds);
      run.check();
    });
    SyncDataChanges.notify();
  }

  /// Disk-staged bootstrap (production acceptance 2): the download lives in
  /// `central_bootstrap_staging` — one small transaction per page, with the
  /// run scope re-checked at every page — instead of one unbounded in-memory
  /// list and one giant transaction. Records merge under version rules
  /// (higher version wins; two different payloads for the SAME approved
  /// version abort the bootstrap as a server inconsistency).
  Future<void> beginBootstrap({
    required int manifestVersion,
    required int h0,
    SyncRunScope? scope,
  }) async {
    final run = scope ?? SyncRunScope(source, databaseHelper);
    final db = await databaseHelper.database;
    await db.transaction((txn) async {
      run.check();
      await txn.delete(
        'central_bootstrap_staging',
        where: 'organization_id = ? AND uid = ?',
        whereArgs: [run.session.organizationId, run.session.uid],
      );
      await txn.insert('central_bootstrap_state', {
        'organization_id': run.session.organizationId,
        'uid': run.session.uid,
        'role': run.session.rolesKey,
        'manifest_version': manifestVersion,
        'h0': h0,
        'h1': 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      run.check();
    });
  }

  /// Marks the page download complete (`h1`, observed by a second
  /// `beginSnapshot` probe) so a crashed run resumes at the event-merge and
  /// install steps instead of re-downloading every page.
  Future<void> updateBootstrapWatermark({
    required int h1,
    SyncRunScope? scope,
  }) async {
    final run = scope ?? SyncRunScope(source, databaseHelper);
    final db = await databaseHelper.database;
    await db.transaction((txn) async {
      run.check();
      final changed = await txn.update(
        'central_bootstrap_state',
        {'h1': h1, 'updated_at': DateTime.now().toUtc().toIso8601String()},
        where:
            'organization_id = ? AND uid = ? AND role = ? AND h1 = 0 AND h0 <= ?',
        whereArgs: [
          run.session.organizationId,
          run.session.uid,
          run.session.rolesKey,
          h1,
        ],
      );
      if (changed != 1) {
        throw StateError('Bootstrap state row vanished or regressed');
      }
      run.check();
    });
  }

  /// Stages one batch of approved after-images (a snapshot page or the
  /// records of one change event) under the merge rules. Runs in its own
  /// small transaction so a crash loses at most the current page.
  Future<void> stageRecords(
    List<ApprovedRecord> records, {
    SyncRunScope? scope,
  }) async {
    if (records.isEmpty) return;
    final run = scope ?? SyncRunScope(source, databaseHelper);
    final db = await databaseHelper.database;
    await db.transaction((txn) async {
      run.check();
      for (final record in records) {
        final fingerprint = hashPayload(record.data);
        final existing = await txn.query(
          'central_bootstrap_staging',
          columns: const ['version', 'payload_hash'],
          where:
              'organization_id = ? AND uid = ? AND entity_type = ? AND entity_id = ?',
          whereArgs: [
            run.session.organizationId,
            run.session.uid,
            record.entityType,
            record.entityId,
          ],
          limit: 1,
        );
        final where =
            'organization_id = ? AND uid = ? AND entity_type = ? AND entity_id = ?';
        final whereArgs = [
          run.session.organizationId,
          run.session.uid,
          record.entityType,
          record.entityId,
        ];
        if (existing.isEmpty) {
          await txn.insert('central_bootstrap_staging', {
            'organization_id': run.session.organizationId,
            'uid': run.session.uid,
            'entity_type': record.entityType,
            'entity_id': record.entityId,
            'version': record.version,
            'payload': jsonEncode(record.data),
            'payload_hash': fingerprint,
          });
        } else if ((existing.single['version'] as num).toInt() >
            record.version) {
          continue;
        } else if ((existing.single['version'] as num).toInt() ==
            record.version) {
          if (existing.single['payload_hash'] != fingerprint) {
            throw StateError(
              'Bootstrap staging saw two different payloads for the same '
              'approved version (${record.entityType}/${record.entityId})',
            );
          }
        } else {
          await txn.update(
            'central_bootstrap_staging',
            {
              'version': record.version,
              'payload': jsonEncode(record.data),
              'payload_hash': fingerprint,
            },
            where: '$where AND version < ?',
            whereArgs: [...whereArgs, record.version],
          );
        }
      }
      run.check();
    });
  }

  /// Final bootstrap install: replaces the canonical cache with the staged
  /// after-images inside ONE transaction (a crash rolls the whole install
  /// back; the next cycle retries it from staging). Identities are allocated
  /// for every staged record first, then rows are materialized in batches —
  /// a parent living in a later batch resolves through the identity table,
  /// and deferred foreign keys verify the complete graph at commit. The
  /// state lands at `catching_up` with the bootstrap watermark (h1) as the
  /// applied cursor; staging and the resume row are removed at the end.
  Future<void> installFromStaging({
    required int throughSequence,
    Set<String> coveredOperationIds = const {},
    SyncRunScope? scope,
  }) async {
    if (throughSequence < 0) throw ArgumentError('Invalid snapshot watermark');
    final run = scope ?? SyncRunScope(source, databaseHelper);
    final db = await databaseHelper.database;
    await _prepare(db, run);
    await db.transaction((txn) async {
      run.check();
      await _assertReplaceable(txn, run);
      await _wipeCanonical(txn, run);
      await _enableDeferredConstraints(txn);
      const batch = 500;
      final state = _ApplyState(
        definitions: _manifest!['entities'] as Map,
        resolveUnapproved: true,
      );
      var lastRid = 0;
      while (true) {
        final (records, rid) = await _stagingBatch(
          txn,
          run,
          afterRowid: lastRid,
          limit: batch,
        );
        if (records.isEmpty) break;
        await _allocate(txn, records, state, run);
        lastRid = rid;
      }
      lastRid = 0;
      while (true) {
        final (records, rid) = await _stagingBatch(
          txn,
          run,
          afterRowid: lastRid,
          limit: batch,
        );
        if (records.isEmpty) break;
        await _materialize(txn, records, state, run);
        lastRid = rid;
      }
      await _installState(txn, run, throughSequence);
      await _releaseCoveredLocks(txn, coveredOperationIds);
      await txn.delete(
        'central_bootstrap_staging',
        where: 'organization_id = ? AND uid = ?',
        whereArgs: [run.session.organizationId, run.session.uid],
      );
      await txn.delete(
        'central_bootstrap_state',
        where: 'organization_id = ? AND uid = ?',
        whereArgs: [run.session.organizationId, run.session.uid],
      );
      run.check();
    });
    SyncDataChanges.notify();
  }

  Future<(List<ApprovedRecord>, int)> _stagingBatch(
    DatabaseExecutor txn,
    SyncRunScope run, {
    required int afterRowid,
    required int limit,
  }) async {
    final rows = await txn.rawQuery(
      'SELECT rowid AS rid, entity_type, entity_id, version, payload '
      'FROM central_bootstrap_staging '
      'WHERE organization_id = ? AND uid = ? AND rowid > ? '
      'ORDER BY rowid LIMIT ?',
      [run.session.organizationId, run.session.uid, afterRowid, limit],
    );
    final records = <ApprovedRecord>[];
    for (final row in rows) {
      final data = jsonDecode('${row['payload']}');
      if (data is! Map) {
        throw StateError('Corrupt staged payload');
      }
      records.add(
        ApprovedRecord(
          entityType: '${row['entity_type']}',
          entityId: '${row['entity_id']}',
          version: (row['version'] as num).toInt(),
          data: Map<String, dynamic>.from(data),
        ),
      );
    }
    return (
      records,
      rows.isEmpty ? afterRowid : (rows.last['rid'] as num).toInt(),
    );
  }

  Future<void> _assertReplaceable(
    DatabaseExecutor txn,
    SyncRunScope run,
  ) async {
    final state = await txn.query(
      'central_sync_state',
      where: 'organization_id = ? AND uid = ?',
      whereArgs: [run.session.organizationId, run.session.uid],
    );
    if (state.length == 1 &&
        state.single['bootstrap_state'] == 'ready' &&
        state.single['role'] == run.session.rolesKey) {
      throw StateError(
        'A ready canonical cache cannot be replaced by an older snapshot',
      );
    }
  }

  Future<void> _wipeCanonical(DatabaseExecutor txn, SyncRunScope run) async {
    // Initial bootstrap replaces the legacy local cache. A role change also
    // removes records that are no longer visible to this account. Because
    // this runs only after every server page has been fetched, a failed
    // download never destroys the existing local state.
    await txn.execute('PRAGMA defer_foreign_keys = ON');
    final archivedAt = DateTime.now().toUtc().toIso8601String();
    for (final table in const ['sync_queue', 'sync_conflicts']) {
      final legacyRows = await txn.query(table);
      for (final row in legacyRows) {
        final rowId = row['id'] ?? row['conflict_id'] ?? archivedAt;
        await txn.insert('legacy_sync_archive', {
          'source_table': table,
          'source_id': '$rowId',
          'row_json': jsonEncode(row),
          'archived_at': archivedAt,
        });
      }
      await txn.delete(table);
    }
    for (final entity in syncEntities.reversed) {
      if (entity.type == 'qcAudit') {
        await txn.delete('central_qc_audits');
        continue;
      }
      await txn.delete(entity.localTable);
    }
    await txn.delete('audit_logs');
    await txn.delete('central_entity_identities');
    await txn.delete('central_approved_records');
    await txn.delete(
      'central_sync_state',
      where: 'organization_id = ? AND uid = ?',
      whereArgs: [run.session.organizationId, run.session.uid],
    );
  }

  Future<void> _installState(
    DatabaseExecutor txn,
    SyncRunScope run,
    int throughSequence,
  ) async {
    await txn.insert('central_sync_state', {
      'organization_id': run.session.organizationId,
      'uid': run.session.uid,
      'role': run.session.rolesKey,
      'applied_sequence': throughSequence,
      'bootstrap_state': 'catching_up',
      'protocol_schema': commandSchemaVersion,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _releaseCoveredLocks(
    DatabaseExecutor txn,
    Set<String> coveredOperationIds,
  ) async {
    for (final operationId in coveredOperationIds) {
      await txn.delete(
        'central_command_entities',
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
    }
  }

  /// Grants `ready` - and with it the permission to author - only after the
  /// driver has applied the complete change-event feed up to a server head it
  /// observed *after* the snapshot watermark. A run that aborts mid-catch-up
  /// stays in `catching_up`; the next run resumes the feed without re-downloading
  /// the snapshot. Already-`ready` archives are untouched.
  Future<void> markReady({SyncRunScope? scope}) async {
    final run = scope ?? SyncRunScope(source, databaseHelper);
    final db = await databaseHelper.database;
    run.check();
    await db.update(
      'central_sync_state',
      {'bootstrap_state': 'ready'},
      where:
          'organization_id = ? AND uid = ? AND role = ? AND '
          'bootstrap_state = ?',
      whereArgs: [
        run.session.organizationId,
        run.session.uid,
        run.session.rolesKey,
        'catching_up',
      ],
    );
  }

  Future<void> _prepare(Database db, SyncRunScope scope) async {
    if (!scope.session.isSignedIn ||
        !scope.session.hasOrganization ||
        !scope.session.isActiveMember) {
      throw StateError('An active organization session is required');
    }
    if (_generation != scope.generation) {
      _manifest = await buildDomainManifest(db);
      _generation = scope.generation;
    }
    scope.check();
  }

  /// Applies a small set of trusted after-images (one change event, or the
  /// full snapshot list path) — allocation then materialization with a
  /// fresh shared state.
  Future<void> _apply(
    DatabaseExecutor txn,
    List<ApprovedRecord> records,
    SyncRunScope scope,
  ) async {
    await _enableDeferredConstraints(txn);
    final state = _ApplyState(definitions: _manifest!['entities'] as Map);
    await _allocate(txn, records, state, scope);
    await _materialize(txn, records, state, scope);
  }

  Future<void> _enableDeferredConstraints(DatabaseExecutor txn) async {
    // Domain aggregates can contain legitimate cycles (a finding and its
    // CAPA). All identities are allocated first; SQLite verifies the
    // complete graph at commit rather than accepting dangling pointers
    // between pages.
    await txn.execute('PRAGMA defer_foreign_keys = ON');
    final deferred = await txn.rawQuery('PRAGMA defer_foreign_keys');
    if (deferred.single.values.single != 1) {
      throw StateError('Deferred constraints are unavailable');
    }
  }

  // Leave ample room below SQLite's legacy 999-variable limit. Grouping by
  // type also uses the existing (entity_type, entity_id) primary-key index.
  Future<Map<String, Map<String, Object?>>> _readRecordKeys(
    DatabaseExecutor txn,
    String table,
    Iterable<(String, String)> keys,
  ) async {
    final grouped = <String, Set<String>>{};
    for (final (type, id) in keys) {
      (grouped[type] ??= {}).add(id);
    }
    final result = <String, Map<String, Object?>>{};
    for (final entry in grouped.entries) {
      final ids = entry.value.toList();
      for (var offset = 0; offset < ids.length; offset += 400) {
        final slice = ids.skip(offset).take(400).toList();
        final rows = await txn.query(
          table,
          columns: table == 'central_approved_records'
              ? ['entity_type', 'entity_id', 'version', 'payload_hash']
              : ['entity_type', 'entity_id', 'local_ref', 'approved_version'],
          where:
              'entity_type = ? AND entity_id IN (${List.filled(slice.length, '?').join(',')})',
          whereArgs: [entry.key, ...slice],
        );
        for (final row in rows) {
          result['${row['entity_type']}/${row['entity_id']}'] = row;
        }
      }
    }
    return result;
  }

  Future<Map<String, List<Map<String, Object?>>>> _readLegacyKeys(
    DatabaseExecutor txn,
    String table,
    String column,
    Iterable<Object?> values,
  ) async {
    final keys = values.whereType<String>().toSet().toList();
    final result = <String, List<Map<String, Object?>>>{};
    for (var offset = 0; offset < keys.length; offset += 400) {
      final slice = keys.skip(offset).take(400).toList();
      final rows = await txn.query(
        table,
        columns: ['id', column],
        where: '$column IN (${List.filled(slice.length, '?').join(',')})',
        whereArgs: slice,
      );
      for (final row in rows) {
        (result[row[column] as String] ??= []).add(row);
      }
    }
    return result;
  }

  /// Phase 1 — validation and identity allocation. Accepts any number of
  /// batches sharing one [state]; records already approved at an equal-or-
  /// newer version are remembered in `skipped` so phase 2 skips them too.
  Future<void> _allocate(
    DatabaseExecutor txn,
    List<ApprovedRecord> records,
    _ApplyState state,
    SyncRunScope scope,
  ) async {
    final storedRecords = await _readRecordKeys(
      txn,
      'central_approved_records',
      records.map((r) => (r.entityType, r.entityId)),
    );
    final identities = await _readRecordKeys(
      txn,
      'central_entity_identities',
      records.map((r) => (r.entityType, r.entityId)),
    );
    final legacyUsers = await _readLegacyKeys(
      txn,
      'users',
      'uid',
      records.where((r) => r.entityType == 'member').map((r) => r.data['uid']),
    );
    final legacyUnits = await _readLegacyKeys(
      txn,
      'lab_units',
      'symbol',
      records
          .where((r) => r.entityType == 'labUnit')
          .map((r) => r.data['symbol']),
    );
    // Allocation writes reservations only. Domain maxima remain fixed during
    // this phase; the local high-water mark advances after each reservation.
    final maxima = <String, int>{};
    for (final record in records) {
      final entity = SyncEntity.byType(record.entityType);
      final key = '${record.entityType}/${record.entityId}';
      if (entity == null ||
          record.entityId.isEmpty ||
          record.version < 1 ||
          record.data['version'] != record.version ||
          record.data['organizationId'] != scope.session.organizationId ||
          _containsCommitTimePlaceholder(record.data) ||
          !state.seen.add(key)) {
        throw StateError('Invalid approved record frame');
      }
      final readPermission = Permission.byId(
        centralReadPermission(entity.type),
      );
      if (readPermission == null || !scope.session.can(readPermission)) {
        throw StateError('This session may not materialize the record');
      }
      final fingerprint = hashPayload(record.data);
      final stored = storedRecords[key];
      if (stored != null && (stored['version'] as int) >= record.version) {
        if (stored['version'] == record.version &&
            stored['payload_hash'] != fingerprint) {
          throw StateError('An approved version has inconsistent contents');
        }
        state.skipped.add(key);
        continue;
      }
      state.fingerprints[key] = fingerprint;
      final known = identities[key];
      int local;
      if (known != null) {
        local = known['local_ref'] as int;
      } else {
        final byUser =
            record.entityType == 'member' && record.data['uid'] is String
            ? legacyUsers[record.data['uid']] ?? const <Map<String, Object?>>[]
            : const <Map<String, Object?>>[];
        final byUnit =
            record.entityType == 'labUnit' && record.data['symbol'] is String
            ? legacyUnits[record.data['symbol']] ??
                  const <Map<String, Object?>>[]
            : const <Map<String, Object?>>[];
        if (byUser.length == 1 || byUnit.length == 1) {
          local =
              (byUser.isNotEmpty ? byUser.single : byUnit.single)['id'] as int;
        } else {
          var maximum = maxima[entity.type];
          if (maximum == null) {
            final maxRow = await txn.rawQuery(
              'SELECT COALESCE(MAX(${entity.pkColumn}), 0) AS n FROM ${entity.localTable}',
            );
            final maxReservation = await txn.rawQuery(
              'SELECT COALESCE(MAX(local_ref), 0) AS n FROM central_entity_identities WHERE entity_type = ?',
              [entity.type],
            );
            final a = maxRow.single['n'] as int,
                b = maxReservation.single['n'] as int;
            maximum = a > b ? a : b;
          }
          local = maximum + 1;
          maxima[entity.type] = local;
        }
        await txn.insert('central_entity_identities', {
          'entity_type': entity.type,
          'entity_id': record.entityId,
          'local_ref': local,
          'approved_version': 0,
        });
      }
      state.targets[key] = local;
      if (record.entityType == 'member' && record.data['uid'] is String) {
        state.users[record.data['uid'] as String] = local;
      }
      if (record.entityType == 'qcAudit') {
        final changed = await txn.rawUpdate(
          'UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = ?',
          [local, 'qc_audits'],
        );
        if (changed == 0) {
          await txn.insert('sqlite_sequence', {
            'name': 'qc_audits',
            'seq': local,
          });
        }
      }
    }
    scope.check();
  }

  /// Phase 2 — materialization of the rows that phase 1 accepted. A parent
  /// living outside the current batch resolves through the identity table;
  /// during a staged install every staged record has an identity allocated
  /// in phase 1, so the `approved_version > 0` filter is dropped
  /// ([_ApplyState.resolveUnapproved]).
  Future<void> _materialize(
    DatabaseExecutor txn,
    List<ApprovedRecord> records,
    _ApplyState state,
    SyncRunScope scope,
  ) async {
    final parentKeys = <(String, String)>[];
    for (final record in records) {
      final key = '${record.entityType}/${record.entityId}';
      if (state.skipped.contains(key)) continue;
      final refs = record.data['parentRefs'];
      if (refs is! Map) continue;
      for (final ref in refs.values) {
        if (ref is Map &&
            ref['entityType'] is String &&
            ref['entityId'] is String) {
          final type = ref['entityType'] as String;
          final id = ref['entityId'] as String;
          if (!state.targets.containsKey('$type/$id')) {
            parentKeys.add((type, id));
          }
        }
      }
    }
    final parentIdentities = await _readRecordKeys(
      txn,
      'central_entity_identities',
      parentKeys,
    );
    Future<int> actor(String uid, String? name) async {
      if (uid.isEmpty) throw StateError('Approved actor identity is missing');
      if (state.actorIds == null) {
        final rows = await txn.query('users', columns: ['id', 'uid']);
        state.actorIds = {};
        for (final row in rows) {
          final id = row['id'] as int;
          if (id > state.actorMaximum) state.actorMaximum = id;
          if (row['uid'] is String) state.actorIds![row['uid'] as String] = id;
        }
        final reservedMax =
            (await txn.rawQuery(
                  "SELECT COALESCE(MAX(local_ref), 0) AS n FROM central_entity_identities WHERE entity_type = 'member'",
                )).single['n']
                as int;
        if (reservedMax > state.actorMaximum) state.actorMaximum = reservedMax;
      }
      final found = state.actorIds![uid];
      if (found != null) return found;
      final reserved = state.users[uid];
      final id = await txn.insert('users', {
        'id': reserved ?? state.actorMaximum + 1,
        'uid': uid,
        'email': '',
        'full_name': name ?? uid,
        'display_name': name ?? uid,
        'role': 'viewer',
        'status': 'active',
        'updated_at': '',
      });
      state.users[uid] = id;
      state.actorIds![uid] = id;
      if (id > state.actorMaximum) state.actorMaximum = id;
      return id;
    }

    for (final record in records) {
      final key = '${record.entityType}/${record.entityId}';
      if (state.skipped.contains(key)) continue;
      scope.check();
      final entity = SyncEntity.byType(record.entityType)!;
      final definition = record.entityType == 'auditLog'
          ? const {'parents': <Object>[]}
          : state.definitions[record.entityType] as Map;
      final local = state.targets[key]!;
      final row = remoteToLocalRow(
        entity,
        record.data,
        organizationId: scope.session.organizationId,
      );
      if (entity.type == 'auditLog' &&
          record.data['action'] == 'DOMAIN_COMMITTED' &&
          record.data['records'] is List) {
        row['details_json'] = jsonEncode({
          'operationId': record.data['operationId'],
          'records': record.data['records'],
        });
      }
      row[entity.pkColumn] = local;
      if (entity.pkColumn != 'id') row.remove('id');
      if (entity.type == 'sample' && record.data['secureEntryId'] != null) {
        row['report_html'] = '';
      }
      row['remote_id'] = record.data['remoteId'] ?? record.entityId;
      row['created_by'] = record.data['createdBy'];
      row['sync_state'] = 'synced';
      row['remote_version'] = record.version;
      row['remote_synced_at'] = DateTime.now().toUtc().toIso8601String();
      if (entity.type == 'qcAudit') {
        await CentralQcAuditCache.put(
          txn,
          record.entityId,
          local,
          row,
          record.data,
        );
        await txn.insert('central_approved_records', {
          'entity_type': entity.type,
          'entity_id': record.entityId,
          'version': record.version,
          'payload': jsonEncode(record.data),
          'payload_hash': state.fingerprints[key],
        });
        await txn.update(
          'central_entity_identities',
          {'approved_version': record.version},
          where: 'entity_type = ? AND entity_id = ?',
          whereArgs: [entity.type, record.entityId],
        );
        continue;
      }
      if (record.entityType == 'qualityCheck' &&
          record.data['businessVersion'] is num) {
        row['version'] = record.data['businessVersion'];
      }
      final refs = (record.data['parentRefs'] as Map?) ?? const {};
      for (final raw in definition['parents'] as List) {
        final parent = raw as Map;
        final column = parent['localField'] as String;
        if (record.entityType == 'sample' &&
            column == 'material_id' &&
            record.data['inspectionKind'] == 'product') {
          row[column] = await databaseHelper.ensureProductSentinelMaterialId(
            txn,
          );
          continue;
        }
        final ref = refs[parent['relation']] as Map?;
        if (ref == null) {
          if (parent['required'] == true) {
            throw StateError(
              'Approved record is missing a required global reference',
            );
          }
          row[column] = null;
          // Optional global references use an empty local cache stamp. Older
          // approved payloads may contain explicit null despite SQLite's
          // NOT NULL DEFAULT '' column, so do not copy that null on insert.
          if (column.endsWith('_id')) {
            row['${column.substring(0, column.length - 3)}_remote_id'] = '';
          }
          continue;
        }
        if (ref['entityType'] != parent['type'] || ref['entityId'] is! String) {
          throw StateError('Approved parent type mismatch');
        }
        final refKey = '${ref['entityType']}/${ref['entityId']}';
        var target = state.targets[refKey];
        if (target == null) {
          final approved = parentIdentities[refKey];
          if (approved != null &&
              (state.resolveUnapproved ||
                  (approved['approved_version'] as int) > 0)) {
            target = approved['local_ref'] as int;
          }
        }
        if (target == null) {
          throw StateError('Approved parent has not been materialized');
        }
        row[column] = target;
        final stamp = column.endsWith('_id')
            ? '${column.substring(0, column.length - 3)}_remote_id'
            : null;
        if (stamp != null) row[stamp] = ref['entityId'];
      }
      final info = state.tableInfo[entity.type] ??= await txn.rawQuery(
        'PRAGMA table_info(${entity.localTable})',
      );
      final columns = {for (final column in info) column['name'] as String};
      for (final column in info) {
        final name = column['name'] as String;
        final type = (column['type'] as String).toUpperCase();
        if (!type.contains('INT') ||
            !(name.endsWith('_by') ||
                name.endsWith('_by_id') ||
                name == 'user_id')) {
          continue;
        }
        final value = row[name];
        if (value == null) continue;
        if (value is! String || value.isEmpty) {
          throw StateError('Approved actor must use a global identity');
        }
        row[name] = await actor(value, record.data['createdByName'] as String?);
      }
      final filtered = <String, Object?>{};
      for (final entry in row.entries) {
        if (!columns.contains(entry.key)) continue;
        if (entry.value is Map || entry.value is List) {
          throw StateError('Unserialized SQLite field ${entry.key}');
        }
        filtered[entry.key] = entry.value;
      }
      if (entity.type == 'organizationSetting') {
        await _removeUnapprovedSettingShadow(txn, filtered['key'], local);
      }
      final existing = await txn.query(
        entity.localTable,
        columns: [entity.pkColumn],
        where: '${entity.pkColumn} = ?',
        whereArgs: [local],
      );
      if (existing.isEmpty) {
        await txn.insert(entity.localTable, filtered);
      } else {
        await txn.update(
          entity.localTable,
          filtered,
          where: '${entity.pkColumn} = ?',
          whereArgs: [local],
        );
      }
      if (entity.type == 'member' &&
          state.actorIds != null &&
          filtered.containsKey('uid')) {
        // A materialized member may replace the uid at an existing local id.
        // Keep actual rows separate from phase-1 reservations (state.users).
        state.actorIds!.removeWhere((_, id) => id == local);
        final uid = filtered['uid'];
        if (uid is String) state.actorIds![uid] = local;
        if (local > state.actorMaximum) state.actorMaximum = local;
      }
      if (entity.type == 'consumption' &&
          (record.data['protocol'] as Map?)?['ledgerMode'] ==
              'consumption_v1' &&
          (record.data['appliedQty'] as num? ?? 0) > 0) {
        // A read-model view of the approved immutable consumption, never a
        // second shared write. Stable identity makes replay/bootstrap idempotent.
        final ledgerId = 'derived_consumption_v1_${record.entityId}';
        final ledger = <String, Object?>{
          'remote_id': ledgerId,
          'inventory_id': filtered['inventory_id'],
          'inventory_remote_id': refs['inventoryId']['entityId'],
          'quantity_delta': -(record.data['qtyUsed'] as num),
          'transaction_type': record.data['eventType'],
          'reference_type': 'sample_test',
          'reference_id': filtered['sample_test_id'],
          'reference_remote_id': refs['sampleTestId']['entityId'],
          'reason': record.data['eventType'] == 'REVERSAL'
              ? 'Lab test reversal'
              : 'Lab test',
          'created_by': await actor(record.data['createdBy'] as String, null),
          'created_at': filtered['created_at'],
          'updated_at': filtered['updated_at'],
          'device_id': record.data['deviceId'],
          'version': 1,
          'remote_version': 1,
          'sync_state': 'synced',
        };
        final existingLedger = await txn.query(
          'inventory_transactions',
          columns: ['id'],
          where: 'remote_id = ?',
          whereArgs: [ledgerId],
        );
        if (existingLedger.isEmpty) {
          final maximum =
              (await txn.rawQuery('''SELECT MAX(n) AS n FROM (
            SELECT COALESCE(MAX(id),0) AS n FROM inventory_transactions
            UNION ALL SELECT COALESCE(MAX(local_ref),0) AS n FROM central_entity_identities
              WHERE entity_type = 'inventoryTransaction')''')).single['n']
                  as num;
          ledger['id'] = maximum.toInt() + 1;
          await txn.insert('inventory_transactions', ledger);
        } else {
          await txn.update(
            'inventory_transactions',
            ledger,
            where: 'id = ?',
            whereArgs: [existingLedger.single['id']],
          );
        }
      }
      await txn.insert('central_approved_records', {
        'entity_type': entity.type,
        'entity_id': record.entityId,
        'version': record.version,
        'payload': jsonEncode(record.data),
        'payload_hash': state.fingerprints[key],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update(
        'central_entity_identities',
        {'approved_version': record.version},
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [entity.type, record.entityId],
      );
    }
    scope.check();
  }

  /// Schema upgrades mirror local settings before their server identities are
  /// known. Such a shadow can hold the incoming key at another local id.
  /// Reconcile only this default/legacy cache row, inside the same transaction
  /// as the approved after-image and cursor. Never merge approved identities.
  Future<void> _removeUnapprovedSettingShadow(
    DatabaseExecutor txn,
    Object? key,
    int keepLocalId,
  ) async {
    if (key is! String || key.isEmpty) {
      throw StateError('Approved setting has no key');
    }
    final siblings = await txn.query(
      'organization_settings',
      where: 'key = ? AND id != ?',
      whereArgs: [key, keepLocalId],
    );
    for (final sibling in siblings) {
      final identity = await txn.rawQuery(
        'SELECT 1 FROM central_entity_identities '
        'WHERE entity_type = ? AND local_ref = ? AND approved_version > 0 '
        'UNION ALL SELECT 1 FROM central_approved_records '
        'WHERE entity_type = ? AND entity_id = ? LIMIT 1',
        [
          'organizationSetting',
          sibling['id'],
          'organizationSetting',
          sibling['remote_id'],
        ],
      );
      if (identity.isNotEmpty) {
        throw StateError(
          'Approved settings identities collide; checkpoint retained',
        );
      }
      await txn.insert('legacy_sync_archive', {
        'source_table': 'organization_settings',
        'source_id': '${sibling['id']}',
        'row_json': jsonEncode(sibling),
        'archived_at': DateTime.now().toUtc().toIso8601String(),
      });
      await txn.delete(
        'organization_settings',
        where: 'id = ?',
        whereArgs: [sibling['id']],
      );
    }
  }
}

/// Shared side tables for the two `_apply` phases: ids and hashes per record
/// stay in memory while the record payloads themselves stream from disk in
/// bounded batches during a staged install.
class _ApplyState {
  _ApplyState({required this.definitions, this.resolveUnapproved = false});

  final Map definitions;

  /// During a staged install every staged record received an identity in
  /// phase 1 (single transaction), so a parent may resolve through an
  /// identity whose row is not yet marked approved.
  final bool resolveUnapproved;

  final Map<String, int> targets = {};
  final Map<String, int> users = {};
  Map<String, int>? actorIds;
  int actorMaximum = 0;
  final Map<String, List<Map<String, Object?>>> tableInfo = {};
  final Map<String, String> fingerprints = {};
  final Set<String> seen = {};
  final Set<String> skipped = {};
}
