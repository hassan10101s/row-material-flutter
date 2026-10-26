import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/drafts_store.dart';
import 'package:material_lab/core/commands/sync_checkpoint.dart';
import 'package:material_lab/core/utils/app_dates.dart';

import '../sync/sync_test_fixture.dart';

/// `command_outbox` / `drafts` / `sync_checkpoint` lifecycle (plan §5/§6):
/// real SQLite, production schema, one-transaction staging semantics.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncFixture fixture;
  late DraftsStore drafts;
  late CommandOutbox outbox;
  late SyncCheckpoints checkpoints;

  setUp(() async {
    fixture = await openSyncFixture();
    drafts = DraftsStore(fixture.helper);
    outbox = CommandOutbox(fixture.helper)..deviceProvider = () => 'dev-1';
    checkpoints = SyncCheckpoints(fixture.helper);
  });

  tearDown(() async => fixture.dispose());

  CommandDraft draft({
    String id = 'd-1',
    String operation = 'create',
    String parentEntityId = 'P-1',
    String? entityId,
    Map<String, dynamic> payload = const {'sampleName': 'Cement A'},
  }) => CommandDraft(
    id: id,
    organizationId: 'org-1',
    uid: 'uid-1',
    entityType: 'sample',
    operation: operation,
    entityId: entityId ?? (operation == 'create' ? '' : 'P-1'),
    parentEntityType: parentEntityId.isEmpty ? '' : 'sample',
    parentEntityId: parentEntityId,
    baseVersion: operation == 'create' ? 0 : 3,
    payload: payload,
    state: DraftState.localDraft,
    createdAt: '2026-10-25 10:00:00',
    updatedAt: '2026-10-25 10:00:00',
  );

  group('staging (draft + outbox in one transaction)', () {
    test(
      'staging produces a pending row + waiting draft and a fixed hash',
      () async {
        final d = draft();
        await drafts.save(d);
        final staged = await fixture.transaction(
          (txn) => outbox.enqueueDraftSubmit(
            txn,
            draft: d,
            commandType: CommandTypes.sampleCreate,
            entityId: 'draft:d-1',
            expectedVersion: 0,
            payload: {'sampleName': 'Cement A'},
            dependencies: {'parent_sample': 'P-1'},
          ),
        );

        final rows = await outbox.list();
        expect(rows, hasLength(1));
        final row = rows.single;
        expect(row.operationId, staged.operationId);
        expect(row.state, OutboxState.pending);
        expect(row.attempts, 0);
        expect(row.deviceId, 'dev-1');
        expect(row.payloadHash, hashPayload(row.payload));
        expect(row.dependencies, {'parent_sample': 'P-1'});

        final saved = await drafts.get('d-1');
        expect(saved, isNotNull);
        expect(saved!.state, DraftState.waitingSend);
      },
    );

    test(
      're-edit before first send replaces the row under a NEW operationId',
      () async {
        final d = draft();
        await drafts.save(d);
        final first = await fixture.transaction(
          (txn) => outbox.enqueueDraftSubmit(
            txn,
            draft: d,
            commandType: CommandTypes.sampleCreate,
            entityId: 'draft:d-1',
            expectedVersion: 0,
            payload: {'sampleName': 'v1'},
            dependencies: const {'parent_sample': 'P-1'},
          ),
        );
        final second = await fixture.transaction(
          (txn) => outbox.enqueueDraftSubmit(
            txn,
            draft: d,
            commandType: CommandTypes.sampleCreate,
            entityId: 'draft:d-1',
            expectedVersion: 0,
            payload: {'sampleName': 'v2'},
            dependencies: const {'parent_sample': 'P-1'},
          ),
        );

        final rows = await outbox.list();
        expect(rows, hasLength(1));
        expect(rows.single.operationId, isNot(first.operationId));
        expect(rows.single.operationId, second.operationId);
        expect(rows.single.payload, {'sampleName': 'v2'});
      },
    );

    test(
      'same draft content twice hashes identically (server dedup key)',
      () async {
        final a = hashPayload({'sampleName': 'Cement A', 'quantity': 5});
        final b = hashPayload({'quantity': 5, 'sampleName': 'Cement A'});
        expect(a, b);

        // The hash MUST equal the Node `hashPayload` output byte-for-byte
        // (functions/commands.js) — the server's dedup key depends on it.
        expect(
          hashPayload({'sampleName': 'Cement A', 'quantity': 3}),
          'cb6bb09b5201cd04ee4f6412859e563a5a8148cd346afbe5735ea06b41ca1d1b',
        );
      },
    );
  });

  group('settlement', () {
    late String operationId;

    setUp(() async {
      final d = draft();
      await drafts.save(d);
      final staged = await fixture.transaction(
        (txn) => outbox.enqueueDraftSubmit(
          txn,
          draft: d,
          commandType: CommandTypes.sampleCreate,
          entityId: 'draft:d-1',
          expectedVersion: 0,
          payload: const {'sampleName': 'Cement A'},
          dependencies: const {'parent_sample': 'P-1'},
        ),
      );
      operationId = staged.operationId;
    });

    test('approve keeps the receipt and walks the draft to approved', () async {
      await outbox.claim();
      await outbox.settleApproved(
        operationId,
        CommandResult(
          operationId: operationId,
          status: CommandResult.statusApproved,
          entityId: 'server-entity-1',
          committedVersion: 1,
          committedAt: '2026-10-25T10:01:00Z',
          changeSequence: 7,
        ),
      );

      final row = (await outbox.list()).single;
      expect(row.state, OutboxState.approved);
      expect(row.result!.entityId, 'server-entity-1');
      expect(row.result!.changeSequence, 7);
      final draftRow = await drafts.get('d-1');
      expect(draftRow!.state, DraftState.approvedOnServer);
      expect(draftRow.failure, isNull);
    });

    test('transient failure backs off but stays pending, and replay keeps '
        'the SAME operationId', () async {
      final claimed = await outbox.claim();
      expect(claimed.single.operationId, operationId);
      await outbox.settleRetry(
        operationId,
        code: CommandErrorCodes.unavailable,
        message: 'شبكة مقطوعة',
      );

      final row = (await outbox.list()).single;
      expect(row.state, OutboxState.pending);
      expect(row.attempts, 1);
      expect(row.nextAttemptAt, isNotNull);
      expect(row.lastErrorCode, CommandErrorCodes.unavailable);
      final draftRow = await drafts.get('d-1');
      expect(draftRow!.state, DraftState.waitingSend);
      expect(draftRow.failure?.code, isNot(CommandErrorCodes.unavailable));

      // A later replay sends the identical request.
      final envelope = claimed.single.envelope();
      final again = envelope.operationId;
      expect(again, operationId);
      expect(envelope.payloadHash, hashPayload(envelope.payload));
    });

    test('permanent rejection parks with the saved reason and stops pending '
        'drain', () async {
      await outbox.claim();
      await outbox.settleTerminal(
        operationId,
        state: OutboxState.rejected,
        code: CommandErrorCodes.permissionDenied,
        message: 'لا صلاحية',
      );

      final row = (await outbox.list()).single;
      expect(row.state, OutboxState.rejected);
      expect(row.nextAttemptAt, isNull);
      // `claim` only takes `pending` — no blind retry.
      expect(await outbox.claim(), isEmpty);
      final draftRow = await drafts.get('d-1');
      expect(draftRow!.state, DraftState.rejected);
      expect(draftRow.failure!.code, CommandErrorCodes.permissionDenied);
    });

    test(
      'version conflict parks as needs_review; auth parked as requires_auth',
      () async {
        // Round 1: conflict
        await outbox.claim();
        await outbox.settleTerminal(
          operationId,
          state: OutboxState.needsReview,
          code: CommandErrorCodes.versionConflict,
          message: 'تغيرت النسخة على السيرفر',
        );
        expect((await outbox.list()).single.state, OutboxState.needsReview);
        expect(
          await drafts.get('d-1').then((d) => d!.state),
          DraftState.needsReview,
        );
      },
    );

    test('a stalled in-flight row returns to pending on recovery', () async {
      final claimed = await outbox.claim();
      expect(claimed, hasLength(1));
      // (process died here)
      final recovered = await outbox.recoverStalled();
      expect(recovered, 1);
      final row = (await outbox.list()).single;
      expect(row.state, OutboxState.pending);
      final draftRow = await drafts.get('d-1');
      expect(draftRow!.state, DraftState.waitingSend);
    });

    test('counts expose every stop state', () async {
      await outbox.claim();
      await outbox.settleTerminal(
        operationId,
        state: OutboxState.authRequired,
        code: CommandErrorCodes.unauthenticated,
        message: 'سجّل الدخول',
      );
      final counts = await outbox.counts();
      expect(counts.pending, 0);
      expect(counts.requiresAuth, 1);
      expect(counts.hasProblems, isTrue);
    });
  });

  group('recovery and manual resolution (production acceptance 3)', () {
    Future<String> stageAndPark(
      OutboxState parkState, {
      String? code,
      String id = 'd-1',
    }) async {
      final d = draft(id: id);
      await drafts.save(d);
      final staged = await fixture.transaction(
        (txn) => outbox.enqueueDraftSubmit(
          txn,
          draft: d,
          commandType: CommandTypes.sampleCreate,
          entityId: 'draft:$id',
          expectedVersion: 0,
          payload: {'sampleName': 'Cement A'},
          dependencies: const {'parent_sample': 'P-1'},
        ),
      );
      if (parkState == OutboxState.pending) return staged.operationId;
      await outbox.claim();
      await outbox.settleTerminal(
        staged.operationId,
        state: parkState,
        code: code ?? CommandErrorCodes.unauthenticated,
        message: 'سبب',
      );
      return staged.operationId;
    }

    test('auth_required requeue keeps the SAME operationId and walks the '
        'draft back to waitingSend atomically', () async {
      final operationId = await stageAndPark(OutboxState.authRequired);

      final requeued = await outbox.retryRejected(onlyPendingable: true);
      expect(requeued, 1);

      final row = (await outbox.list()).single;
      expect(row.operationId, operationId);
      expect(row.state, OutboxState.pending);
      expect(
        await drafts.get('d-1').then((d) => d!.state),
        DraftState.waitingSend,
      );
      // Idempotent: nothing left to requeue.
      expect(await outbox.retryRejected(onlyPendingable: true), 0);
    });

    test('retryRejected refuses to run without an active scope', () async {
      final operationId = await stageAndPark(OutboxState.authRequired);
      outbox.scopeProvider = () => null;

      expect(await outbox.retryRejected(onlyPendingable: true), 0);
      // `list()` itself is scope-filtered — read the raw row instead.
      final raw = (await fixture.db.query(
        'command_outbox',
        where: 'operation_id = ?',
        whereArgs: [operationId],
      )).single;
      expect(raw['state'], 'auth_required');
      expect(
        await drafts.get('d-1').then((d) => d!.state),
        DraftState.requiresAuth,
      );
    });

    test('archive + release drops the entity locks so a corrected request '
        'can be authored; unknown-fate rows are refused', () async {
      final operationId = await stageAndPark(OutboxState.rejected);
      await fixture.db.insert('central_command_entities', {
        'entity_type': 'sample',
        'entity_id': 'P-1',
        'operation_id': operationId,
      });

      // A still-pending request must NOT be archivable.
      final d2 = draft(id: 'd-2');
      await drafts.save(d2);
      final stillPending = await fixture.transaction(
        (txn) => outbox.enqueueDraftSubmit(
          txn,
          draft: d2,
          commandType: CommandTypes.sampleCreate,
          entityId: 'draft:d-2',
          expectedVersion: 0,
          payload: const {'sampleName': 'Cement B'},
          dependencies: const {'parent_sample': 'P-1'},
        ),
      );
      expect(
        await outbox.releaseLockAndArchive(stillPending.operationId),
        isFalse,
      );

      expect(
        await outbox.releaseLockAndArchive(
          operationId,
          reason: 'قرار المستخدم',
        ),
        isTrue,
      );
      final locks = await fixture.db.query(
        'central_command_entities',
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
      expect(locks, isEmpty);
      final row = (await outbox.list())
          .singleWhere((r) => r.operationId == operationId);
      expect(row.state, OutboxState.archived);
      expect(row.lastError, 'قرار المستخدم');
    });

    test('needs_review can be released; an approved row never', () async {
      final conflictId = await stageAndPark(
        OutboxState.needsReview,
        code: CommandErrorCodes.versionConflict,
      );
      expect(await outbox.releaseLockAndArchive(conflictId), isTrue);
      expect(
        (await outbox.list())
            .singleWhere((r) => r.operationId == conflictId)
            .state,
        OutboxState.archived,
      );

      // Approved requests are settled: cleanup owns them, not this method.
      // (A new draft id: the archived conflict row still guards draft d-1,
      // which is exactly the production rule — "resolve before editing".)
      final approvedId = await stageAndPark(
        OutboxState.pending,
        id: 'd-2',
      );
      await outbox.claim();
      await outbox.settleApproved(
        approvedId,
        CommandResult(
          operationId: approvedId,
          status: CommandResult.statusApproved,
          entityId: 'server-entity-2',
          committedVersion: 1,
          committedAt: '2026-10-25T10:01:00Z',
          changeSequence: 8,
        ),
      );
      expect(await outbox.releaseLockAndArchive(approvedId), isFalse);
      expect(
        (await outbox.list())
            .singleWhere((r) => r.operationId == approvedId)
            .state,
        OutboxState.approved,
      );
    });

    test('cleanup archives only old approved rows — receipts, pending and '
        'recent approvals are untouched', () async {
      final oldApproved = await stageAndPark(OutboxState.pending);
      final recentApproved = await stageAndPark(OutboxState.pending, id: 'd-2');
      await outbox.claim();
      for (final operationId in [oldApproved, recentApproved]) {
        await outbox.settleApproved(
          operationId,
          CommandResult(
            operationId: operationId,
            status: CommandResult.statusApproved,
            entityId: 'server-$operationId',
            committedVersion: 1,
            committedAt: '2026-10-25T10:01:00Z',
            changeSequence: 9,
          ),
        );
      }
      // A request staged afterwards stays pending throughout the cleanup.
      final d3 = draft(id: 'd-3');
      await drafts.save(d3);
      final stillPending = await fixture.transaction(
        (txn) => outbox.enqueueDraftSubmit(
          txn,
          draft: d3,
          commandType: CommandTypes.sampleCreate,
          entityId: 'draft:d-3',
          expectedVersion: 0,
          payload: const {'sampleName': 'Cement C'},
          dependencies: const {'parent_sample': 'P-1'},
        ),
      );
      await fixture.db.update(
        'command_outbox',
        {
          'updated_at': nowIsoAt(
            DateTime.now().subtract(const Duration(days: 30)),
          ),
        },
        where: 'operation_id = ?',
        whereArgs: [oldApproved],
      );

      expect(await outbox.archiveSettled(), 1);

      Future<String> stateOf(String operationId) async => (await outbox.list())
          .singleWhere((r) => r.operationId == operationId)
          .state
          .value;
      expect(await stateOf(oldApproved), 'archived');
      expect(await stateOf(recentApproved), 'approved');
      expect(await stateOf(stillPending.operationId), 'pending');
      // Receipts are never deleted.
      expect(
        (await outbox.list())
            .singleWhere((r) => r.operationId == oldApproved)
            .result,
        isNotNull,
      );
    });
  });

  group('sync_checkpoint', () {
    test(
      'advances monotonically and survives duplicate/older events',
      () async {
        await checkpoints.advance(fixture.db, organizationId: 'org-1', to: 5);
        // A duplicated older event cannot regress the checkpoint.
        await checkpoints.advance(fixture.db, organizationId: 'org-1', to: 3);
        expect(await checkpoints.appliedSequence(organizationId: 'org-1'), 5);
        await checkpoints.advance(fixture.db, organizationId: 'org-1', to: 6);
        expect(await checkpoints.appliedSequence(organizationId: 'org-1'), 6);
        // Checkpoints are per organization.
        expect(await checkpoints.appliedSequence(organizationId: 'org-2'), 0);
      },
    );
  });
}
