import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/lab/data/offline_first_lab_repository.dart';
import 'package:material_lab/features/inspections/data/offline_first_inspection_repository.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/central_authoring_gateway.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/sync/sync_queue.dart';

import '../sync/sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture fixture;
  late SyncQueue queue;
  late CommandOutbox outbox;
  late CentralAuthoringGateway gateway;
  const session = AppSession(
    uid: 'uid_admin',
    organizationId: 'org_test',
    memberId: 'm1',
    deviceId: 'dev_1',
    role: 'admin',
    status: 'active',
  );

  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    // Authoring requires a downloaded AND fully caught-up central archive.
    await fixture.db.insert('central_sync_state', {
      'organization_id': 'org_test',
      'uid': 'uid_admin',
      'role': 'admin',
      'bootstrap_state': 'ready',
      'applied_sequence': 1,
    });
    await fixture.db.insert('central_entity_identities', {
      'entity_type': 'referenceMaterial',
      'entity_id': 'server-material-1',
      'local_ref': 1,
      'approved_version': 1,
    });

    queue = SyncQueue(fixture.helper);
    outbox = CommandOutbox(fixture.helper);
    outbox.scopeProvider = () =>
        const CommandScope('org_test', 'uid_admin', 'dev_1');
    outbox.deviceProvider = () => 'dev_1';
    gateway = CentralAuthoringGateway(
      databaseHelper: fixture.helper,
      source: SessionSource(() => session),
      outbox: outbox,
    );
    fixture.helper.businessGateway = gateway;
  });
  tearDown(() async => fixture.dispose());

  OfflineFirstLabRepository lab({SyncQueue? transportQueue}) {
    final selected = transportQueue ?? queue;
    return OfflineFirstLabRepository(
      dbHelper: fixture.helper,
      guard: SessionWriteGuard(
        source: SessionSource(() => session),
        isOnline: () => false,
      ),
      queue: selected,
      audit: AuditLogger(queue: selected, session: () => session),
    );
  }

  test(
    'the actual inspection screen repository stages a full inspection without changing the archive',
    () async {
      await fixture.db.update('reference_materials', {
        'physical_reference_json': '{"color":"good"}',
      }, where: 'id = 1');
      final repository = OfflineFirstInspectionRepository(
        dbHelper: fixture.helper,
        referenceRepo: ReferenceRepo(
          dbHelper: fixture.helper,
          deviceTagProvider: () async => 'TEST',
        ),
        guard: SessionWriteGuard(
          source: SessionSource(() => session),
          isOnline: () => false,
        ),
        queue: queue,
        audit: AuditLogger(queue: queue, session: () => session),
      );
      await expectLater(
        repository.create({
          'entry_code': 'CENTRAL-REAL',
          'material_id': 1,
          'inspection_date': '2026-10-26',
          'supplier': 'Valid Supplier',
          'sample_taken_by': 'Valid Taker',
          'quantity': '10,5',
          'sample_names': ['S1'],
          'physical_results': {'color': 'good'},
          'decision_status': 'APPROVED',
        }, const UserContext(id: 1, fullName: 'Admin', role: 'Admin')),
        throwsA(isA<CentralDraftPending>()),
      );
      expect(await fixture.db.query('inspections'), isEmpty);
      final request = (await fixture.db.query('command_outbox')).single;
      final writes =
          (jsonDecode(request['payload'] as String) as Map)['writes'] as List;
      final sample = writes.singleWhere((row) => row['entityType'] == 'sample');
      expect(sample['payload']['quantity'], '10,5');
      expect(sample['payload']['decisionStatus'], 'APPROVED');
      expect(sample['payload']['physicalResultsJson'], contains('good'));
    },
  );

  test(
    'the inventory screen stages the item, opening lot and ledger in one request',
    () async {
      await expectLater(
        lab().addInventoryItem(
          name: 'Central Reagent',
          category: 'liquid',
          unit: 'mL',
          qty: 10,
          minQty: 1,
          user: {'id': 1, 'full_name': 'Admin'},
        ),
        throwsA(isA<CentralDraftPending>()),
      );
      for (final table in [
        'lab_inventory',
        'inventory_lots',
        'inventory_transactions',
      ]) {
        expect(
          await fixture.db.query(table),
          isEmpty,
          reason: '$table stays server-approved',
        );
      }
      final request = (await fixture.db.query('command_outbox')).single;
      final writes =
          (jsonDecode(request['payload'] as String) as Map)['writes'] as List;
      expect(
        writes.map((row) => row['entityType']),
        containsAll(['inventoryItem', 'inventoryLot', 'inventoryTransaction']),
      );
    },
  );

  test('worksheet cancellation rolls back if its outbox write fails', () async {
    fixture.helper.businessGateway = null;
    final id = await fixture.db.insert('lab_worksheet', {
      'created_at': '2026-10-26',
      'status': 'ACTIVE',
      'created_by': 1,
    });
    await expectLater(
      lab(
        transportQueue: _FailingQueue(fixture.helper),
      ).deleteWorksheetRow(rowId: id, reason: 'Cancel', user: {'id': 1}),
      throwsStateError,
    );
    final row = (await fixture.db.query(
      'lab_worksheet',
      where: 'id = ?',
      whereArgs: [id],
    )).single;
    expect(row['status'], 'ACTIVE');
    expect(await fixture.db.query('sync_queue'), isEmpty);
  });

  test(
    'draft plus request commit without exposing the speculative business row',
    () async {
      await expectLater(
        fixture.helper.businessTransaction((txn) async {
          final id = await txn.insert(
            'inspections',
            sampleRow(entryCode: 'CENTRAL-1'),
          );
          await queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'CENTRAL-1',
            localRef: id,
            operation: 'create',
            baseVersion: 0,
            payload: {
              'entryCode': 'CENTRAL-1',
              'updatedBy': 'uid_admin',
              'version': 1,
            },
          );
          return id;
        }),
        throwsA(isA<CentralDraftPending>()),
      );
      expect(await fixture.db.query('inspections'), isEmpty);
      expect(await fixture.db.query('sync_queue'), isEmpty);
      final draft = (await fixture.db.query('drafts')).single;
      expect(draft['state'], 'waiting_send');
      final request = (await fixture.db.query('command_outbox')).single;
      expect(request['command_type'], 'domain.commit');
      expect(request['payload'], contains('CENTRAL-1'));
      expect(request['draft_id'], draft['id']);
    },
  );

  test('all effects of one action share one immutable request', () async {
    await expectLater(
      fixture.helper.businessTransaction((txn) async {
        for (final code in ['BATCH-A', 'BATCH-B']) {
          final id = await txn.insert(
            'inspections',
            sampleRow(entryCode: code),
          );
          await queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: code,
            localRef: id,
            operation: 'create',
            baseVersion: 0,
            payload: {
              'entryCode': code,
              'updatedBy': 'uid_admin',
              'version': 1,
            },
          );
        }
      }),
      throwsA(isA<CentralDraftPending>()),
    );
    expect(await fixture.db.query('inspections'), isEmpty);
    final requests = await fixture.db.query('command_outbox');
    expect(requests, hasLength(1));
    expect(
      requests.single['payload'],
      allOf(contains('BATCH-A'), contains('BATCH-B')),
    );
  });

  test(
    'separate offline creates reserve different local identities without visible rows',
    () async {
      for (final code in ['OFFLINE-A', 'OFFLINE-B']) {
        await expectLater(
          fixture.helper.businessTransaction((txn) async {
            final id = await txn.insert(
              'inspections',
              sampleRow(entryCode: code),
            );
            await queue.enqueue(
              txn,
              entityType: 'sample',
              entityId: code,
              localRef: id,
              operation: 'create',
              payload: {'entryCode': code, 'updatedBy': 'uid_admin'},
              baseVersion: 0,
            );
          }),
          throwsA(isA<CentralDraftPending>()),
        );
      }
      expect(await fixture.db.query('inspections'), isEmpty);
      final identities = await fixture.db.query(
        'central_entity_identities',
        where: 'entity_type = ?',
        whereArgs: ['sample'],
      );
      expect(identities.map((row) => row['local_ref']).toSet(), hasLength(2));
      expect(identities.map((row) => row['entity_id']).toSet(), hasLength(2));
      expect(await fixture.db.query('command_outbox'), hasLength(2));
    },
  );

  test(
    'an undeclared mutation is rejected and cannot report success',
    () async {
      await expectLater(
        fixture.helper.businessTransaction((txn) async {
          await txn.insert('inspections', sampleRow(entryCode: 'UNDECLARED'));
        }),
        throwsStateError,
      );
      expect(await fixture.db.query('inspections'), isEmpty);
      expect(await fixture.db.query('drafts'), isEmpty);
      expect(await fixture.db.query('command_outbox'), isEmpty);
    },
  );

  test(
    'a failed business operation leaves no draft and no partial result',
    () async {
      await expectLater(
        fixture.helper.businessTransaction((txn) async {
          await txn.insert('inspections', sampleRow(entryCode: 'FAIL'));
          throw StateError('business validation failed');
        }),
        throwsStateError,
      );
      expect(await fixture.db.query('inspections'), isEmpty);
      expect(await fixture.db.query('command_outbox'), isEmpty);
    },
  );
}

class _FailingQueue extends SyncQueue {
  _FailingQueue(super.dbHelper);
  @override
  Future<void> enqueue(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
    int? localRef,
    required String operation,
    required Map<String, dynamic> payload,
    int baseVersion = 0,
  }) async => throw StateError('outbox unavailable');
}
