/// The new send queue (plan `SYNC_ARCHITECTURE_PLAN_2026-10-25` §5
/// `command_outbox`) — protocols only: requests, their fixed `operationId`,
/// the expected version, dependencies and transport attempts.
///
/// Invariants baked in here:
///  * **draft + outbox in one SQLite transaction** — [enqueueDraftSubmit] is
///    `DatabaseExecutor`-shaped so the caller binds them atomically;
///  * one operation = one effect: `operation_id` is UNIQUE; a retry resends
///    the same id and hash, a re-edit BEFORE first send replaces the row under
///    a NEW operationId and purges the never-sent one, a re-edit after send is
///    refused by [CommandService];
///  * permanent business rejections (permission / conflict / parent rules)
///    park here with the stored reason — the worker never blind-retries.
library;

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../database/database_helper.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'command_contract.dart';
import 'drafts_store.dart';

/// Outbox row lifecycle.
enum OutboxState {
  /// Staged, waiting for the worker.
  pending('pending'),

  /// Claimed, request in flight.
  inFlight('in_flight'),

  /// Receipt approved; row kept with the receipt (§6: "إيصالات العمليات لا
  /// تُحذف بينما قد توجد طلبات قابلة لإعادة الإرسال تعتمد عليها") until the
  /// retention sweep.
  approved('approved'),

  /// Terminal stop state with a saved permanent failure.
  rejected('rejected'),

  /// Server says content needs a human decision (e.g. VERSION_CONFLICT).
  needsReview('needs_review'),

  /// Cannot proceed until sign-in freshens.
  authRequired('auth_required'),

  /// Archived by an explicit user decision (cleanup, or "ignore my request"
  /// after a rejection / conflict review). The row, its reason and the
  /// receipt stay; the entity locks are released. Never counted as a problem.
  archived('archived');

  const OutboxState(this.value);
  final String value;

  static OutboxState from(String value) => values.firstWhere(
    (state) => state.value == value,
    orElse: () => OutboxState.pending,
  );

  bool get isSendable => this == OutboxState.pending;
}

/// One staged command.
class CommandOutboxEntry {
  const CommandOutboxEntry({
    required this.id,
    required this.draftId,
    required this.operationId,
    required this.organizationId,
    required this.uid,
    required this.deviceId,
    required this.commandType,
    this.schemaVersion = commandSchemaVersion,
    required this.entityId,
    required this.expectedVersion,
    required this.payload,
    required this.payloadHash,
    required this.dependencies,
    required this.state,
    required this.attempts,
    required this.createdAt,
    required this.updatedAt,
    this.nextAttemptAt,
    this.lastErrorCode,
    this.lastError,
    this.result,
  });

  static const Uuid _uuid = Uuid();
  final int schemaVersion;

  final int id;
  final String draftId;
  final String operationId;

  final String organizationId;
  final String uid;
  final String deviceId;

  final String commandType;
  final String entityId;
  final int expectedVersion;

  final Map<String, dynamic> payload;
  final String payloadHash;
  final Map<String, String> dependencies;

  final OutboxState state;
  final int attempts;

  final String? nextAttemptAt;
  final String? lastErrorCode;
  final String? lastError;

  /// Last non-transport result received for this operation; survives replays
  /// so crash-after-commit recovery shows the truth.
  final CommandResult? result;

  final String createdAt;
  final String updatedAt;

  /// The exact wire request this entry always produces.
  CommandEnvelope envelope() => CommandEnvelope(
    operationId: operationId,
    organizationId: organizationId,
    schemaVersion: schemaVersion,
    commandType: commandType,
    entityId: entityId,
    expectedVersion: expectedVersion,
    payload: payload,
    payloadHash: payloadHash,
    deviceId: deviceId,
    dependencies: dependencies,
  );

