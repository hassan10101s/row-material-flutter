import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/command_transport.dart';
import 'package:material_lab/core/commands/command_worker.dart';
import 'package:material_lab/core/commands/drafts_store.dart';

import '../sync/sync_test_fixture.dart';

/// Worker invariants from the failure matrix (plan §12): one operation, one
/// effect — with transport crashes, permanent denials, conflicts and offline
/// gating, all against the real outbox store.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncFixture fixture;
  late DraftsStore drafts;
  late CommandOutbox outbox;
  late FakeTransport transport;
  late CommandWorker worker;

  setUp(() async {
    fixture = await openSyncFixture();
    drafts = DraftsStore(fixture.helper);
    outbox = CommandOutbox(fixture.helper)..deviceProvider = () => 'dev-1';
    transport = FakeTransport();
    worker = CommandWorker(outbox: outbox, transport: transport);
  });

  tearDown(() async => fixture.dispose());

  Future<String> stageDraft({
    String draftId = 'd-1',
    Map<String, dynamic> payload = const {'sampleName': 'Cement A'},
    String operation = 'create',
    String entityId = 'draft:d-1',
    int expectedVersion = 0,
  }) async {
    final newDraft = CommandDraft(
      id: draftId,
      organizationId: 'org-1',
      uid: 'uid-1',
      entityType: 'sample',
      operation: operation,
      entityId: operation == 'create' ? '' : entityId,
      parentEntityType: '',
      parentEntityId: '',
      baseVersion: expectedVersion,
      payload: payload,
      state: DraftState.localDraft,
      createdAt: '2026-10-25 10:00:00',
      updatedAt: '2026-10-25 10:00:00',
    );
    await drafts.save(newDraft);
    final entry = await fixture.transaction((txn) {
      return outbox.enqueueDraftSubmit(
        txn,
        draft: newDraft,
        commandType: operation == 'create'
            ? CommandTypes.sampleCreate
            : CommandTypes.sampleUpdate,
        entityId: entityId,
        expectedVersion: expectedVersion,
        payload: payload,
        dependencies: const {},
      );
    });
    return entry.operationId;
  }

  /// Force the backoff clock open so the next cycle claims again.
  Future<void> openBackoffWindow() async {
    await fixture.db.rawUpdate(
      "UPDATE command_outbox SET next_attempt_at = NULL "
      "WHERE state = 'pending'",
    );
  }

  group('send loop', () {
    test('transport outage: the SAME operationId+hash is re-sent, then the '
        'single receipt approves once', () async {
      final operationId = await stageDraft();
      transport.scripts = [
        Script.throw_({'message': 'socket closed'}), // attempt 1 fails
        Script.throw_({'message': 'timeout'}), // attempt 2 fails
        Script.approved(entityId: 'draft:d-1', version: 1, seq: 3),
      ];

      final first = await worker.runOnce();
      expect(first.retried, 1);
      await openBackoffWindow();
      final second = await worker.runOnce();
      expect(second.retried, 1);
      await openBackoffWindow();
      final third = await worker.runOnce();
      expect(third.approved, 1);

      // Every attempt carried the same fixed request.
      expect(transport.requests, hasLength(3));
      final operationIds = transport.requests.map((r) => r.operationId).toSet();
      expect(operationIds, {operationId});
      final hashes = transport.requests.map((r) => r.payloadHash).toSet();
      expect(hashes, hasLength(1));
      expect(transport.requests.first.operationId, operationId);

      // Approved once; the row leaves the pending pool — no further sends.
      final after = await worker.runOnce();
      expect(after.sent, 0);
      expect(transport.requests, hasLength(3));
      final row = (await outbox.list()).single;
      expect(row.state, OutboxState.approved);
      expect(row.result!.entityId, 'draft:d-1');
      expect(row.result!.changeSequence, 3);
      expect((await drafts.get('d-1'))!.state, DraftState.approvedOnServer);
    });

    test('PERMISSION_DENIED parks forever with the saved reason (no blind '
        'retry)', () async {
      await stageDraft();
      transport.scripts = [
        Script.rejected(
          code: CommandErrorCodes.permissionDenied,
          message: 'لا تمتلك صلاحية',
        ),
      ];

      final report = await worker.runOnce();
      expect(report.parked, 1);
      expect(await outbox.claim(), isEmpty);
      // A later cycle makes NO further transport call.
      final later = await worker.runOnce();
      expect(later.sent, 0);
      expect(transport.requests, hasLength(1));
      final row = (await outbox.list()).single;
      expect(row.state, OutboxState.rejected);
      expect(row.lastErrorCode, CommandErrorCodes.permissionDenied);
      expect((await drafts.get('d-1'))!.state, DraftState.rejected);
    });

    test('UNAUTHENTICATED parks as auth_required; VERSION_CONFLICT as '
        'needs_review', () async {
      final first = await stageDraft(draftId: 'd-1');
      transport.scripts = [
        Script.rejected(
          code: CommandErrorCodes.unauthenticated,
          message: 'سجّل الدخول',
        ),
      ];
      await worker.runOnce();
      expect((await outbox.list()).first.state, OutboxState.authRequired);
      expect((await drafts.get('d-1'))!.state, DraftState.requiresAuth);

      // Second draft hits a conflict: server version moved — review, never
      // a silent overwrite (§7).
      final second = await stageDraft(
        draftId: 'd-2',
        operation: 'update',
        entityId: 'srv-9',
        expectedVersion: 4,
        payload: {'sampleName': 'edited'},
      );
      transport.scripts = [
        Script.rejected(
          code: CommandErrorCodes.versionConflict,
          message: 'تغيرت النسخة على السيرفر',
          currentVersion: 6,
        ),
      ];
      await worker.runOnce();
      final row = (await outbox.list()).firstWhere(
        (r) => r.operationId == second,
      );
      expect(row.state, OutboxState.needsReview);
      expect((await drafts.get('d-2'))!.state, DraftState.needsReview);
      expect(first, isNot(second));
    });

    test('canSend=false claims back without touching the transport', () async {
      await stageDraft();
      worker.canSend = () => false;

      final report = await worker.runOnce();
      expect(transport.requests, isEmpty);
      expect(report.skippedOffline, 1);
      final row = (await outbox.list()).single;
      expect(row.state, OutboxState.pending);
      expect((await drafts.get('d-1'))!.state, DraftState.waitingSend);
    });

    test(
      'crash mid-send recovers on the next start and still approves once',
      () async {
        final operationId = await stageDraft();
        transport.scripts = [
          // First "process": claim happens, then a crash before the answer.
          Script.approved(entityId: 'draft:d-1', version: 1, seq: 9),
        ];
        final claimed = await outbox.claim();
        expect(claimed.single.operationId, operationId);
        // In-flight, then death. The SWEEP of the next process recovers it.
        final report = await worker.runOnce();
        expect(report.approved, 1);
        expect(transport.requests, hasLength(1));
        final row = (await outbox.list()).single;
        expect(row.state, OutboxState.approved);
        expect(row.result!.changeSequence, 9);
        // exactly one pending source remains: zero.
        expect(await outbox.claim(), isEmpty);
      },
    );
  });
}

