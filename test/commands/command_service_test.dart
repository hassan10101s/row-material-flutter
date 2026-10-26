import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/command_service.dart';
import 'package:material_lab/core/commands/drafts_store.dart';

import '../sync/sync_test_fixture.dart';

/// CommandService gates (plan §5/§7): the relationship check runs BEFORE
/// staging, refusals park the draft without touching the outbox, and the
/// one-transaction draft+outbox stage never half-fails.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncFixture fixture;
  late DraftsStore drafts;
  late CommandOutbox outbox;
  late FakeReadModel readModel;
  late CommandService service;

  setUp(() async {
    fixture = await openSyncFixture();
    drafts = DraftsStore(fixture.helper);
    outbox = CommandOutbox(fixture.helper)..deviceProvider = () => 'dev-1';
    readModel = FakeReadModel();
    service = CommandService(
      dbHelper: fixture.helper,
      drafts: drafts,
      outbox: outbox,
      readModel: readModel,
    );
  });

  tearDown(() async => fixture.dispose());

  CommandDraft createDraft({String parentEntityId = 'P-1'}) => CommandDraft(
    id: 'd-1',
    organizationId: 'org-1',
    uid: 'uid-1',
    entityType: 'sample',
    operation: 'create',
    parentEntityType: parentEntityId.isEmpty ? '' : 'sample',
    parentEntityId: parentEntityId,
    payload: {'sampleName': 'Cement A'},
    state: DraftState.localDraft,
    createdAt: '',
    updatedAt: '',
  );

  test('valid create stages draft + outbox in one transaction', () async {
    readModel.rows['sample:P-1'] = (
      row: {'id': 7, 'remote_id': 'P-1'},
      deleted: false,
      version: 2,
    );
    final outcome = await service.submitDraft(createDraft(parentEntityId: ''));

    expect(outcome.staged, isTrue);
    final saved = await drafts.get('d-1');
    expect(saved!.state, DraftState.waitingSend);
    final row = (await outbox.list()).single;
    expect(row.operationId, outcome.operationId);
    expect(row.commandType, CommandTypes.sampleCreate);
    expect(row.dependencies, isEmpty);
  });

  test(
    'a missing locally-known parent parks the draft WITHOUT staging',
    () async {
      // no parent in the read model at all
      final outcome = await service.submitDraft(createDraft());

      expect(outcome.staged, isFalse);
      expect(outcome.failure!.code, CommandErrorCodes.parentMissingOrDeleted);
      final saved = await drafts.get('d-1');
      expect(saved!.state, DraftState.needsReview);
      expect(saved.failure, isNotNull);
      expect(await outbox.list(), isEmpty);
    },
  );

  test('a deleted parent parks with the deleted reason; the outbox stays '
      'empty', () async {
    readModel.rows['sample:P-1'] = (
      row: {'id': 7, 'remote_id': 'P-1', 'deleted_at': '2026-10-01'},
      deleted: true,
      version: 4,
    );
    final outcome = await service.submitDraft(createDraft());

    expect(outcome.staged, isFalse);
    expect(outcome.failure!.code, CommandErrorCodes.parentDeletedCannotLink);
    final saved = await drafts.get('d-1');
    expect(saved!.state, DraftState.needsReview);
    expect(await outbox.list(), isEmpty);
  });

  test('unknown operation parks as bad payload', () async {
    final outcome = await service.submitDraft(
      CommandDraft(
        id: 'd-2',
        organizationId: 'org-1',
        uid: 'uid-1',
        entityType: 'sample',
        operation: 'frobnicate',
        entityId: '',
        payload: const {},
        state: DraftState.localDraft,
        createdAt: '',
        updatedAt: '',
      ),
    );
    expect(outcome.staged, isFalse);
    expect(outcome.failure!.code, CommandErrorCodes.badPayload);
    expect(await outbox.list(), isEmpty);
  });

  test('update without a global entity id refuses before the wire', () async {
    final outcome = await service.submitDraft(
      CommandDraft(
        id: 'd-3',
        organizationId: 'org-1',
        uid: 'uid-1',
        entityType: 'sample',
        operation: 'update',
        entityId: '', // no global id — SQLite numbering is NOT allowed
        payload: const {'sampleName': 'edited'},
        state: DraftState.localDraft,
        createdAt: '',
        updatedAt: '',
      ),
    );
    expect(outcome.staged, isFalse);
    expect(outcome.failure!.code, CommandErrorCodes.badPayload);
    expect(await outbox.list(), isEmpty);
  });

  test(
    're-submitting an approved draft is a no-op (no second effect)',
    () async {
      final approved =
          (await (drafts.get('d-1'))) ??
          createDraft().copyForTest(
            state: DraftState.approvedOnServer,
            entityId: 'srv-1',
          );
      await fixture.db.insert('drafts', approved.toRow());

      final outcome = await service.submitDraft(createDraft());
      expect(outcome.staged, isFalse);
      expect(outcome.draft.state, DraftState.approvedOnServer);
      expect(await outbox.list(), isEmpty);
    },
  );
}

class FakeReadModel implements CommandReadModel {
  final Map<String, ({Map<String, dynamic> row, bool deleted, int version})>
  rows = {};

  @override
  Future<({Map<String, dynamic> row, bool deleted, int version})?>
  readApprovedEntity({
    required String organizationId,
    required String entityType,
    required String entityId,
  }) async => rows['$entityType:$entityId'];
}

extension on CommandDraft {
  CommandDraft copyForTest({DraftState? state, String? entityId}) =>
      CommandDraft(
        id: id,
        organizationId: organizationId,
        uid: uid,
        entityType: entityType,
        operation: operation,
        entityId: entityId ?? this.entityId,
        parentEntityType: parentEntityType,
        parentEntityId: parentEntityId,
        baseVersion: baseVersion,
        payload: payload,
        state: state ?? this.state,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );
}