  Map<String, Object?> toRow() => {
    'draft_id': draftId,
    'operation_id': operationId,
    'organization_id': organizationId,
    'uid': uid,
    'device_id': deviceId,
    'command_type': commandType,
    'entity_id': entityId,
    'expected_version': expectedVersion,
    'schema_version': schemaVersion,
    'payload': jsonEncode(payload),
    'payload_hash': payloadHash,
    'dependencies': jsonEncode(dependencies),
    'state': state.value,
    'attempts': attempts,
    'next_attempt_at': nextAttemptAt,
    'last_error_code': lastErrorCode,
    'last_error': lastError,
    'result_json': result == null ? null : jsonEncode(result!.toJson()),
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  static CommandOutboxEntry fromRow(Map<String, Object?> row) {
    final resultJson = row['result_json'] as String?;
    return CommandOutboxEntry(
      id: (row['id'] as num).toInt(),
      draftId: '${row['draft_id']}',
      operationId: '${row['operation_id']}',
      organizationId: '${row['organization_id']}',
      uid: '${row['uid']}',
      deviceId: '${row['device_id']}',
      commandType: '${row['command_type']}',
      schemaVersion: (row['schema_version'] as num?)?.toInt() ?? 0,
      entityId: '${row['entity_id']}',
      expectedVersion: (row['expected_version'] as num?)?.toInt() ?? 0,
      payload:
          jsonDecode('${row['payload'] ?? '{}'}') as Map<String, dynamic>? ??
          <String, dynamic>{},
      payloadHash: '${row['payload_hash'] ?? ''}',
      dependencies:
          (jsonDecode('${row['dependencies'] ?? '{}'}') as Map?)
              ?.cast<String, String>() ??
          <String, String>{},
      state: OutboxState.from('${row['state']}'),
      attempts: (row['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAt: row['next_attempt_at'] as String?,
      lastErrorCode: row['last_error_code'] as String?,
      lastError: row['last_error'] as String?,
      result: resultJson == null
          ? null
          : CommandResult.fromJson(
              jsonDecode(resultJson) as Map<String, dynamic>,
            ),
      createdAt: '${row['created_at']}',
      updatedAt: '${row['updated_at']}',
    );
  }

  CommandOutboxEntry copyWith({
    OutboxState? state,
    int? attempts,
    String? nextAttemptAt,
    String? lastErrorCode,
    String? lastError,
    CommandResult? result,
  }) => CommandOutboxEntry(
    id: id,
    draftId: draftId,
    operationId: operationId,
    organizationId: organizationId,
    uid: uid,
    deviceId: deviceId,
    commandType: commandType,
    schemaVersion: schemaVersion,
    entityId: entityId,
    expectedVersion: expectedVersion,
    payload: payload,
    payloadHash: payloadHash,
    dependencies: dependencies,
    state: state ?? this.state,
    attempts: attempts ?? this.attempts,
    nextAttemptAt: nextAttemptAt,
    lastErrorCode: lastErrorCode,
    lastError: lastError,
    result: result ?? this.result,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// Counts the UI badge reads in one round trip.
class CommandOutboxCounts {
  const CommandOutboxCounts({
    required this.pending,
    required this.inFlight,
    required this.approved,
    required this.rejected,
    required this.needsReview,
    required this.requiresAuth,
    this.awaitingProjection = 0,
  });

  final int pending;
  final int inFlight;
  final int approved;
  final int rejected;
  final int needsReview;
  final int requiresAuth;
  final int awaitingProjection;

  /// Things the user must look at (§5 stop states).
  bool get hasProblems => rejected > 0 || needsReview > 0 || requiresAuth > 0;
}

class CommandOutbox {
  CommandOutbox(this.dbHelper) {
    dbHelper.onDatabaseClosed(() => _resolved = null);
  }

  final DatabaseHelper dbHelper;

  Database? _resolved;

  Future<Database> get _db async => _resolved ??= await dbHelper.database;

  Future<T> _withDb<T>(String label, Future<T> Function(Database db) action) {
    return DbTrace.run(label, () async {
      try {
        return await action(await _db);
      } on DatabaseException catch (e) {
        if (!e.isDatabaseClosedError()) rethrow;
        _resolved = null;
        return await action(await _db);
      }
    });
  }

  /// Bind a fresh operationId to [draftId]; returns it.
  ///
  /// Must run inside the SAME transaction that writes [drafts] and any local
  /// noise (§5): [txn] is provided by [CommandService.submitDraft].
  ///
  /// Re-submission rule: a draft edited again before its request was ever sent
  /// replaces the staging row under a NEW operationId — the old one was never
  /// on the wire, so cancelling it cannot lose an effect. A draft whose row is
  /// `in_flight`/beyond is refused by the caller.
  Future<CommandOutboxEntry> enqueueDraftSubmit(
    DatabaseExecutor txn, {
    required CommandDraft draft,
    required String commandType,
    required String entityId,
    required int expectedVersion,
    required Map<String, dynamic> payload,
    required Map<String, String> dependencies,
  }) async {
    final existing = await txn.query(
      'command_outbox',
      where: 'draft_id = ?',
      whereArgs: [draft.id],
    );
    if (existing.any(
      (row) =>
          row['state'] != 'pending' || (row['attempts'] as num).toInt() != 0,
    )) {
      throw StateError(
        'A submitted draft cannot become a different operation; reconcile its receipt first.',
      );
    }
    final scope = scopeProvider?.call();
    if (scopeProvider != null &&
        (scope == null || !scope.owns(draft.organizationId, draft.uid))) {
      throw StateError('Draft owner is not the active session');
    }
    final now = nowIso();
    final entry = CommandOutboxEntry(
      id: 0,
      draftId: draft.id,
      operationId: CommandOutboxEntry._uuid.v4(),
      organizationId: draft.organizationId,
      uid: draft.uid,
      deviceId: deviceProvider?.call() ?? '',
      commandType: commandType,
      entityId: entityId,
      expectedVersion: expectedVersion,
      payload: payload,
      payloadHash: hashPayload(payload),
      dependencies: dependencies,
      state: OutboxState.pending,
      attempts: 0,
      createdAt: now,
      updatedAt: now,
    );
    // A never-sent staging row for the same draft (re-submit after editing
    // the content) is replaced under a NEW operationId: the old request was
    // never on the wire, so discarding it cannot lose an effect.
    final stale = await txn.query(
      'command_outbox',
      where: "draft_id = ? AND state = 'pending' AND attempts = 0",
      whereArgs: [draft.id],
      limit: 1,
    );
    if (stale.isNotEmpty) {
      await txn.delete(
        'command_outbox',
        where: 'id = ?',
        whereArgs: [(stale.first['id'] as num).toInt()],
      );
    }
    await txn.insert('command_outbox', entry.toRow());
    await DraftsStore.transition(txn, draft.id, state: DraftState.waitingSend);
    return entry;
  }

  /// Injection point for the current device id (avoids a dependency cycle
  /// with the session store).
  String Function()? deviceProvider;
  CommandScope? Function()? scopeProvider;

  String get leaseKey {
    final scope = scopeProvider?.call();
    return scope == null
        ? 'unscoped-test-queue'
        : '${scope.organizationId}/${scope.uid}';
  }

  Future<bool> acquireLease(String key, String owner) => _withDb(
    'outbox.lease',
    (db) => db.transaction((txn) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await txn.query(
        'command_worker_leases',
        where: 'lease_key = ?',
        whereArgs: [key],
      );
      if (rows.isNotEmpty &&
          rows.single['owner'] != owner &&
          (rows.single['expires_at'] as int) > now &&
          (rows.single['expires_at'] as int) <= now + 180000) {
        return false;
      }
      await txn.insert('command_worker_leases', {
        'lease_key': key,
        'owner': owner,
        'expires_at': now + 120000,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    }),
  );
  Future<bool> renewLease(String key, String owner) => _withDb(
    'outbox.renewLease',
    (db) async =>
        (await db.update(
          'command_worker_leases',
          {'expires_at': DateTime.now().millisecondsSinceEpoch + 120000},
          where: 'lease_key = ? AND owner = ?',
          whereArgs: [key, owner],
        )) ==
        1,
  );
  Future<void> releaseLease(String key, String owner) =>
      _withDb('outbox.releaseLease', (db) async {
        await db.delete(
          'command_worker_leases',
          where: 'lease_key = ? AND owner = ?',
          whereArgs: [key, owner],
        );
      });

  /// Claim up to [limit] ready rows for sending (single-flight owner).
  Future<List<CommandOutboxEntry>> claim({
    int limit = 20,
  }) => _withDb('outbox.claim', (db) {
    return tracedTransaction(db, 'outbox.claim', (txn) async {
      final scope = scopeProvider?.call();
      if (scopeProvider != null && scope == null) return <CommandOutboxEntry>[];
      final rows = await txn.query(
        'command_outbox',
        where:
            "state = 'pending' AND (next_attempt_at IS NULL "
            'OR next_attempt_at <= ?)${scope == null ? '' : ' AND organization_id = ? AND uid = ? AND device_id = ?'}',
        whereArgs: [
          nowIso(),
          if (scope != null) ...[
            scope.organizationId,
            scope.uid,
            scope.deviceId,
          ],
        ],
        orderBy: 'id ASC',
        limit: limit,
      );
      final claimed = <CommandOutboxEntry>[];
      for (final row in rows) {
        final outboxId = (row['id'] as num).toInt();
        final updated = await txn.update(
          'command_outbox',
          {
            'state': 'in_flight',
            'attempts': (row['attempts'] as num).toInt() + 1,
            'updated_at': nowIso(),
          },
          where: "id = ? AND state = 'pending'",
          whereArgs: [outboxId],
        );
        if (updated > 0) {
          claimed.add(
            CommandOutboxEntry.fromRow({
              ...row,
              'state': 'in_flight',
              'attempts': (row['attempts'] as num).toInt() + 1,
            }),
          );
          await DraftsStore.transition(
            txn,
            '${row['draft_id']}',
            state: DraftState.sending,
          );
        }
      }
      return claimed;
    });
  });

  /// Approved: the receipt is persisted with the operation and its effect.
  /// The row stays (receipts are never dropped while replays may exist).
  Future<void> settleApproved(String operationId, CommandResult result) =>
      _withDb('outbox.settleApproved', (db) {
        return tracedTransaction(db, 'outbox.settleApproved', (txn) async {
          if (result.operationId != operationId || !result.isApproved) {
            throw StateError('Invalid receipt');
          }
          final changed = await txn.update(
            'command_outbox',
            {
              'state': 'approved',
              'result_json': jsonEncode(result.toJson()),
              'last_error_code': null,
              'last_error': null,
              'next_attempt_at': null,
              'updated_at': nowIso(),
            },
            where: "operation_id = ? AND state != 'approved'",
            whereArgs: [operationId],
          );
          if (changed == 0) return;
          final draftId = await _draftIdOf(txn, operationId);
          if (draftId != null) {
            await DraftsStore.transition(
              txn,
              draftId,
              state: DraftState.approvedOnServer,
            );
          }
        });
      });

  /// Transient transport failure → backoff, stay pending (§5 "انقطاع الشبكة
  /// أو مهلة الاستجابة يعيدان نفس العملية").
  Future<void> settleRetry(
    String operationId, {
    required String code,
    required String message,
  }) => _withDb('outbox.settleRetry', (db) {
    return tracedTransaction(db, 'outbox.settleRetry', (txn) async {
      final rows = await txn.query(
        'command_outbox',
        columns: const ['id', 'attempts', 'draft_id'],
        where: 'operation_id = ? AND state = ?',
        whereArgs: [operationId, 'in_flight'],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final attempts = (rows.first['attempts'] as num?)?.toInt() ?? 0;
      await txn.update(
        'command_outbox',
        {
          'state': 'pending',
          'attempts': attempts,
          'next_attempt_at': nowIsoAt(
            DateTime.now().add(backoffDelay(attempts > 0 ? attempts - 1 : 0)),
          ),
          'last_error_code': code,
          'last_error': message,
          'updated_at': nowIso(),
        },
        where: 'id = ?',
        whereArgs: [(rows.first['id'] as num).toInt()],
      );
      // The draft returns to "waiting" so the user sees pending, not failure.
      await DraftsStore.transition(
        txn,
        '${rows.first['draft_id']}',
        state: DraftState.waitingSend,
      );
    });
  });

  /// Permanent stop states with the reason saved (§5).
  Future<void> settleTerminal(
    String operationId, {
    required OutboxState state,
    required String code,
    required String message,
    CommandResult? result,
  }) => _withDb('outbox.settleTerminal', (db) {
    return tracedTransaction(db, 'outbox.settleTerminal', (txn) async {
      final changed = await txn.update(
        'command_outbox',
        {
          'state': state.value,
          'last_error_code': code,
          'last_error': message,
          'next_attempt_at': null,
          'result_json': result == null ? null : jsonEncode(result.toJson()),
          'updated_at': nowIso(),
        },
        where: 'operation_id = ? AND state = ?',
        whereArgs: [operationId, 'in_flight'],
      );
      if (changed == 0) return;
      final draftId = await _draftIdOf(txn, operationId);
      if (draftId != null) {
        final draftState = switch (state) {
          OutboxState.rejected => DraftState.rejected,
          OutboxState.needsReview => DraftState.needsReview,
          OutboxState.authRequired => DraftState.requiresAuth,
          _ => null,
        };
        if (draftState != null) {
          await DraftsStore.transition(
            txn,
            draftId,
            state: draftState,
            failure: CommandFailure(code: code, messageAr: message),
          );
        }
      }
    });
  });

  /// in_flight rows stranded by a process death go back to pending (§12
  /// "توقف العميل بعد استلام الرد وقبل تحديث الكاش → استئناف من الإيصال").
  /// The server-side receipt makes the replay harmless.
  Future<int> recoverStalled() => _withDb('outbox.recoverStalled', (db) {
    return tracedTransaction(db, 'outbox.recoverStalled', (txn) async {
      final scope = scopeProvider?.call();
      if (scopeProvider != null && scope == null) return 0;
      final rows = await txn.query(
        'command_outbox',
        columns: ['id', 'draft_id'],
        where:
            "state = 'in_flight'${scope == null ? '' : ' AND organization_id = ? AND uid = ? AND device_id = ?'}",
        whereArgs: scope == null
            ? null
            : [scope.organizationId, scope.uid, scope.deviceId],
      );
      for (final row in rows) {
        await txn.update(
          'command_outbox',
          {
            'state': 'pending',
            'next_attempt_at': nowIso(),
            'last_error': 'interrupted mid-send',
            'updated_at': nowIso(),
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        await DraftsStore.transition(
          txn,
          '${row['draft_id']}',
          state: DraftState.waitingSend,
        );
      }
      return rows.length;
    });
  });

  Future<CommandOutboxCounts> counts() => _withDb('outbox.counts', (db) async {
    final scope = scopeProvider?.call();
    final condition = scope == null
        ? (scopeProvider == null ? '1=1' : '0=1')
        : 'organization_id = ? AND uid = ?';
    final rows = await db.rawQuery('''
      SELECT
        SUM(CASE WHEN state = 'pending' OR state = 'in_flight'
                 THEN 1 ELSE 0 END) AS pending,
        SUM(CASE WHEN state = 'in_flight' THEN 1 ELSE 0 END) AS inFlight,
        SUM(CASE WHEN state = 'approved' THEN 1 ELSE 0 END) AS approved,
        SUM(CASE WHEN state = 'rejected' THEN 1 ELSE 0 END) AS rejected,
        SUM(CASE WHEN state = 'needs_review' THEN 1 ELSE 0 END) AS needsReview,
        SUM(CASE WHEN state = 'auth_required' THEN 1 ELSE 0 END) AS authRequired
      FROM command_outbox WHERE $condition
    ''', scope == null ? [] : [scope.organizationId, scope.uid]);
    final projectionRows = scope == null
        ? const <Map<String, Object?>>[]
        : await db.rawQuery(
            '''
          SELECT COUNT(*) AS n FROM central_command_entities c
          INNER JOIN command_outbox o ON o.operation_id = c.operation_id
          WHERE o.organization_id = ? AND o.uid = ? AND o.state = 'approved'
        ''',
            [scope.organizationId, scope.uid],
          );
    return CommandOutboxCounts(
      pending: ((rows.first['pending'] ?? 0) as num).toInt(),
      inFlight: ((rows.first['inFlight'] ?? 0) as num).toInt(),
      approved: ((rows.first['approved'] ?? 0) as num).toInt(),
      rejected: ((rows.first['rejected'] ?? 0) as num).toInt(),
      needsReview: ((rows.first['needsReview'] ?? 0) as num).toInt(),
      requiresAuth: ((rows.first['authRequired'] ?? 0) as num).toInt(),
      awaitingProjection: projectionRows.isEmpty
          ? 0
          : (projectionRows.first['n'] as num).toInt(),
    );
  });

  /// The outbox list for the Sync/status screens, annoyances first.
  Future<List<CommandOutboxEntry>> list({int limit = 200}) =>
      _withDb('outbox.list', (db) async {
        final scope = scopeProvider?.call();
        final rows = await db.query(
          'command_outbox',
          where: scope == null
              ? (scopeProvider == null ? null : '0=1')
              : 'organization_id = ? AND uid = ?',
          whereArgs: scope == null ? null : [scope.organizationId, scope.uid],
          orderBy:
              "CASE state WHEN 'rejected' THEN 0 WHEN 'needs_review' THEN 1 "
              "WHEN 'auth_required' THEN 2 WHEN 'in_flight' THEN 3 "
              "WHEN 'pending' THEN 4 ELSE 5 END, id DESC",
          limit: limit,
        );
        return rows.map(CommandOutboxEntry.fromRow).toList();
      });

  Future<CommandOutboxEntry?> getByOperationId(String operationId) =>
      _withDb('outbox.getByOperationId', (db) async {
        final scope = scopeProvider?.call();
        if (scopeProvider != null && scope == null) return null;
        final rows = await db.query(
          'command_outbox',
          where: scope == null
              ? 'operation_id = ?'
              : 'operation_id = ? AND organization_id = ? AND uid = ?',
          whereArgs: scope == null
              ? [operationId]
              : [operationId, scope.organizationId, scope.uid],
          limit: 1,
        );
        return rows.isEmpty ? null : CommandOutboxEntry.fromRow(rows.single);
      });

  Future<Set<String>> approvedOperationIdsThrough(int sequence) =>
      _withDb('outbox.approvedThrough', (db) async {
        final scope = scopeProvider?.call();
        if (scopeProvider != null && scope == null) return <String>{};
        final rows = await db.query(
          'command_outbox',
          columns: const ['operation_id', 'result_json'],
          where: scope == null
              ? "state = 'approved'"
              : "state = 'approved' AND organization_id = ? AND uid = ?",
          whereArgs: scope == null ? null : [scope.organizationId, scope.uid],
        );
        final covered = <String>{};
        for (final row in rows) {
          final raw = row['result_json'];
          if (raw is! String) continue;
          try {
            final result = CommandResult.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
            if ((result.changeSequence ?? sequence + 1) <= sequence) {
              covered.add(row['operation_id'] as String);
            }
          } on Object {
            // A malformed result cannot release its entity lock.
          }
        }
        return covered;
      });

  /// After a fresh sign-in for the SAME account/organization/device (the
  /// scope provider guarantees the match), `auth_required` requests return
  /// to the queue with their original operationId and hash — the server
  /// receipt makes the replay harmless — and the draft walks back to
  /// waitingSend IN THE SAME TRANSACTION, so the request and its draft state
  /// can never disagree (production acceptance 3: "تحديث حالة المسودة معه
  /// ذريًا"). Callers must only invoke this after authentication succeeded;
  /// it refuses to run without an active scope.
  Future<int> retryRejected({
    required bool onlyPendingable,
  }) => _withDb('outbox.retryRejected', (db) async {
    if (!onlyPendingable) return 0;
    final scope = scopeProvider?.call();
    if (scopeProvider != null && scope == null) return 0;
    return tracedTransaction(db, 'outbox.retryRejected.tx', (txn) async {
      final rows = await txn.query(
        'command_outbox',
        columns: ['id', 'draft_id'],
        where:
            "state = 'auth_required'${scope == null ? '' : ' AND organization_id = ? AND uid = ? AND device_id = ?'}",
        whereArgs: scope == null
            ? null
            : [scope.organizationId, scope.uid, scope.deviceId],
      );
      for (final row in rows) {
        await txn.update(
          'command_outbox',
          {
            'state': OutboxState.pending.value,
            'next_attempt_at': null,
            'updated_at': nowIso(),
          },
          where: 'id = ? AND state = ?',
          whereArgs: [(row['id'] as num).toInt(), OutboxState.authRequired.value],
        );
        await DraftsStore.transition(
          txn,
          '${row['draft_id']}',
          state: DraftState.waitingSend,
        );
      }
      return rows.length;
    });
  });

  /// Explicit user decision on a stop state (production acceptance 3):
  /// archives ONE settled request — `rejected` or `needs_review` — and
  /// releases its entity locks, so a corrected request can be authored at
  /// the current server version. The row is kept with its reason and the
  /// resolution timestamp (state `archived`), the server receipt is never
  /// touched, and requests whose fate is still unknown (pending / in_flight /
  /// auth_required / approved-but-unapplied) are refused.
  Future<bool> releaseLockAndArchive(
    String operationId, {
    String? reason,
  }) => _withDb('outbox.releaseLockAndArchive', (db) {
    return tracedTransaction(db, 'outbox.releaseLockAndArchive', (txn) async {
      final scope = scopeProvider?.call();
      if (scopeProvider != null && scope == null) return false;
      final rows = await txn.query(
        'command_outbox',
        where:
            'operation_id = ?${scope == null ? '' : ' AND organization_id = ? AND uid = ?'}',
        whereArgs: scope == null
            ? [operationId]
            : [operationId, scope.organizationId, scope.uid],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      final entry = CommandOutboxEntry.fromRow(rows.single);
      if (entry.state != OutboxState.rejected &&
          entry.state != OutboxState.needsReview) {
        return false;
      }
      final changed = await txn.update(
        'command_outbox',
        {
          'state': OutboxState.archived.value,
          'next_attempt_at': null,
          'updated_at': nowIso(),
          'last_error': ?reason,
        },
        where: 'id = ? AND state IN (?, ?)',
        whereArgs: [
          entry.id,
          OutboxState.rejected.value,
          OutboxState.needsReview.value,
        ],
      );
      if (changed == 0) return false;
      await txn.delete(
        'central_command_entities',
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
      return true;
    });
  });

  /// Central cleanup (production acceptance 3): archives RESOLVED rows only —
  /// approved requests old enough that their event has long been applied
  /// (the projection removed their entity locks). It never deletes receipts
  /// or `result_json`, never touches pending / in-flight / blocked rows, and
  /// therefore never hides a request whose fate is still unknown.
  Future<int> archiveSettled({Duration age = const Duration(days: 7)}) =>
      _withDb('outbox.archiveSettled', (db) async {
        final scope = scopeProvider?.call();
        if (scopeProvider != null && scope == null) return 0;
        final cutoff = nowIsoAt(DateTime.now().subtract(age));
        return db.rawUpdate(
          "UPDATE command_outbox SET state = 'archived', updated_at = ? "
          "WHERE state = 'approved' AND updated_at < ?"
          '${scope == null ? '' : ' AND organization_id = ? AND uid = ?'}',
          [
            nowIso(),
            cutoff,
            if (scope != null) ...[scope.organizationId, scope.uid],
          ],
        );
      });

  Future<String?> _draftIdOf(DatabaseExecutor txn, String operationId) async {
    final rows = await txn.query(
      'command_outbox',
      columns: const ['draft_id'],
      where: 'operation_id = ?',
      whereArgs: [operationId],
      limit: 1,
    );
    return rows.isEmpty ? null : '${rows.first['draft_id']}';
  }

  /// Exponential backoff with deterministic ±20% jitter, capped at 15 minutes.
  /// Same shape as `SyncQueue.backoffDelay` so both ladders look the same,
  /// and deterministic in tests.
  static Duration backoffDelay(int attempt) {
    const cap = 900;
    final seconds = (5 * (1 << attempt.clamp(0, 20))).clamp(0, cap);
    final jitter = (seconds * 0.2 * ((attempt % 5) - 2) / 2).round();
    return Duration(seconds: seconds + jitter);
  }
}