/// Scripted transport double: decodes exactly like the real one's outcomes.
class Script {
  const Script.approved({
    required this.entityId,
    required this.version,
    required this.seq,
  }) : kind = _approve,
       code = null,
       message = null,
       throwLog = null,
       currentVersion = null;

  const Script.rejected({
    required this.code,
    required this.message,
    this.currentVersion,
  }) : kind = _reject,
       entityId = '',
       version = null,
       seq = null,
       throwLog = null;

  // Named factory instead of a const named "throw" (reserved word).
  Script.throw_(Object error)
    : kind = _throwing,
      code = null,
      message = null,
      entityId = '',
      version = null,
      seq = null,
      throwLog = error,
      currentVersion = null;

  static const String _approve = 'approve';
  static const String _reject = 'reject';
  static const String _throwing = 'throw';

  final String kind;
  final String? code;
  final String? message;
  final String? entityId;
  final int? version;
  final int? seq;
  final Object? throwLog;
  final int? currentVersion;
}

class FakeTransport implements CommandTransport {
  final List<CommandEnvelope> requests = [];
  List<Script> scripts = [];
  int _next = 0;

  @override
  Future<CommandResult> submit(CommandEnvelope envelope) async {
    requests.add(envelope);
    final script = scripts[_next.clamp(0, scripts.length - 1)];
    if (scripts.isNotEmpty && _next < scripts.length) _next++;
    if (script.kind == Script._throwing) throw script.throwLog!;
    if (script.kind == Script._reject) {
      return CommandResult(
        operationId: envelope.operationId,
        status: CommandResult.statusRejected,
        entityId: envelope.entityId,
        failure: CommandFailure(code: script.code!, messageAr: script.message!),
      );
    }
    return CommandResult(
      operationId: envelope.operationId,
      status: CommandResult.statusApproved,
      entityId: script.entityId!,
      committedVersion: script.version,
      committedAt: '2026-10-25T10:05:00Z',
      changeSequence: script.seq,
    );
  }
}
