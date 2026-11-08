import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/command_transport.dart';
import 'package:material_lab/core/commands/direct_write_service.dart';
import 'package:material_lab/core/commands/drafts_store.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import '../sync/sync_test_fixture.dart';

class _Transport implements CommandTransport, CommandReceiptReader {
  final sent = <CommandEnvelope>[];
  final receipts = <String, CommandResult>{};
  int reads = 0;
  bool loseReply = false;
  String? refusal;
  Completer<void>? pause;
  @override
  Future<CommandResult> submit(CommandEnvelope envelope) async {
    sent.add(envelope);
    await pause?.future;
    if (refusal != null) {
      return CommandResult.retryable(envelope.operationId, refusal!, 'Refused');
    }
    final result = receipts.putIfAbsent(
      envelope.operationId,
      () => CommandResult(
        operationId: envelope.operationId,
        status: CommandResult.statusApproved,
        entityId: envelope.entityId,
        committedVersion: 1,
        committedAt: '2026-11-01T12:00:00Z',
        changeSequence: 5,
      ),
    );
    if (loseReply) throw StateError('reply lost after commit');
    return result;
  }

  @override
  Future<CommandResult?> lookupReceipt(CommandEnvelope envelope) async {
    reads++;
    return receipts[envelope.operationId];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture fixture;
  late CommandOutbox outbox;
  late DraftsStore drafts;
  late _Transport transport;
  late DirectWriteService service;
  var online = true;
  var applied = 0;
  var manualRequests = 0;
  CommandScope? scope;
  setUp(() async {
    fixture = await openSyncFixture();
    scope = const CommandScope('org-1', 'uid-1', 'dev-1');
    outbox = CommandOutbox(fixture.helper)
      ..deviceProvider = (() => 'dev-1')
      ..scopeProvider = () => scope;
    drafts = DraftsStore(fixture.helper);
    transport = _Transport();
    online = true;
    applied = 0;
    manualRequests = 0;
    service = DirectWriteService(
      outbox: outbox,
      transport: transport,
      isOnline: () => online,
      synchronize: (seq) async {
        applied = seq;
        return seq;
      },
      waitBudget: const Duration(seconds: 2),
      onManualRequest: () => manualRequests++,
    );
  });
  tearDown(() async => fixture.dispose());

  Future<CommandOutboxEntry> stage(String id) async {
    final draft = CommandDraft(
      id: id,
      organizationId: 'org-1',
      uid: 'uid-1',
      entityType: 'sample',
      operation: 'create',
      entityId: '',
      parentEntityType: '',
      parentEntityId: '',
      baseVersion: 0,
      payload: {'sampleName': id},
      state: DraftState.localDraft,
      createdAt: '2026-10-25 10:00:00',
      updatedAt: '2026-10-25 10:00:00',
    );
    await drafts.save(draft);
    return fixture.transaction(
      (txn) => outbox.enqueueDraftSubmit(
        txn,
        draft: draft,
        commandType: CommandTypes.sampleCreate,
        entityId: 'draft:$id',
        expectedVersion: 0,
        payload: draft.payload,
        dependencies: const {},
      ),
    );
  }

  test(
    'automatic receipt recovery never resumes quota; explicit verification does',
    () async {
      final entry = await stage('quota');
      transport.loseReply = true;
      await service.submitAndWait(entry);
      expect(manualRequests, 1);
      service.onOutcome = (_, _) async => true;
      await service.checkOutcomes();
      await service.recover();
      expect(manualRequests, 1);
      expect(transport.sent, hasLength(1));
      expect(await service.verify(entry), isTrue);
      expect(manualRequests, 2);
      expect(transport.sent, hasLength(1));
    },
  );

  test(
    'manual retry resumes quota before looking for a lost receipt',
    () async {
      final entry = await stage('quota-retry');
      transport.loseReply = true;
      await service.submitAndWait(entry);
      expect(await service.retry(entry), isTrue);
      expect(manualRequests, 2);
      expect(
        transport.sent,
        hasLength(1),
        reason: 'The receipt prevents a second send',
      );
      expect(
        (await outbox.getByOperationId(entry.operationId))!.operationId,
        entry.operationId,
      );
    },
  );

  test(
    'offline or foreign requests cannot resume the shared quota gate',
    () async {
      final entry = await stage('quota-foreign');
      online = false;
      expect(await service.submitAndWait(entry), isFalse);
      expect(await service.verify(entry), isFalse);
      await expectLater(service.retry(entry), throwsA(isA<ValidationError>()));
      online = true;
      scope = const CommandScope('other-org', 'other-user', 'other-device');
      await expectLater(
        service.submitAndWait(entry),
        throwsA(isA<AuthorizationError>()),
      );
      expect(await service.verify(entry), isFalse);
      await expectLater(
        service.retry(entry),
        throwsA(isA<AuthorizationError>()),
      );
      expect(manualRequests, 0);
      expect(transport.sent, isEmpty);
    },
  );

  test(
    'explicit save sends only its selected operation then applies receipt',
    () async {
      final a = await stage('a');
      await stage('b');
      expect(await service.submitAndWait(a), isTrue);
      expect(transport.sent.map((e) => e.operationId), [a.operationId]);
      expect(applied, 5);
      expect((await outbox.list()).where((e) => e.attempts == 0), hasLength(1));
    },
  );
  test(
    'removing an uncertain event deletes only its draft and preserves receipt recovery',
    () async {
      final a = await stage('a');
      await fixture.db.insert('central_command_entities', {
        'entity_type': 'sample',
        'entity_id': 'protected-row',
        'operation_id': a.operationId,
      });
      transport.loseReply = true;
      await service.submitAndWait(a);
      final pending = (await outbox.getByOperationId(a.operationId))!;
      online = false;
      await service.dismissRequest(pending);
      await service.dismissRequest(pending);
      expect(await drafts.get('a'), isNull);
      expect(await service.openRequests(), isEmpty);
      expect(await service.openRequests(includeDismissed: true), hasLength(1));
      final saved = (await outbox.getByOperationId(a.operationId))!;
      expect(saved.state, pending.state);
      expect(saved.payloadHash, a.payloadHash);
      expect(saved.payload, a.payload);
      expect(await fixture.db.query('central_command_entities'), hasLength(1));
      // Recovery still discovers a commit whose response was lost, without a
      // second write, even though the user removed its draft from the list.
      online = true;
      await service.recover();
      expect(
        (await outbox.getByOperationId(a.operationId))!.state,
        OutboxState.approved,
      );
      expect(transport.sent, hasLength(1));
      expect(applied, 5);
    },
  );

  test('event removal refuses another owner and an unsent operation', () async {
    final a = await stage('a');
    await expectLater(
      service.dismissRequest(a),
      throwsA(isA<ValidationError>()),
    );
    scope = const CommandScope('another-org', 'another-user', 'dev-1');
    await expectLater(
      service.dismissRequest(a),
      throwsA(isA<AuthorizationError>()),
    );
    scope = const CommandScope('org-1', 'uid-1', 'dev-1');
    expect(await drafts.get('a'), isNotNull);
    expect(await fixture.db.query('dismissed_command_requests'), isEmpty);
    expect(transport.sent, isEmpty);
  });

  test(
    'monitor follows a lost reply after navigation and acknowledges success only once across restart',
    () async {
      final a = await stage('a');
      transport.loseReply = true;
      await service.submitAndWait(a);
      final seen = <String>[];
      service.onOutcome = (entry, approved) async {
        expect(applied, 5);
        expect(approved, isTrue);
        seen.add(entry.operationId);
        return true;
      };
      await service.checkOutcomes();
      await service.checkOutcomes();
      final restarted = DirectWriteService(
        outbox: outbox,
        transport: transport,
        isOnline: () => online,
        synchronize: (seq) async => seq,
      )..onOutcome = service.onOutcome;
      await restarted.checkOutcomes();
      expect(seen, [a.operationId]);
      expect(transport.sent, hasLength(1));
    },
  );

  test(
    'monitor does not announce success until receipt projection succeeds',
    () async {
      final a = await stage('a');
      transport.loseReply = true;
      await service.submitAndWait(a);
      var ready = false;
      var notices = 0;
      final monitor =
          DirectWriteService(
              outbox: outbox,
              transport: transport,
              isOnline: () => online,
              synchronize: (seq) async => ready ? seq : 0,
            )
            ..onOutcome = (entry, approved) async {
              notices++;
              return true;
            };
      await monitor.checkOutcomes();
      expect(notices, 0);
      ready = true;
      await monitor.checkOutcomes();
      expect(notices, 1);
      expect(transport.sent, hasLength(1));
    },
  );

  test(
    'monitor reports a definitive refusal and does not turn uncertainty into a failure',
    () async {
      final a = await stage('a');
      transport.refusal = CommandErrorCodes.unavailable;
      await service.submitAndWait(a);
      final outcomes = <bool>[];
      service.onOutcome = (entry, approved) async {
        outcomes.add(approved);
        return true;
      };
      await service.checkOutcomes();
      expect(outcomes, isEmpty);
      final refused = await stage('refused');
      transport.refusal = CommandErrorCodes.badPayload;
      await expectLater(
        service.submitAndWait(refused),
        throwsA(isA<ValidationError>()),
      );
      await service.checkOutcomes();
      expect(outcomes, [false]);
      expect(transport.sent, hasLength(2));
    },
  );

  test('offline and reconnect never submit old queued work', () async {
    final a = await stage('a');
    online = false;
    expect(await service.submitAndWait(a), isFalse);
    await service.recover();
    online = true;
    await service.recover(migrateUnsent: true);
    expect(transport.sent, isEmpty);
    expect((await drafts.get('a'))!.state, DraftState.localDraft);
    expect(
      (await outbox.getByOperationId(a.operationId))!.state,
      OutboxState.archived,
    );
  });
  test(
    'lost reply recovers by GET receipt without repeating a write',
    () async {
      final a = await stage('a');
      transport.loseReply = true;
      expect(await service.submitAndWait(a), isFalse);
      online = false;
      await service.recover();
      online = true;
      await service.recover();
      expect(transport.sent, hasLength(1));
      expect(transport.reads, 1);
      expect(
        (await outbox.getByOperationId(a.operationId))!.state,
        OutboxState.approved,
      );
      expect(applied, 5);
    },
  );
  test(
    'missing receipt never replays automatically; manual retry keeps identity',
    () async {
      final a = await stage('a');
      transport.loseReply = true;
      await service.submitAndWait(a);
      transport.receipts.clear();
      await service.recover();
      await service.recover();
      expect(transport.sent, hasLength(1));
      transport.loseReply = false;
      expect(await service.retry(a), isTrue);
      expect(transport.sent, hasLength(2));
      expect(transport.sent.map((e) => e.operationId).toSet(), {a.operationId});
      expect(transport.sent.map((e) => e.payloadHash).toSet(), hasLength(1));
    },
  );
  test(
    'slow response releases UI wait without allowing parallel retry',
    () async {
      final a = await stage('a');
      transport.pause = Completer<void>();
      service = DirectWriteService(
        outbox: outbox,
        transport: transport,
        isOnline: () => online,
        synchronize: (seq) async => seq,
        waitBudget: const Duration(milliseconds: 80),
      );
      expect(await service.submitAndWait(a), isFalse);
      expect(service.isSending(a.operationId), isTrue);
      expect(await service.retry(a), isFalse);
      await service.recover();
      expect(transport.sent, hasLength(1));
      transport.pause!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(await service.verify(a), isTrue);
      expect(transport.sent, hasLength(1));
    },
  );
  test('scope switch cannot send or read another accounts receipt', () async {
    final a = await stage('a');
    scope = const CommandScope('another-org', 'another-user', 'dev-1');
    await service.recover(migrateUnsent: true);
    expect(await service.verify(a), isFalse);
    expect(transport.sent, isEmpty);
    expect(transport.reads, 0);
  });

  Future<void> lock(CommandOutboxEntry entry, String entity) => fixture.db
      .insert('central_command_entities', {
        'entity_type': 'sample',
        'entity_id': entity,
        'operation_id': entry.operationId,
      })
      .then((_) {});

  test(
    'definitive refusal releases every affected record and preserves evidence',
    () async {
      final entry = await stage('refused');
      await lock(entry, 'sample-a');
      await lock(entry, 'sample-b');
      transport.refusal = CommandErrorCodes.permissionDenied;
      await expectLater(
        service.submitAndWait(entry),
        throwsA(isA<Exception>()),
      );
      expect(await fixture.db.query('central_command_entities'), isEmpty);
      final stored = (await outbox.getByOperationId(entry.operationId))!;
      expect(stored.state, OutboxState.rejected);
      expect(stored.result?.failure?.code, CommandErrorCodes.permissionDenied);
      expect((await drafts.get(entry.draftId))!.state, DraftState.rejected);
      await service.recover();
      expect(transport.sent, hasLength(1));
      expect(
        transport.reads,
        0,
        reason: 'A settled refusal without locks needs no remote reads',
      );
    },
  );

  test(
    'restart repairs old refusal locks while preserving unresolved writes',
    () async {
      final rejected = await stage('old-refusal');
      final pending = await stage('unknown');
      final approved = await stage('not-projected');
      for (final entry in [rejected, pending, approved]) {
        await lock(entry, entry.draftId);
      }
      await fixture.db.update(
        'command_outbox',
        {
          'state': 'rejected',
          'attempts': 1,
          'last_error_code': CommandErrorCodes.permissionDenied,
        },
        where: 'operation_id = ?',
        whereArgs: [rejected.operationId],
      );
      await fixture.db.update(
        'command_outbox',
        {'attempts': 1},
        where: 'operation_id = ?',
        whereArgs: [pending.operationId],
      );
      await fixture.db.update(
        'command_outbox',
        {'state': 'approved', 'attempts': 1},
        where: 'operation_id = ?',
        whereArgs: [approved.operationId],
      );
      online = false;
      await service.recover();
      expect(await fixture.db.query('central_command_entities'), hasLength(3));
      online = true;
      await service.recover();
      expect(
        (await fixture.db.query(
          'central_command_entities',
        )).map((r) => r['operation_id']).toSet(),
        {pending.operationId, approved.operationId},
      );
      expect(transport.sent, isEmpty);
      expect(
        (await outbox.getByOperationId(rejected.operationId))!.lastErrorCode,
        CommandErrorCodes.permissionDenied,
      );
    },
  );

  test('a refused retry cannot unlock an earlier uncertain attempt', () async {
    final entry = await stage('uncertain');
    await lock(entry, 'sample-a');
    transport.loseReply = true;
    expect(await service.submitAndWait(entry), isFalse);
    transport.receipts.clear();
    transport.loseReply = false;
    transport.refusal = CommandErrorCodes.permissionDenied;
    expect(await service.retry(entry), isFalse);
    expect(await fixture.db.query('central_command_entities'), hasLength(1));
    expect(
      (await outbox.getByOperationId(entry.operationId))!.state,
      OutboxState.pending,
    );
  });
}
