/// User drafts (plan `SYNC_ARCHITECTURE_PLAN_2026-10-25` §5) — the *local*
/// authoring store, logically separate from both the read model (server
/// records) and the command outbox (submit requests).
///
/// A draft lives only on the device that created it (§5: "المسودة غير المرسلة
/// توجد على الجهاز الذي أنشأها"): keyed by organization + author + a global
/// UUID `draftId`, never shared via sync. Saving or editing a draft NEVER
/// produces a sync write or a command; only an explicit "submit" by the user
/// (handled by [CommandService]) turns it into an outbox entry.
library;

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../database/database_helper.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'command_contract.dart';

/// Draft lifecycle (§5 states, Arabic labels live in the presentation layer).
enum DraftState {
  /// Local authoring; nothing staged.
  localDraft('local_draft'),

  /// Submit chosen: draft + outbox row committed in one transaction, waiting
  /// for connectivity / next worker drain.
  waitingSend('waiting_send'),

  /// Claimed by the worker, request in flight.
  sending('sending'),

  /// Server approved (receipt persisted). The approved values are the server
  /// result, not the draft payload.
  approvedOnServer('approved'),

  /// Server decided the content needs a decision from the user (e.g. version
  /// conflict — the server returned the current record + diffs conceptually).
  needsReview('needs_review'),

  /// Rejected by permission / business rule; draft kept with the reason.
  rejected('rejected'),

  /// Cannot be sent until sign-in.
  requiresAuth('requires_auth');

  const DraftState(this.value);
  final String value;

  static DraftState from(String value) => values.firstWhere(
    (state) => state.value == value,
    orElse: () => DraftState.localDraft,
  );

  bool get isTerminal =>
      this == DraftState.approvedOnServer ||
      this == DraftState.needsReview ||
      this == DraftState.rejected ||
      this == DraftState.requiresAuth;

  /// "مسودة محلية → بانتظار الإرسال → جارٍ الإرسال → معتمد" or one of the
  /// stop states — never shows a draft as approved before the receipt.
  bool get canShowAsApproved => this == DraftState.approvedOnServer;
}

/// One saved draft.
class CommandDraft {
  const CommandDraft({
    required this.id,
    required this.organizationId,
    required this.uid,
    required this.entityType,
    required this.operation,
    required this.state,
    required this.payload,
    required this.createdAt,
    required this.updatedAt,
    this.entityId = '',
    this.parentEntityType = '',
    this.parentEntityId = '',
    this.baseVersion = 0,
    this.failure,
  });

  /// Global UUID — no table row numbering crosses devices.
  final String id;
  final String organizationId;
  final String uid;

  /// Entity family (e.g. `sample`).
  final String entityType;

  /// `create` / `update` / `delete`.
  final String operation;

  /// Global parent identity for relation-gated creates (§7), e.g. the product
  /// inspection a sample belongs to.
  final String parentEntityType;
  final String parentEntityId;

  /// Global entity id for update/`delete` ops (empty for create until the
  /// server assigns one).
  final String entityId;

  /// Server version the draft started from (0 for creates).
  final int baseVersion;

  final Map<String, dynamic> payload;
  final DraftState state;
  final CommandFailure? failure;
  final String createdAt;
  final String updatedAt;

  Map<String, dynamic> toRow() => {
    'id': id,
    'organization_id': organizationId,
    'uid': uid,
    'entity_type': entityType,
    'operation': operation,
    'entity_id': entityId,
    'parent_entity_type': parentEntityType,
    'parent_entity_id': parentEntityId,
    'base_version': baseVersion,
    'payload': jsonEncode(payload),
    'state': state.value,
    'failure_code': failure?.code,
    'failure_message': failure?.messageAr,
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  static CommandDraft fromRow(Map<String, Object?> row) {
    final failureCode = row['failure_code'] as String?;
    return CommandDraft(
      id: '${row['id']}',
      organizationId: '${row['organization_id']}',
      uid: '${row['uid']}',
      entityType: '${row['entity_type']}',
      operation: '${row['operation']}',
      entityId: '${row['entity_id'] ?? ''}',
      parentEntityType: '${row['parent_entity_type'] ?? ''}',
      parentEntityId: '${row['parent_entity_id'] ?? ''}',
      baseVersion: (row['base_version'] as num?)?.toInt() ?? 0,
      payload:
          jsonDecode('${row['payload'] ?? '{}'}') as Map<String, dynamic>? ??
          <String, dynamic>{},
      state: DraftState.from('${row['state']}'),
      failure: failureCode == null
          ? null
          : CommandFailure(
              code: failureCode,
              messageAr: '${row['failure_message'] ?? ''}',
            ),
      createdAt: '${row['created_at']}',
      updatedAt: '${row['updated_at']}',
    );
  }
}

/// SQLite-backed drafts store. Writes go through [DatabaseHelper] so an
/// organization switch / restore closes underneath safely (same pattern as
/// `SyncQueue._withDb`).
class DraftsStore {
  DraftsStore(this.dbHelper) {
    dbHelper.onDatabaseClosed(() => _resolved = null);
  }

