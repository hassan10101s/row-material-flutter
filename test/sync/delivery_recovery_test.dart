import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'lost mutable acknowledgements do not duplicate or change original identity',
    () async {
      final remote = InMemoryDataSource();
      final data = <String, dynamic>{
        'organizationId': 'org',
        'localId': 7,
        'createdBy': 'author',
        'updatedBy': 'author',
        'deviceId': 'desktop',
        'materialName': 'A',
        'deletedAt': null,
      };
      Future<PushResult> push(Map<String, dynamic> value, int base) =>
          remote.setDocument(
            organizationId: 'org',
            collection: SyncCollection.samples,
            documentId: 'sample',
            data: value,
            baseVersion: base,
          );
      expect((await push(data, 0)).version, 1);
      expect((await push(data, 0)).version, 1);
      final edit = {
        ...data,
        'localId': 99,
        'createdBy': 'receiver',
        'materialName': 'B',
      };
      expect((await push(edit, 1)).version, 2);
      expect((await push(edit, 1)).version, 2);
      expect(remote.documents, hasLength(1));
      expect(remote.documents.values.single['localId'], 7);
      expect(remote.documents.values.single['createdBy'], 'author');
      remote.documents.clear();
      expect((await push(edit, 2)).version, 1);
      expect(remote.documents.values.single['createdAt'], isNotNull);
    },
  );

  test(
    'append retry is acknowledged once and a different value cannot overwrite it',
    () async {
      final remote = InMemoryDataSource();
      final data = <String, dynamic>{
        'organizationId': 'org',
        'deviceId': 'desktop',
        'remoteId': 'transaction',
        'quantityDelta': -3,
        'createdAt': 'old',
      };
      Future<PushResult> push(Map<String, dynamic> value) =>
          remote.appendDocument(
            organizationId: 'org',
            collection: SyncCollection.inventoryTransactions,
            documentId: 'transaction',
            data: value,
          );
      expect((await push(data)).isSuccess, isTrue);
      expect(
        (await push({
          ...data,
          'deviceId': 'reenrolled',
          'createdAt': 'new',
        })).isSuccess,
        isTrue,
      );
      expect((await push({...data, 'quantityDelta': -30})).isSuccess, isFalse);
      expect(remote.documents, hasLength(1));
      expect(remote.documents.values.single['quantityDelta'], -3);
      expect(remote.appendReceipts, hasLength(1));
    },
  );

  test(
    'upgrade retries an old transport denial once and resolves only after acknowledgement',
    () async {
      final fixture = await openSyncFixture();
      addTearDown(fixture.dispose);
      await fixture.seedOrganization();
      final queue = SyncQueue(fixture.helper);
      final id = await fixture.db.insert(
        'inspections',
        sampleRow(entryCode: 'recover'),
      );
      await fixture.transaction(
        (txn) => queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'recover',
          localRef: id,
          operation: 'update',
          payload: const {},
        ),
      );
      final first = (await queue.claim()).single;
      await queue.markConflict(
        first,
        direction: 'push_rejected',
        error: 'Missing or insufficient permissions.',
      );
      expect(await queue.countConflicts(), 1);
      expect(await queue.recoverEnvelopeUpgrade(), 1);
      expect(await queue.recoverEnvelopeUpgrade(), 0);
      expect(await queue.countConflicts(), 1);
      final retry = (await queue.claim()).single;
      await queue.markDone(retry, remoteVersion: 1);
      expect(await queue.countConflicts(), 0);
      expect(await queue.listConflicts(), isEmpty);
      final local = (await fixture.db.query(
        'inspections',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(local['remote_version'], 1);
      expect(local['version'], 1);
      expect(local['sync_state'], 'synced');
    },
  );
}
