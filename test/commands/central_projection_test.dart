import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/central_projection.dart';
import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/sync/shared_settings.dart';
import 'package:material_lab/core/sync/sync_run_scope.dart';

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
      'protocol_schema': 3,
      'applied_sequence': 0,
    });
  });
  tearDown(() async => fixture.dispose());

  test(
    'approved command audits are visible once and remain permission scoped',
    () async {
      const record = ApprovedRecord(
        entityType: 'auditLog',
        entityId: 'cmd_op',
        version: 1,
        data: {
          'organizationId': 'org_test',
          'version': 1,
          'userId': 'uid_admin',
          'userName': 'Admin',
          'action': 'DOMAIN_COMMITTED',
          'entityType': 'domainTransaction',
          'entityId': 'op',
          'detailsJson': '{}',
          'deviceId': 'other-device',
          'occurredAt': '2026-10-27T10:00:00Z',
        },
      );
      await projection.applyEvent(
        sequence: 1,
        operationId: 'op',
        records: [record],
      );
      await projection.applyEvent(
        sequence: 1,
        operationId: 'op',
        records: [record],
      );
      final rows = await fixture.db.query('audit_logs');
      expect(rows, hasLength(1));
      expect(rows.single['user_id'], 'uid_admin');
      expect(rows.single['action'], 'DOMAIN_COMMITTED');
      final viewer = CentralProjection(
        databaseHelper: fixture.helper,
        source: SessionSource(
          () => const AppSession(
            uid: 'uid_admin',
            organizationId: 'org_test',
            deviceId: 'device',
            memberId: 'member',
            role: 'viewer',
            status: 'active',
          ),
        ),
      );
      await expectLater(
        viewer.installSnapshot(throughSequence: 1, records: [record]),
        throwsA(isA<StateError>()),
      );
    },
  );

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

  ApprovedRecord setting(
    String id,
    String key,
    String value, {
    int version = 1,
  }) => ApprovedRecord(
    entityType: 'organizationSetting',
    entityId: id,
    version: version,
    data: approved(
      {
        'key': key,
        'value': value,
        'localId': 217,
        'deviceId': 'foreign-android',
      },
      id,
      version: version,
    ),
  );

  test(
    'approved setting replaces only its unapproved local shadow and replays once',
    () async {
      const key = 'inspection_label_form_no';
      await fixture.db.rawInsert(
        'INSERT INTO organization_settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, 'local-default'],
      );
      await fixture.db.insert('drafts', {
        'id': 'keep-draft',
        'organization_id': 'org_test',
        'uid': 'uid_admin',
        'entity_type': 'organizationSetting',
        'operation': 'update',
        'payload': '{"value":"draft-value"}',
      });
      final record = setting('remote-setting', key, 'form2');
      await projection.applyEvent(
        sequence: 1,
        operationId: 'setting-op',
        records: [record],
      );
      await projection.applyEvent(
        sequence: 1,
        operationId: 'setting-op',
        records: [record],
      );
      final rows = await fixture.db.query(
        'organization_settings',
        where: 'key = ?',
        whereArgs: [key],
      );
      expect(rows, hasLength(1));
      expect(rows.single['remote_id'], 'remote-setting');
      expect(rows.single['value'], 'form2');
      expect(rows.single['id'], isNot(217));
      expect(
        (await fixture.db.query(
          'settings',
          where: 'key = ?',
          whereArgs: [key],
        )).single['value'],
        'form2',
      );
      expect(
        (await fixture.db.query('drafts')).single['payload'],
        '{"value":"draft-value"}',
      );
      expect(await sequence(), 1);
      expect(
        await fixture.db.query(
          'legacy_sync_archive',
          where: 'source_table = ?',
          whereArgs: ['organization_settings'],
        ),
        hasLength(1),
      );
    },
  );

  for (final type in ['member', 'labUnit']) {
    test(
      'existing local $type uses its stable key without a duplicate insert',
      () async {
        final entity = SyncEntity.byType(type)!;
        if (type == 'labUnit') {
          await fixture.db.rawInsert(
            "INSERT OR IGNORE INTO lab_units(symbol, is_active, created_at) VALUES ('g', 1, '2026-01-01')",
          );
        }
        final column = type == 'member' ? 'uid' : 'symbol';
        final value = type == 'member' ? 'uid_admin' : 'g';
        final original = Map<String, dynamic>.from(
          (await fixture.db.query(
            entity.localTable,
            where: '$column = ?',
            whereArgs: [value],
          )).single,
        );
        final local = original['id'];
        original['id'] = 913;
        final payload = buildRemotePayload(
          entity,
          original,
          context,
          asCreate: true,
        );
        await projection.applyEvent(
          sequence: 1,
          operationId: 'adopt-$type',
          records: [
            ApprovedRecord(
              entityType: type,
              entityId: 'global-$type',
              version: 1,
              data: approved(payload, 'global-$type'),
            ),
          ],
        );
        final rows = await fixture.db.query(
          entity.localTable,
          where: '$column = ?',
          whereArgs: [value],
        );
        expect(rows, hasLength(1));
        expect(rows.single['id'], local);
        expect(rows.single['remote_id'], 'global-$type');
        expect(await sequence(), 1);
      },
    );
  }

  test(
    'known setting identity can update into a key occupied by a local shadow',
    () async {
      await projection.applyEvent(
        sequence: 1,
        operationId: 'first-key',
        records: [setting('known-setting', 'custom_previous_key', 'old')],
      );
      final oldId = (await fixture.db.query(
        'organization_settings',
        where: 'remote_id = ?',
        whereArgs: ['known-setting'],
      )).single['id'];
      await fixture.db.insert('organization_settings', {
        'key': 'custom_next_key',
        'value': 'local',
      });
      await projection.applyEvent(
        sequence: 2,
        operationId: 'next-key',
        records: [
          setting('known-setting', 'custom_next_key', 'server', version: 2),
        ],
      );
      final rows = await fixture.db.query(
        'organization_settings',
        where: 'key = ?',
        whereArgs: ['custom_next_key'],
      );
      expect(rows, hasLength(1));
      expect(rows.single['id'], oldId);
      expect(rows.single['value'], 'server');
      expect(await sequence(), 2);
    },
  );

  test(
    'every shared settings key reconciles in the incremental cycle path',
    () async {
      final records = <ApprovedRecord>[];
      for (final key in sharedSettingKeys) {
        await fixture.db.rawInsert(
          'INSERT INTO organization_settings(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [key, 'default'],
        );
        records.add(setting('global-$key', key, 'server-$key'));
      }
      await projection.applyCycle(
        afterSequence: 0,
        throughSequence: 1,
        records: records,
        operationIds: {'settings-cycle'},
        scope: SyncRunScope(SessionSource(() => session), fixture.helper),
      );
      for (final key in sharedSettingKeys) {
        final row = (await fixture.db.query(
          'organization_settings',
          where: 'key = ?',
          whereArgs: [key],
        )).single;
        expect(row['value'], 'server-$key');
        expect(row['remote_id'], 'global-$key');
        expect(
          (await fixture.db.query(
            'settings',
            where: 'key = ?',
            whereArgs: [key],
          )).single['value'],
          'server-$key',
        );
      }
      expect(await sequence(), 1);
      expect(
        await fixture.db.query(
          'legacy_sync_archive',
          where: 'source_table = ?',
          whereArgs: ['organization_settings'],
        ),
        hasLength(sharedSettingKeys.length),
      );
    },
  );

  test(
    'setting shadow reconciliation rolls back with a rejected companion',
    () async {
      await fixture.db.insert('organization_settings', {
        'key': 'rollback-key',
        'value': 'keep-local',
      });
      await expectLater(
        projection.applyEvent(
          sequence: 1,
          operationId: 'rollback-setting',
          records: [
            setting('rollback-setting', 'rollback-key', 'new'),
            ApprovedRecord(
              entityType: 'sample',
              entityId: 'missing-parent',
              version: 1,
              data: approved({
                'entryCode': 'MISSING',
                'inspectionKind': 'raw',
              }, 'missing-parent'),
            ),
          ],
        ),
        throwsStateError,
      );
      expect(
        (await fixture.db.query(
          'organization_settings',
          where: 'key = ?',
          whereArgs: ['rollback-key'],
        )).single['value'],
        'keep-local',
      );
      expect(await sequence(), 0);
      expect(
        await fixture.db.query(
          'legacy_sync_archive',
          where: 'source_table = ?',
          whereArgs: ['organization_settings'],
        ),
        isEmpty,
      );
      expect(
        await fixture.db.query(
          'central_entity_identities',
          where: 'entity_type = ?',
          whereArgs: ['organizationSetting'],
        ),
        isEmpty,
      );
    },
  );

  test(
    'different approved setting identities cannot silently replace each other',
    () async {
      await projection.applyEvent(
        sequence: 1,
        operationId: 'first-setting',
        records: [setting('first-setting', 'collision-key', 'approved')],
      );
      await expectLater(
        projection.applyEvent(
          sequence: 2,
          operationId: 'invalid-setting',
          records: [setting('second-setting', 'collision-key', 'wrong')],
        ),
        throwsStateError,
      );
      final rows = await fixture.db.query(
        'organization_settings',
        where: 'key = ?',
        whereArgs: ['collision-key'],
      );
      expect(rows.single['remote_id'], 'first-setting');
      expect(rows.single['value'], 'approved');
      expect(await sequence(), 1);
      expect(
        await fixture.db.query(
          'legacy_sync_archive',
          where: 'source_table = ?',
          whereArgs: ['organization_settings'],
        ),
        isEmpty,
      );
    },
  );

  test(
    'NIR reset remaps its typed parent instead of reusing a foreign local id',
    () async {
      await projection.applyEvent(
        sequence: 1,
        operationId: 'material',
        records: await aggregate(),
      );
      final payload = buildRemotePayload(
        SyncEntity.byType('nirValidationSettings')!,
        {
          'id': 913,
          'scope': 'raw_material',
          'entity_id': 913,
          'material_id': 913,
          'product_id': null,
          'reference_version': 1,
          'entity_name': 'New server material',
          'parameter': 'Protein',
          'start_date': '2026-10-01',
          'created_at': '2026-10-26',
          'updated_at': '2026-10-26',
        },
        context,
        asCreate: true,
      );
      await projection.applyEvent(
        sequence: 2,
        operationId: 'reset',
        records: [
          ApprovedRecord(
            entityType: 'nirValidationSettings',
            entityId: 'global-reset',
            version: 1,
            data: approved(
              payload,
              'global-reset',
              refs: {
                'materialId': {
                  'entityType': 'referenceMaterial',
                  'entityId': 'new-material',
                  'version': 1,
                },
              },
            ),
          ),
        ],
      );
      final material = (await fixture.db.query(
        'reference_materials',
        where: 'remote_id = ?',
        whereArgs: ['new-material'],
      )).single;
      final reset = (await fixture.db.query('nir_validation_settings')).single;
      expect(material['id'], isNot(913));
      expect(material['id'], isNot(1));
      expect(reset['material_id'], material['id']);
      expect(reset['entity_id'], 913);
      expect(reset['reference_version'], 1);
      expect(reset['product_id'], isNull);
    },
  );

  test(
    'actor cache respects member reservations and repeated historical actors',
    () async {
      final records = await aggregate();
      final base =
          (await fixture.db.rawQuery(
                'SELECT MAX(id) AS n FROM users',
              )).single['n']
              as int;
      final user =
          Map<String, dynamic>.from(
              (await fixture.db.query(
                'users',
                where: 'uid = ?',
                whereArgs: ['uid_admin'],
              )).single,
            )
            ..['uid'] = 'reserved_actor'
            ..['email'] = 'reserved@example.test';
      final member = ApprovedRecord(
        entityType: 'member',
        entityId: 'member-reserved',
        version: 1,
        data: approved(
          buildRemotePayload(
            SyncEntity.byType('member')!,
            user,
            context,
            asCreate: true,
          ),
          'member-reserved',
        ),
      );
      ApprovedRecord inspection(String id, String actor) => ApprovedRecord(
        entityType: 'sample',
        entityId: id,
        version: 1,
        data: {
          ...records.first.data,
          'remoteId': id,
          'entryCode': id,
          'createdBy': actor,
        },
      );
      await projection.applyEvent(
        sequence: 1,
        operationId: 'actors',
        records: [
          inspection('a', 'historical_actor'),
          inspection('b', 'reserved_actor'),
          member,
          inspection('c', 'historical_actor'),
          inspection('d', 'another_actor'),
          records.last,
        ],
      );
      final users = {
        for (final row in await fixture.db.query('users'))
          row['uid']: row['id'],
      };
      expect(users['reserved_actor'], base + 1);
      expect(users['historical_actor'], base + 2);
      expect(users['another_actor'], base + 3);
      final rows = {
        for (final row in await fixture.db.query('inspections'))
          row['entry_code']: row['created_by'],
      };
      expect(rows, {
        'a': base + 2,
        'b': base + 1,
        'c': base + 2,
        'd': base + 3,
      });
    },
  );

  test(
    'mixed newer and skipped records retain targets for child references',
    () async {
      final records = await aggregate();
      await projection.applyEvent(
        sequence: 1,
        operationId: 'initial',
        records: records,
      );
      final original = (await fixture.db.query(
        'reference_materials',
        where: 'remote_id = ?',
        whereArgs: ['new-material'],
      )).single;
      await projection.applyEvent(
        sequence: 2,
        operationId: 'mixed',
        records: [
          ApprovedRecord(
            entityType: 'sample',
            entityId: records.first.entityId,
            version: 2,
            data: {...records.first.data, 'version': 2, 'supplier': 'updated'},
          ),
          records.last,
        ],
      );
      final row = (await fixture.db.query('inspections')).single;
      expect(row['material_id'], original['id']);
      expect(row['supplier'], 'updated');
      expect(
        (await fixture.db.query(
          'reference_materials',
          where: 'id = ?',
          whereArgs: [original['id']],
        )).single,
        original,
      );
      expect(await sequence(), 2);
    },
  );

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
        (await fixture.db.query(
          'central_sync_state',
        )).single['bootstrap_state'],
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

  group('manual audit trail materialization', () {
    ApprovedRecord auditFrame(
      String id,
      Map<String, dynamic> data, {
      int version = 1,
    }) => ApprovedRecord(
      entityType: 'auditLog',
      entityId: id,
      version: version,
      data: {
        'organizationId': 'org_test',
        'version': version,
        ...data,
      },
    );

    test('pages replay idempotently and identity rows stay reused', () async {
      final scope = SyncRunScope(SessionSource(() => session), fixture.helper);
      final page = [
        auditFrame('al_dev1_t1_a1', {
          'userId': 'uid_admin',
          'userName': 'Admin',
          'action': 'DOMAIN_COMMITTED',
          'entityType': 'domainTransaction',
          'entityId': 'op-1',
          'detailsJson': '{}',
          'operationId': 'op-1',
          'records': [
            {
              'entityType': 'sample',
              'entityId': 'inspection-global',
              'version': 1,
            },
          ],
          'deviceId': 'device',
          'occurredAt': '2026-11-10T10:00:00Z',
        }),
      ];
      expect(await projection.applyAuditTrail(page, scope), 1);

      // A replay of the SAME page is skipped (append-once).
      expect(await projection.applyAuditTrail(page, scope), 0);
      expect(await fixture.db.query('audit_logs'), hasLength(1));
      final row = (await fixture.db.query('audit_logs')).single;
      expect(row['organization_id'], 'org_test');
      expect(row['synced'], 1);
      expect(row['user_id'], 'uid_admin');
      expect(row['occurred_at'], '2026-11-10T10:00:00Z');
      // The committed operation frame survives in details_json.
      final details = jsonDecode('${row['details_json']}');
      expect(details['operationId'], 'op-1');
      expect(
        (details['records'] as List).single['entityId'],
        'inspection-global',
      );
      final identity = (await fixture.db.query(
        'central_entity_identities',
        where: "entity_type = 'auditLog'",
      )).single;
      expect(identity['entity_id'], 'al_dev1_t1_a1');
      expect(identity['approved_version'], 1);

      // A REPUBLISHED higher version converges through the identity row:
      // the audit_logs table gains no second row (append-only domain).
      final v2 = auditFrame(
        'al_dev1_t1_a1',
        {
          'userId': 'uid_admin',
          'userName': 'Admin',
          'action': 'DOMAIN_COMMITTED',
          'entityType': 'domainTransaction',
          'entityId': 'op-1',
          'detailsJson': '{}',
          'operationId': 'op-1',
          'records': const <Object>[],
          'deviceId': 'device',
          'occurredAt': '2026-11-10T10:00:00Z',
        },
        version: 2,
      );
      expect(await projection.applyAuditTrail([v2], scope), 1);
      expect(await fixture.db.query('audit_logs'), hasLength(1));
      expect(
        (await fixture.db.query(
          'central_entity_identities',
          where: "entity_type = 'auditLog'",
        )).single['approved_version'],
        2,
      );
    });

    test('tampered bytes for the same approved version abort the page', () async {
      final scope = SyncRunScope(SessionSource(() => session), fixture.helper);
      final record = auditFrame('al_dev2_t2_a2', {
        'userId': 'uid_admin',
        'userName': 'Admin',
        'action': 'LOGIN',
        'entityType': 'session',
        'entityId': 'login-1',
        'deviceId': 'device',
        'occurredAt': '2026-11-10T11:00:00Z',
      });
      expect(await projection.applyAuditTrail([record], scope), 1);

      final tampered = ApprovedRecord(
        entityType: 'auditLog',
        entityId: 'al_dev2_t2_a2',
        version: 1,
        data: {...record.data, 'userName': 'Impostor'},
      );
      await expectLater(
        projection.applyAuditTrail([tampered], scope),
        throwsStateError,
      );
      expect(
        (await fixture.db.query('audit_logs')).single['user_name'],
        'Admin',
      );
    });

    test('invalid frames are rejected before any row is written', () async {
      final scope = SyncRunScope(SessionSource(() => session), fixture.helper);
      // A non-audit entity never enters the trail projection.
      await expectLater(
        projection.applyAuditTrail([
          ApprovedRecord(
            entityType: 'sample',
            entityId: 'inspection-global',
            version: 1,
            data: const {
              'organizationId': 'org_test',
              'version': 1,
            },
          ),
        ], scope),
        throwsA(isA<StateError>()), // audit log path rejects foreign records
      );
      // A record claiming another organization is refused.
      await expectLater(
        projection.applyAuditTrail([
          ApprovedRecord(
            entityType: 'auditLog',
            entityId: 'al_foreign',
            version: 1,
            data: const {
              'organizationId': 'org_other',
              'version': 1,
              'action': 'LOGIN',
              'entityType': 'session',
              'entityId': 'login',
              'deviceId': 'device',
              'occurredAt': '2026-11-10T12:00:00Z',
            },
          ),
        ], scope),
        throwsA(isA<StateError>()), // foreign organization
      );
      expect(await fixture.db.query('audit_logs'), isEmpty);
      expect(await fixture.db.query('central_approved_records'), isEmpty);
    });

    test('a session without audit.read cannot materialize the trail', () async {
      final viewerScope = SyncRunScope(
        SessionSource(
          () => const AppSession(
            uid: 'uid_admin',
            organizationId: 'org_test',
            deviceId: 'device',
            memberId: 'member',
            role: 'viewer',
            status: 'active',
          ),
        ),
        fixture.helper,
      );
      await expectLater(
        projection.applyAuditTrail(const [], viewerScope),
        throwsA(isA<StateError>()), // audit trail projection is admin-only
      );
    });
  });
}
