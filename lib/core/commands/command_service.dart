/// The command facade (plan `SYNC_ARCHITECTURE_PLAN_2026-10-25` §5-§7).
///
/// `submitDraft` is the ONLY entry from the UI into the new send path and
/// guarantees, per call:
///  * relation gate BEFORE staging (§7: "فحص العلاقات شرط يسبق تشغيل المسار
///    الجديد") — a create whose parent is missing / tombstoned can never
///    reach the outbox; the draft parks as `needsReview` with a saved reason;
///  * draft + outbox staging in ONE SQLite transaction, so a crash leaves
///    both present or neither;
///  * a NEW operationId per distinct content, replacing the previous
///    never-sent stage — the worker always re-sends the fixed id it sent.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../database/database_helper.dart';
import '../database/db_trace.dart';
import '../utils/app_dates.dart';
import 'command_contract.dart';
import 'command_outbox.dart';
import 'drafts_store.dart';

/// What a submit produced, for the caller's UI state machine.
class SubmitOutcome {
  const SubmitOutcome({
    required this.draft,
    required this.staged,
    this.operationId,
    this.entityId,
    this.failure,
  });

  /// `true` when the request was staged into the outbox. `false` keeps the
  /// draft (never deletes it): every refusal goes through the stop states.
  final bool staged;
  final CommandDraft draft;

  /// Fresh operationId when [staged].
  final String? operationId;

  final String? entityId;
  final CommandFailure? failure;
}

/// Builds the business payload / command meta for a draft; entity-registry
/// specific (§4 sweep gate: no entity ships without its entry here).
abstract interface class CommandSpecResolver {
  /// The command type + payload for a draft, or null when the draft's
  /// fields/operation violate the contract — the caller then parks the draft
  /// with `BAD_PAYLOAD` and a reason instead of staging it.
  ({
    String commandType,
    Map<String, dynamic> payload,
    Map<String, String> dependencies,
  })?
  resolve(CommandDraft draft);
}

/// Reads the approved read-model rows used by the relation gate.
abstract interface class CommandReadModel {
  /// The local copy of a server-approved record, keyed by its GLOBAL id.
  /// Returns null when the device has not synced it (never fabricates one).
  Future<({Map<String, dynamic> row, bool deleted, int version})?>
  readApprovedEntity({
    required String organizationId,
    required String entityType,
    required String entityId,
  });
}

/// Pilot-scope resolver for the inspection sample family (registry entity
/// `sample`: global identity via entry code / uuid).
class SampleCommandSpecResolver implements CommandSpecResolver {
  const SampleCommandSpecResolver();

  @override
  ({
    String commandType,
    Map<String, dynamic> payload,
    Map<String, String> dependencies,
  })?
  resolve(CommandDraft draft) {
    switch (draft.operation) {
      case 'create':
        return (
          commandType: CommandTypes.sampleCreate,
          payload: {...draft.payload, 'organizationId': draft.organizationId},
          dependencies: {
            if (draft.parentEntityId.isNotEmpty)
              'parent_${draft.parentEntityType}': draft.parentEntityId,
          },
        );
      case 'update':
        return (
          commandType: CommandTypes.sampleUpdate,
          payload: {...draft.payload, 'organizationId': draft.organizationId},
          dependencies: const <String, String>{},
        );
      case 'delete':
        return (
          commandType: CommandTypes.sampleDelete,
          payload: const <String, dynamic>{},
          dependencies: const <String, String>{},
        );
    }
    return null;
  }
}

class CommandService {
  CommandService({
    required this.dbHelper,
    required this.drafts,
    required this.outbox,
    required this.readModel,
    this.specResolver = const SampleCommandSpecResolver(),
    this.onDrainRequested,
  });

  final DatabaseHelper dbHelper;
  final DraftsStore drafts;
  final CommandOutbox outbox;
  final CommandReadModel readModel;
  final CommandSpecResolver specResolver;

  /// Fired after a successful stage so the worker drains within seconds.
  void Function()? onDrainRequested;

