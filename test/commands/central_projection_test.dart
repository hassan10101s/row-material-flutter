import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/central_projection.dart';
import 'package:material_lab/core/sync/entity_registry.dart';

import '../sync/sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture fixture;
  late CentralProjection projection;
  const session = AppSession(
    uid: 'uid_admin',
    organizationId: 'org_test',
    deviceId: 'device',
    memberId: 'member',
    role: 'admin',
    status: 'active',
  );
  const context = SyncPayloadContext(
    organizationId: 'org_test',
    uid: 'uid_admin',
    deviceId: 'origin',
    version: 1,
    versionField: 'version',
  );

  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    projection = CentralProjection(
      databaseHelper: fixture.helper,
      source: SessionSource(() => session),
    );
    await fixture.db.insert('central_entity_identities', {
      'entity_type': 'referenceMaterial',
      'entity_id': 'decoy',
      'local_ref': 1,
      'approved_version': 1,
    });
    await fixture.db.insert('central_sync_state', {
      'organization_id': 'org_test',
      'uid': 'uid_admin',
      'role': 'admin',
      'bootstrap_state': 'ready',
      'applied_sequence': 0,
    });
  });
  tearDown(() async => fixture.dispose());

  Map<String, dynamic> approved(
    Map<String, dynamic> data,
    String id, {
    int version = 1,
    Map<String, dynamic> refs = const {},
  }) => {
    ...data,
    'organizationId': 'org_test',
    'remoteId': id,
    'version': version,
    'createdBy': 'uid_admin',
    'updatedBy': 'uid_admin',
    'createdAt': '2026-10-26T00:00:00.000Z',
    'updatedAt': '2026-10-26T00:00:00.000Z',
    'deletedAt': null,
    'parentRefs': refs,
  };

  Future<List<ApprovedRecord>> aggregate() async {
    final raw =
        Map<String, dynamic>.from(
            (await fixture.db.query(
              'reference_materials',
              where: 'id = 1',
            )).single,
          )
          ..['id'] = 913
          ..['material_name'] = 'New server material'
          ..['material_code'] = 'NEW';
    final material = approved(
      buildRemotePayload(
        SyncEntity.byType('referenceMaterial')!,
        raw,
        context,
        asCreate: true,
      ),
      'new-material',
    );
    final row = sampleRow(entryCode: 'CENTRAL-EVENT')
      ..['id'] = 913
      ..['material_id'] = 913;
    final inspection = approved(
      buildRemotePayload(
        SyncEntity.byType('sample')!,
        row,
        context,
        asCreate: true,
      ),
      'inspection-global',
      refs: {
        'materialId': {
          'entityType': 'referenceMaterial',
          'entityId': 'new-material',
          'version': 1,
        },
      },
    );
    return [
      ApprovedRecord(
        entityType: 'sample',
        entityId: 'inspection-global',
        version: 1,
        data: inspection,
      ),
      ApprovedRecord(
        entityType: 'referenceMaterial',
        entityId: 'new-material',
        version: 1,
        data: material,
      ),
    ];
  }

  Future<int> sequence() async =>
      (await fixture.db.query('central_sync_state')).single['applied_sequence']
          as int;

  test(
    'an entire after-image event commits with its checkpoint and remaps global parents',
    () async {
      await projection.applyEvent(
        sequence: 1,
        operationId: 'operation',
        records: await aggregate(),
      );
      final row = (await fixture.db.query('inspections')).single;
      final material = (await fixture.db.query(
        'reference_materials',
        where: 'material_code = ?',
        whereArgs: ['NEW'],
      )).single;
      expect(row['id'], isNot(913));
      expect(row['material_id'], material['id']);
      expect(material['id'], isNot(1));
      expect(
        (await fixture.db.query(
          'reference_materials',
          where: 'id = 1',
        )).single['material_code'],
        isNot('NEW'),
      );
      expect(row['created_by'], 1);
      expect(row['sync_state'], 'synced');
      expect(await sequence(), 1);
      await projection.applyEvent(
        sequence: 1,
        operationId: 'operation',
        records: await aggregate(),
      );
      expect(await fixture.db.query('inspections'), hasLength(1));
    },
  );

  test(
    'a missing parent rolls back identities, records and checkpoint together',
    () async {
      final records = await aggregate();
      await expectLater(
        projection.applyEvent(
          sequence: 1,
          operationId: 'broken',
          records: [records.first],
        ),
        throwsStateError,
      );
      expect(await fixture.db.query('inspections'), isEmpty);
      expect(await fixture.db.query('central_approved_records'), isEmpty);
      expect(
        await fixture.db.query(
          'central_entity_identities',
          where: 'entity_type = ?',
          whereArgs: ['sample'],
        ),
        isEmpty,
      );
      expect(await sequence(), 0);
    },
  );

  test('a feed gap cannot advance the checkpoint', () async {
    await expectLater(
      projection.applyEvent(
        sequence: 2,
        operationId: 'gap',
        records: await aggregate(),
      ),
      throwsStateError,
    );
    expect(await sequence(), 0);
    expect(await fixture.db.query('inspections'), isEmpty);
  });

  test(
    'a version with different contents cannot overwrite an approved record',
    () async {
      final records = await aggregate();
      await projection.applyEvent(
        sequence: 1,
        operationId: 'first',
        records: records,
      );
      final changed = ApprovedRecord(
        entityType: records.first.entityType,
        entityId: records.first.entityId,
        version: 1,
        data: {...records.first.data, 'supplier': 'tampered'},
      );
      await expectLater(
        projection.applyEvent(
          sequence: 2,
          operationId: 'second',
          records: [changed],
        ),
        throwsStateError,
      );
      expect(await sequence(), 1);
      expect(
        (await fixture.db.query('inspections')).single['supplier'],
        isNot('tampered'),
      );
    },
  );

  test(
    'a snapshot lands as catching_up, becomes ready only when promoted, and a ready cache cannot be replaced',
    () async {
      await fixture.db.delete('central_sync_state');
      await projection.installSnapshot(
        throughSequence: 7,
        records: await aggregate(),
      );
      expect(await sequence(), 7);
      // Authoring stays blocked until the post-snapshot event feed is proven
      // drained; the driver promotes the state explicitly.
      expect(
        (await fixture.db.query('central_sync_state')).single['bootstrap_state'],
        'catching_up',
      );
      await projection.markReady();
      expect(
        (await fixture.db.query(
          'central_sync_state',
        )).single['bootstrap_state'],
        'ready',
      );
      await expectLater(
        projection.installSnapshot(throughSequence: 0, records: []),
        throwsStateError,
      );
      expect(await fixture.db.query('inspections'), hasLength(1));
    },
  );

  test('events can still be applied while catching_up', () async {
    // installSnapshot wipes the entity tables, so the fixture records must be
    // built before it runs.
    final records = await aggregate();
    await fixture.db.delete('central_sync_state');
    await projection.installSnapshot(throughSequence: 0, records: []);
    await projection.applyEvent(
      sequence: 1,
      operationId: 'post-snapshot',
      records: records,
    );
    expect(await sequence(), 1);
    expect(
      (await fixture.db.query('central_sync_state')).single['bootstrap_state'],
      'catching_up',
    );
  });
}