  final DatabaseHelper dbHelper;
  CommandScope? Function()? scopeProvider;

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

  /// Insert or update this draft (identity = uuid [CommandDraft.id]).
  ///
  /// Draft-only: writing here creates no sync work.
  Future<CommandDraft> save(CommandDraft draft) => _withDb('drafts.save', (
    db,
  ) async {
    await tracedTransaction(db, 'drafts.save', (txn) async {
      if (draft.state != DraftState.localDraft) {
        throw StateError(
          'Only the command lifecycle may approve or submit a draft',
        );
      }
      final scope = scopeProvider?.call();
      if (scopeProvider != null &&
          (scope == null || !scope.owns(draft.organizationId, draft.uid))) {
        throw StateError('Wrong draft owner');
      }
      final previous = await txn.query(
        'drafts',
        where: 'id = ?',
        whereArgs: [draft.id],
      );
      if (previous.isNotEmpty &&
          (previous.single['uid'] != draft.uid ||
              previous.single['organization_id'] != draft.organizationId ||
              previous.single['state'] == 'approved')) {
        throw StateError('Draft ownership/state is immutable');
      }
      final sent = await txn.query(
        'command_outbox',
        where: 'draft_id = ?',
        whereArgs: [draft.id],
      );
      if (sent.any(
        (row) =>
            row['state'] != 'pending' || (row['attempts'] as num).toInt() > 0,
      )) {
        throw StateError('Resolve the submitted operation before editing');
      }
      await txn.delete(
        'command_outbox',
        where: "draft_id = ? AND state = 'pending' AND attempts = 0",
        whereArgs: [draft.id],
      );
      await txn.insert(
        'drafts',
        draft.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
    return draft;
  });

  Future<CommandDraft?> get(String id) => _withDb('drafts.get', (db) async {
    final scope = scopeProvider?.call();
    final rows = await db.query(
      'drafts',
      where:
          'id = ?${scope == null ? (scopeProvider == null ? '' : ' AND 0=1') : ' AND organization_id = ? AND uid = ?'}',
      whereArgs: [
        id,
        if (scope != null) ...[scope.organizationId, scope.uid],
      ],
      limit: 1,
    );
    return rows.isEmpty ? null : CommandDraft.fromRow(rows.first);
  });

  /// One draft per entity stage — the editor screen finds what to re-open.
  Future<List<CommandDraft>> listForEntity({
    required String organizationId,
    required String uid,
    required String entityType,
    required String entityId,
  }) => _withDb('drafts.listForEntity', (db) async {
    final scope = scopeProvider?.call();
    if (scopeProvider != null &&
        (scope == null || !scope.owns(organizationId, uid))) {
      return <Map<String, Object?>>[];
    }
    return db.query(
      'drafts',
      where:
          'organization_id = ? AND uid = ? AND entity_type = ? AND entity_id = ?',
      whereArgs: [organizationId, uid, entityType, entityId],
      orderBy: 'updated_at DESC',
    );
  }).then((rows) => rows.map(CommandDraft.fromRow).toList());

  /// Drafts that still need the user (stop states + authoring + in-flight).
  Future<List<CommandDraft>> listOpen({
    int limit = 200,
  }) => _withDb('drafts.listOpen', (db) async {
    final scope = scopeProvider?.call();
    final rows = await db.query(
      'drafts',
      where:
          "state != 'approved'${scope == null ? (scopeProvider == null ? '' : ' AND 0=1') : ' AND organization_id = ? AND uid = ?'}",
      whereArgs: scope == null ? null : [scope.organizationId, scope.uid],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(CommandDraft.fromRow).toList();
  });

  /// State machine of a submit/transport cycle inside the caller's txn.
  ///
  /// Terminal transitions are guarded: an approved draft can never be walked
  /// back to `sending` by a late, stale response.
  static Future<void> transition(
    DatabaseExecutor txn,
    String draftId, {
    required DraftState state,
    CommandFailure? failure,
  }) async {
    final guard = state == DraftState.approvedOnServer
        ? '' // receipts are terminal; caller already checked pre-state
        : "AND state != 'approved'";
    await txn.update(
      'drafts',
      {
        'state': state.value,
        'failure_code': failure?.code,
        'failure_message': failure?.messageAr,
        'updated_at': nowIso(),
      },
      where: 'id = ? $guard',
      whereArgs: [draftId],
    );
  }

  /// Remove drafts already approved long ago (§5 bookkeeping; the server
  /// record itself lives in the read model).
  Future<int> purgeApproved({
    Duration age = const Duration(days: 1),
  }) => _withDb('drafts.purgeApproved', (db) async {
    final scope = scopeProvider?.call();
    if (scopeProvider != null && scope == null) return 0;
    final cutoff = nowIsoAt(DateTime.now().subtract(age));
    return db.delete(
      'drafts',
      where:
          "state = 'approved' AND updated_at < ?${scope == null ? '' : ' AND organization_id = ? AND uid = ?'}",
      whereArgs: [
        cutoff,
        if (scope != null) ...[scope.organizationId, scope.uid],
      ],
    );
  });
}
