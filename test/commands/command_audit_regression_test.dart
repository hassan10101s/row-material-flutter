import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/command_service.dart';
import 'package:material_lab/core/commands/command_transport.dart';
import 'package:material_lab/core/commands/command_worker.dart';
import 'package:material_lab/core/commands/drafts_store.dart';
import 'package:material_lab/core/commands/sync_checkpoint.dart';

import '../sync/sync_test_fixture.dart';

CommandDraft draft(String id, {String uid = 'u', String org = 'org'}) =>
    CommandDraft(
      id: id,
      organizationId: org,
      uid: uid,
      entityType: 'sample',
      operation: 'create',
      state: DraftState.localDraft,
      payload: const {'quantity': 3.0},
      createdAt: '',
      updatedAt: '',
    );
CommandResult approved(CommandEnvelope request) => CommandResult(
  operationId: request.operationId,
  entityId: request.entityId,
  status: 'approved',
  committedVersion: 1,
  changeSequence: 1,
  committedAt: '2026-10-25T00:00:00Z',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture fixture;
  late DraftsStore drafts;
  late CommandOutbox outbox;
  setUp(() async {
    fixture = await openSyncFixture();
    drafts = DraftsStore(fixture.helper);
    outbox = CommandOutbox(fixture.helper)..deviceProvider = () => 'device';
  });
  tearDown(() async => fixture.dispose());
  Future<CommandOutboxEntry> stage(String id, {String uid = 'u'}) async {
    final value = draft(id, uid: uid);
    await drafts.save(value);
    return fixture.transaction(
      (txn) => outbox.enqueueDraftSubmit(
        txn,
        draft: value,
        commandType: CommandTypes.sampleCreate,
        entityId: id,
        expectedVersion: 0,
        payload: value.payload,
        dependencies: const {},
      ),
    );
  }

  test(
    'Dart hashes match Node contract for decimals, numeric keys and Unicode',
    () {
      final vectors =
          jsonDecode(
                File(
                  'functions/test/fixtures/command_hash_vectors.json',
                ).readAsStringSync(),
              )
              as List;
      for (final vector in vectors) {
        expect(
          hashPayload(Map<String, dynamic>.from(vector['payload'] as Map)),
          vector['hash'],
          reason: vector['label'] as String,
        );
      }
      expect(hashPayload({'n': 1}), hashPayload({'n': 1.0}));
      expect(hashPayload({'n': -0.0}), hashPayload({'n': 0}));
      expect(() => hashPayload({'n': double.nan}), throwsFormatException);
    },
  );

  test(
    'a claimed draft cannot become a second operation after a lost response',
    () async {
      final entry = await stage('draft');
      await outbox.claim();
      final service = CommandService(
        dbHelper: fixture.helper,
        drafts: drafts,
        outbox: outbox,
        readModel: _NoParents(),
      );
      await expectLater(service.submitDraft(draft('draft')), throwsStateError);
      await expectLater(drafts.save(draft('draft')), throwsStateError);
      final rows = await outbox.list();
      expect(rows, hasLength(1));
      expect(rows.single.operationId, entry.operationId);
      expect(rows.single.attempts, 1);
    },
  );

  test('local relation rejection cannot replace a submitted draft', () async {
    await stage('draft');
    await outbox.claim();
    final service = CommandService(
      dbHelper: fixture.helper,
      drafts: drafts,
      outbox: outbox,
      readModel: _NoParents(),
    );
    final value = CommandDraft(
      id: 'draft',
      organizationId: 'org',
      uid: 'u',
      entityType: 'sample',
      operation: 'create',
      parentEntityType: 'sample',
      parentEntityId: 'missing',
      state: DraftState.localDraft,
      payload: const {'quantity': 99},
      createdAt: '',
      updatedAt: '',
    );
    await expectLater(service.submitDraft(value), throwsStateError);
    expect((await drafts.get('draft'))!.payload['quantity'], 3);
  });

  test(
    'active account can neither claim nor list another account queue',
    () async {
      await stage('a');
      await stage('b', uid: 'other');
      outbox.scopeProvider = () => const CommandScope('org', 'u', 'device');
      drafts.scopeProvider = () => const CommandScope('org', 'u', 'device');
      expect((await outbox.list()).map((row) => row.draftId), ['a']);
      expect((await outbox.claim()).map((row) => row.draftId), ['a']);
      expect(await drafts.get('b'), isNull);
      expect((await drafts.listOpen()).map((row) => row.id), ['a']);
      outbox.scopeProvider = () => null;
      expect(await outbox.claim(), isEmpty);
    },
  );

  test('late terminal failure cannot change an approved draft state', () async {
    final entry = await stage('draft');
    await outbox.claim();
    await outbox.settleApproved(entry.operationId, approved(entry.envelope()));
    await outbox.settleTerminal(
      entry.operationId,
      state: OutboxState.rejected,
      code: 'PERMISSION_DENIED',
      message: 'late',
    );
    expect((await drafts.get('draft'))!.state, DraftState.approvedOnServer);
    expect((await outbox.list()).single.state, OutboxState.approved);
  });

  test(
    'an approved receipt wins over an earlier auth rejection for the same immutable operation',
    () async {
      final entry = await stage('draft');
      await outbox.claim();
      await outbox.settleTerminal(
        entry.operationId,
        state: OutboxState.authRequired,
        code: 'UNAUTHENTICATED',
        message: 'stale',
      );
      await outbox.settleApproved(
        entry.operationId,
        approved(entry.envelope()),
      );
      expect((await drafts.get('draft'))!.state, DraftState.approvedOnServer);
    },
  );

  test(
    'two workers cannot recover and resend each other active claims',
    () async {
      await stage('draft');
      final transport = _WaitingTransport();
      final first = CommandWorker(outbox: outbox, transport: transport);
      final second = CommandWorker(
        outbox: CommandOutbox(fixture.helper),
        transport: transport,
      );
      final running = first.runOnce();
      await transport.started.future;
      expect((await second.runOnce()).sent, 0);
      expect(transport.calls, 1);
      transport.answer.complete(approved(transport.request!));
      expect((await running).approved, 1);
    },
  );

  test(
    'checkpoint returns the persisted high-water mark, not an older input',
    () async {
      final checkpoints = SyncCheckpoints(fixture.helper);
      await checkpoints.advance(fixture.db, organizationId: 'org', to: 8);
      expect(
        await checkpoints.advance(fixture.db, organizationId: 'org', to: 3),
        8,
      );
      expect(
        () => checkpoints.advance(fixture.db, organizationId: 'org', to: -1),
        throwsArgumentError,
      );
    },
  );

  test(
    'wire schema is the persisted schema, never relabeled by an upgrade',
    () async {
      await stage('draft');
      await fixture.db.update('command_outbox', {'schema_version': 1});
      expect((await outbox.list()).single.envelope().schemaVersion, 1);
    },
  );

  test(
    'Windows REST sends callable envelope and parses an authoritative receipt',
    () async {
      final entry = await stage('draft');
      final request = entry.envelope();
      final transport = CloudFunctionsCommandTransport(
        useRest: true,
        projectId: 'demo-materiallab',
        tokenProvider: () async => 'test-token',
        client: MockClient((wire) async {
          expect(wire.url.scheme, 'https');
          expect(wire.headers['Authorization'], 'Bearer test-token');
          expect(jsonDecode(wire.body), {'data': request.toWire()});
          return http.Response(
            jsonEncode({'result': approved(request).toJson()}),
            200,
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      expect((await transport.submit(request)).isApproved, isTrue);
    },
  );

  test('Windows REST preserves stable business failure codes', () async {
    final entry = await stage('draft');
    final transport = CloudFunctionsCommandTransport(
      useRest: true,
      projectId: 'demo-materiallab',
      tokenProvider: () async => 'test-token',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': {
              'status': 'FAILED_PRECONDITION',
              'message': 'review',
              'details': {
                'code': 'VERSION_CONFLICT',
                'messageAr': 'راجع التعديل',
              },
            },
          }),
          400,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    expect(
      (await transport.submit(entry.envelope())).failure!.code,
      CommandErrorCodes.versionConflict,
    );
  });
  test(
    'an unrelated approved receipt never approves the queued operation',
    () async {
      final entry = await stage('draft');
      await outbox.claim();
      final worker = CommandWorker(
        outbox: outbox,
        transport: _WaitingTransport(),
      );
      final response = CommandResult(
        operationId: 'different-operation',
        entityId: entry.entityId,
        status: 'approved',
        committedVersion: 1,
        changeSequence: 1,
        committedAt: '2026-10-25T00:00:00Z',
      );
      expect(await worker.settle(entry, response), Answer.retry);
      expect((await drafts.get('draft'))!.state, DraftState.waitingSend);
    },
  );

  test('stalled recovery does not change a different device draft', () async {
    await stage('current');
    await stage('other');
    await outbox.claim();
    await fixture.db.update(
      'command_outbox',
      {'device_id': 'other-device'},
      where: 'draft_id = ?',
      whereArgs: ['other'],
    );
    outbox.scopeProvider = () => const CommandScope('org', 'u', 'device');
    expect(await outbox.recoverStalled(), 1);
    expect((await drafts.get('current'))!.state, DraftState.waitingSend);
    expect((await drafts.get('other'))!.state, DraftState.sending);
  });

  test(
    'scheduler failure after commit cannot turn a staged save into a failed save',
    () async {
      final service = CommandService(
        dbHelper: fixture.helper,
        drafts: drafts,
        outbox: outbox,
        readModel: _NoParents(),
        onDrainRequested: () {
          throw StateError('scheduler unavailable');
        },
      );
      final result = await service.submitDraft(draft('draft'));
      expect(result.staged, isTrue);
      expect((await outbox.list()).single.operationId, result.operationId);
    },
  );
}

class _NoParents implements CommandReadModel {
  @override
  Future<({Map<String, dynamic> row, bool deleted, int version})?>
  readApprovedEntity({
    required String organizationId,
    required String entityType,
    required String entityId,
  }) async => null;
}

class _WaitingTransport implements CommandTransport {
  final started = Completer<void>();
  final answer = Completer<CommandResult>();
  int calls = 0;
  CommandEnvelope? request;
  @override
  Future<CommandResult> submit(CommandEnvelope value) {
    calls++;
    request = value;
    if (!started.isCompleted) started.complete();
    return answer.future;
  }
}