  /// One staged submit = one business command. Re-submitting an already
  /// approved draft is a no-op (the receipt already covers it).
  Future<SubmitOutcome> submitDraft(CommandDraft draft) async {
    final scope = outbox.scopeProvider?.call();
    if (outbox.scopeProvider != null &&
        (scope == null || !scope.owns(draft.organizationId, draft.uid))) {
      throw StateError('Wrong active draft owner');
    }
    final existing = await drafts.get(draft.id);
    if (existing != null && existing.state == DraftState.approvedOnServer) {
      return SubmitOutcome(staged: false, draft: existing);
    }

    if (draft.entityType != 'sample') {
      throw ArgumentError(
        'Only inspection commands are implemented in this pilot',
      );
    }
    final resolved = specResolver.resolve(draft);
    if (resolved == null) {
      return _park(
        draft,
        const CommandFailure(
          code: CommandErrorCodes.badPayload,
          messageAr: 'المسودة لا تحمل كل حقول الأجل المطلوبة.',
        ),
      );
    }
    if (!CommandTypes.all.contains(resolved.commandType)) {
      return _park(
        draft,
        const CommandFailure(
          code: CommandErrorCodes.badCommandType,
          messageAr: 'نوع أمر غير مسموح.',
        ),
      );
    }

    final entityId = draft.operation == 'create'
        ? (draft.entityId.isEmpty ? draft.id : draft.entityId)
        : draft.entityId;
    if ((draft.operation == 'update' || draft.operation == 'delete') &&
        draft.entityId.isEmpty) {
      return _park(
        draft,
        const CommandFailure(
          code: CommandErrorCodes.badPayload,
          messageAr: 'أمر تعديل/حذف يجب أن يشير إلى سجل معتمد بمعرف عالمي.',
        ),
      );
    }

    final relation = await _relationGateFailure(draft);
    if (relation != null) {
      return _park(draft, relation);
    }

    final merged = CommandDraft(
      id: draft.id,
      organizationId: draft.organizationId,
      uid: draft.uid,
      entityType: draft.entityType,
      operation: draft.operation,
      entityId: entityId,
      parentEntityType: draft.parentEntityType,
      parentEntityId: draft.parentEntityId,
      baseVersion: draft.baseVersion,
      payload: draft.payload,
      state: DraftState.waitingSend,
      failure: null,
      createdAt: draft.createdAt.isEmpty ? nowIso() : draft.createdAt,
      updatedAt: nowIso(),
    );

    final outcome = await _run((db) {
      return db.transaction<SubmitOutcome>((txn) async {
        final current = await txn.query(
          'drafts',
          where: 'id = ?',
          whereArgs: [draft.id],
        );
        if (current.isNotEmpty) {
          if (current.single['uid'] != draft.uid ||
              current.single['organization_id'] != draft.organizationId) {
            throw StateError('Wrong draft owner');
          }
          if (current.single['state'] == 'approved') {
            return SubmitOutcome(
              staged: false,
              draft: CommandDraft.fromRow(current.single),
            );
          }
        }
        final entry = await outbox.enqueueDraftSubmit(
          txn,
          draft: merged,
          commandType: resolved.commandType,
          entityId: entityId,
          expectedVersion: merged.baseVersion,
          payload: resolved.payload,
          dependencies: resolved.dependencies,
        );
        await txn.insert(
          'drafts',
          merged.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        return SubmitOutcome(
          staged: true,
          draft: merged,
          operationId: entry.operationId,
          entityId: entry.entityId,
        );
      });
    });
    if (outcome.staged) {
      try {
        onDrainRequested?.call();
      } on Object catch (error) {
        debugPrint('[commands] scheduled after commit: $error');
      }
    }
    return outcome;
  }

  /// §7 relationship gate over the LOCAL read model. The server repeats it
  /// inside its transaction — this gate exists to keep obvious refusals
  /// out of the outbox; it must never let a bad command THROUGH.
  Future<CommandFailure?> _relationGateFailure(CommandDraft draft) async {
    if (draft.parentEntityType.isEmpty || draft.parentEntityId.isEmpty) {
      return null;
    }
    final parent = await readModel.readApprovedEntity(
      organizationId: draft.organizationId,
      entityType: draft.parentEntityType,
      entityId: draft.parentEntityId,
    );
    if (parent == null) {
      return const CommandFailure(
        code: CommandErrorCodes.parentMissingOrDeleted,
        messageAr:
            'السجل الأب غير متوفر محلياً؛ أرسل بعد اكتمال التحميل أو '
            'عند اتصال السيرفر.',
      );
    }
    if (parent.deleted) {
      return const CommandFailure(
        code: CommandErrorCodes.parentDeletedCannotLink,
        messageAr: 'السجل الأب محذوف؛ لا يمكن ربط مسودات جديدة بسجل محذوف.',
      );
    }
    return const CommandFailure(
      code: CommandErrorCodes.badCommandType,
      messageAr:
          'العينات التشغيلية تحتاج أمرًا مستقلًا غير متاح في النطاق التجريبي.',
    );
  }

  Future<SubmitOutcome> _park(
    CommandDraft draft,
    CommandFailure failure,
  ) async {
    final saved = CommandDraft(
      id: draft.id,
      organizationId: draft.organizationId,
      uid: draft.uid,
      entityType: draft.entityType,
      operation: draft.operation,
      entityId: draft.entityId,
      parentEntityType: draft.parentEntityType,
      parentEntityId: draft.parentEntityId,
      baseVersion: draft.baseVersion,
      payload: draft.payload,
      state: DraftState.needsReview,
      failure: failure,
      createdAt: draft.createdAt.isEmpty ? nowIso() : draft.createdAt,
      updatedAt: nowIso(),
    );
    await _run(
      (db) => db.transaction((txn) async {
        final scope = outbox.scopeProvider?.call();
        if (outbox.scopeProvider != null &&
            (scope == null || !scope.owns(draft.organizationId, draft.uid))) {
          throw StateError('Session changed while checking the draft');
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
          throw StateError(
            'Cannot replace a submitted draft with a local rejection',
          );
        }
        final old = await txn.query(
          'drafts',
          where: 'id = ?',
          whereArgs: [draft.id],
        );
        if (old.isNotEmpty &&
            (old.single['uid'] != draft.uid ||
                old.single['organization_id'] != draft.organizationId ||
                old.single['state'] == 'approved')) {
          throw StateError('Wrong draft state/owner');
        }
        await txn.delete(
          'command_outbox',
          where: "draft_id = ? AND state = 'pending' AND attempts = 0",
          whereArgs: [draft.id],
        );
        await txn.insert(
          'drafts',
          saved.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }),
    );
    return SubmitOutcome(
      staged: false,
      draft: saved,
      entityId: saved.entityId,
      failure: failure,
    );
  }

  /// Same connection-health handling as the other stores: survive a close
  /// racing this single write.
  Future<T> _run<T>(Future<T> Function(Database db) action) =>
      DbTrace.run('commands.submit', () async {
        try {
          return await action(await dbHelper.database);
        } on DatabaseException catch (e) {
          if (!e.isDatabaseClosedError()) rethrow;
          return await action(await dbHelper.database);
        }
      });
}
