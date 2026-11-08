import 'package:flutter_test/flutter_test.dart';
import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/lab/data/server_confirmed_lab_repository.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/inspections/data/server_confirmed_inspection_repository.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:material_lab/features/reference/data/server_confirmed_reference_repository.dart';
import 'package:material_lab/features/qc_manager/data/qc_repo.dart';
import 'package:material_lab/features/qc_manager/data/qc_audit_repo.dart';
import 'package:material_lab/features/qc_manager/data/qc_sync_writer.dart';
import 'package:material_lab/features/qc_manager/data/server_confirmed_qc_repository.dart';
import 'package:material_lab/features/qc_manager/domain/qc_template.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/data/routine_lists_repository.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/central_authoring_gateway.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/drafts_store.dart';
import 'package:material_lab/core/commands/domain_draft_service.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';

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
      'protocol_schema': 3,
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

  ServerConfirmedLabRepository lab({SyncQueue? transportQueue}) {
    final selected = transportQueue ?? queue;
    return ServerConfirmedLabRepository(
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
    'deleting an approved lab result stages its tombstone without removing the source cache',
    () async {
      final analysisId = await fixture.db.insert('lab_analyses', {
        'name': 'Delete regression',
        'unit': '%',
        'dynamic_fields_json': '[]',
        'created_at': '2026-11-03',
        'remote_version': 1,
      });
      final testId = await fixture.db.insert('lab_sample_tests', {
        'analysis_id': analysisId,
        'source_type': 'sample',
        'source_name': 'Sample',
        'sample_name': 'Sample',
        'result_text': '5',
        'tested_at': '2026-11-03',
        'version': 1,
        'remote_version': 1,
        'remote_id': 'approved-result',
        'sync_state': 'synced',
      });
      for (final item in [
        ('labAnalysis', analysisId, 'approved-analysis'),
        ('labResult', testId, 'approved-result'),
      ]) {
        await fixture.db.insert('central_entity_identities', {
          'entity_type': item.$1,
          'local_ref': item.$2,
          'entity_id': item.$3,
          'approved_version': 1,
        });
      }
      await expectLater(
        lab().deleteSampleTest(testId),
        throwsA(isA<CentralDraftPending>()),
      );
      final writes = (await outbox.list()).single.payload['writes'] as List;
      expect(writes, hasLength(1));
      expect(writes.single['entityId'], 'approved-result');
      expect(writes.single['operation'], 'tombstone');
      expect(writes.single['payload']['deletedAt'], isNotNull);
      final cached = (await fixture.db.query('lab_sample_tests')).single;
      expect(cached['deleted_at'], isNull);
      expect(cached['remote_version'], 1);
    },
  );

  for (final kind in [
    'equipment',
    'equipmentEvent',
    'constant',
    'unit',
    'parameter',
    'batch',
    'qcTemplate',
    'inspection',
    'material',
    'analysis',
    'product',
  ]) {
    test(
      'delete audit: $kind stages all effects and preserves approved cache',
      () async {
        final plain = LabRepo(dbHelper: fixture.helper);
        final reference = ServerConfirmedReferenceRepository(
          dbHelper: fixture.helper,
          guard: SessionWriteGuard(
            source: SessionSource(() => session),
            isOnline: () => true,
          ),
          queue: queue,
          audit: AuditLogger(queue: queue, session: () => session),
        );
        Future<void> approve(
          String type,
          String table,
          int id, {
          String pk = 'id',
        }) async {
          final known = await fixture.db.query(
            'central_entity_identities',
            where: 'entity_type = ? AND local_ref = ?',
            whereArgs: [type, id],
          );
          final remote = known.isEmpty
              ? 'delete-$type-$id'
              : known.single['entity_id'] as String;
          await fixture.db.update(
            table,
            {
              'remote_id': remote,
              'remote_version': 1,
              table == 'inspections' ? 'decision_version' : 'version': 1,
              'sync_state': 'synced',
            },
            where: '$pk = ?',
            whereArgs: [id],
          );
          if (known.isEmpty) {
            await fixture.db.insert('central_entity_identities', {
              'entity_type': type,
              'entity_id': remote,
              'local_ref': id,
              'approved_version': 1,
            });
          }
        }

        late String table, type;
        var pk = 'id';
        late int id;
        late Future<void> Function() remove;
        var expected = <String>{};
        if (kind == 'equipment' || kind == 'equipmentEvent') {
          final parent = await plain.createEquipment(name: 'Delete equipment');
          final parentId = parent['id'] as int;
          await approve('equipment', 'lab_equipment', parentId);
          final event = await plain.addEquipmentEvent(
            equipmentId: parentId,
            eventType: 'CALIBRATION',
            eventDate: '2026-11-03',
          );
          final eventId = event['id'] as int;
          await approve('equipmentEvent', 'lab_equipment_events', eventId);
          table = kind == 'equipment'
              ? 'lab_equipment'
              : 'lab_equipment_events';
          type = kind;
          id = kind == 'equipment' ? parentId : eventId;
          remove = kind == 'equipment'
              ? () => lab().deleteEquipment(id)
              : () => lab().deleteEquipmentEvent(id);
          expected = kind == 'equipment'
              ? {'equipment', 'equipmentEvent'}
              : {'equipmentEvent'};
        } else if (kind == 'constant') {
          final row = await plain.upsertGlobalConstant({
            'name': 'Delete constant',
            'symbol': 'DeleteC',
            'value_text': '2',
          });
          table = 'lab_constants';
          type = 'labConstant';
          id = row['id'] as int;
          remove = () async {
            await lab().deleteGlobalConstant(id);
          };
        } else if (kind == 'unit') {
          await ReferenceRepo(
            dbHelper: fixture.helper,
          ).upsertUnit('delete-unit');
          id =
              (await fixture.db.query(
                    'lab_units',
                    where: 'symbol = ?',
                    whereArgs: ['delete-unit'],
                  )).single['id']
                  as int;
          table = 'lab_units';
          type = 'labUnit';
          remove = () => reference.deleteUnit('delete-unit');
        } else if (kind == 'parameter') {
          await ReferenceRepo(
            dbHelper: fixture.helper,
          ).upsertParameter('Delete parameter', '%');
          id =
              (await fixture.db.query(
                    'parameters',
                    where: 'parameter_name = ?',
                    whereArgs: ['Delete parameter'],
                  )).single['id']
                  as int;
          final analysis = await plain.createAnalysis(
            name: 'Linked analysis',
            parameterId: id,
          );
          await approve('labAnalysis', 'lab_analyses', analysis['id'] as int);
          table = 'parameters';
          type = 'parameter';
          remove = () => reference.deleteParameter('Delete parameter');
          expected = {'parameter', 'labAnalysis'};
        } else if (kind == 'qcTemplate') {
          final local = QcTemplateRepo(fixture.helper);
          id = await local.createTemplate(
            const QcTemplate(
              name: 'Delete template',
              code: 'DEL',
              createdAt: '2026-11-03',
              updatedAt: '2026-11-03',
            ),
          );
          table = 'qc_templates';
          type = 'qcTemplate';
          pk = 'template_id';
          final guard = SessionWriteGuard(
            source: SessionSource(() => session),
            isOnline: () => true,
          );
          final repo = ServerConfirmedQcTemplateRepository(
            local: local,
            guard: guard,
            audit: QcAuditRepo(
              dbHelper: fixture.helper,
              actorReader: () => QcActor.fromSession(session),
            ),
            dbHelper: fixture.helper,
            sync: QcSyncWriter(queue: queue, guard: guard),
          );
          remove = () => repo.deleteTemplate(id);
          expected = {'qcTemplate', 'qcAudit'};
        } else if (kind == 'inspection' || kind == 'batch') {
          final batch = await fixture.db.insert('inspections', {
            ...sampleRow(entryCode: 'DELETE-INSPECTION'),
            'inspection_kind': 'product',
          });
          await approve('sample', 'inspections', batch);
          if (kind == 'inspection') {
            table = 'inspections';
            type = 'sample';
            id = batch;
            final repo = ServerConfirmedInspectionRepository(
              dbHelper: fixture.helper,
              referenceRepo: ReferenceRepo(dbHelper: fixture.helper),
              guard: SessionWriteGuard(
                source: SessionSource(() => session),
                isOnline: () => true,
              ),
              queue: queue,
              audit: AuditLogger(queue: queue, session: () => session),
            );
            remove = () => repo.delete(id);
          } else {
            final sample = await plain.addBatchSample(batchId: batch);
            id = sample['id'] as int;
            table = 'product_batch_samples';
            type = 'productBatchSample';
            final a = await plain.createAnalysis(name: 'Batch test');
            await approve('labAnalysis', 'lab_analyses', a['id'] as int);
            final result = await fixture.db.insert('lab_sample_tests', {
              'analysis_id': a['id'],
              'source_type': 'product',
              'source_ref_id': id,
              'source_name': 'Sample',
              'sample_name': 'Sample',
              'entry_code': 'DELETE-INSPECTION',
              'result_text': '2',
              'tested_at': '2026-11-03',
            });
            await approve('labResult', 'lab_sample_tests', result);
            remove = () => lab().deleteBatchSample(id);
            expected = {'productBatchSample', 'labResult'};
          }
        } else if (kind == 'material') {
          table = 'reference_materials';
          type = 'referenceMaterial';
          id = 1;
          remove = () => reference.deleteMaterial(id);
        } else if (kind == 'analysis') {
          final row = await plain.createAnalysis(name: 'Delete definition');
          table = 'lab_analyses';
          type = 'labAnalysis';
          id = row['id'] as int;
          remove = () async {
            await lab().deleteAnalysis(id);
          };
        } else {
          final row = await plain.createProduct(name: 'Delete product');
          table = 'lab_products';
          type = 'labProduct';
          id = row['id'] as int;
          remove = () async {
            await lab().deleteProduct(id);
          };
        }
        await approve(type, table, id, pk: pk);
        final before = (await fixture.db.query(
          table,
          where: '$pk = ?',
          whereArgs: [id],
        )).single;
        await expectLater(remove(), throwsA(isA<CentralDraftPending>()));
        final effects = (await outbox.list()).single.payload['writes'] as List;
        expect(
          effects.map((w) => w['entityType']).toSet(),
          expected.isEmpty ? {type} : expected,
        );
        expect(
          effects.firstWhere((w) => w['entityType'] == type)['operation'],
          'tombstone',
        );
        expect(
          (await fixture.db.query(
            table,
            where: '$pk = ?',
            whereArgs: [id],
          )).single,
          before,
        );
        if (kind == 'parameter') {
          expect(
            (effects.firstWhere(
                  (w) => w['entityType'] == 'labAnalysis',
                )['payload']
                as Map)['parameterId'],
            isNull,
          );
        }
        if (kind == 'batch') {
          expect(
            (await fixture.db.query('lab_sample_tests')).single['deleted_at'],
            isNull,
          );
        }
      },
    );
  }

  test(
    'product NCR with a newly entered quantity unit captures its full atomic operation',
    () async {
      final batchId = await fixture.db.insert('inspections', {
        ...sampleRow(entryCode: 'NCR-UNIT'),
        'inspection_kind': 'product',
        'remote_id': 'ncr-header',
        'remote_version': 1,
      });
      final sampleId = await fixture.db.insert('product_batch_samples', {
        'batch_id': batchId,
        'sample_no': 1,
        'sample_name': 'Sample 1',
        'tested_at': '2026-11-03',
        'created_at': '2026-11-03',
        'remote_id': 'ncr-sample',
        'version': 1,
        'remote_version': 1,
      });
      for (final row in [
        ('sample', batchId, 'ncr-header'),
        ('productBatchSample', sampleId, 'ncr-sample'),
      ]) {
        await fixture.db.insert('central_entity_identities', {
          'entity_type': row.$1,
          'local_ref': row.$2,
          'entity_id': row.$3,
          'approved_version': 1,
        });
      }
      final guard = SessionWriteGuard(
        source: SessionSource(() => session),
        isOnline: () => true,
      );
      final repo = ServerConfirmedQcNcCapaRepository(
        local: QcNcCapaRepo(fixture.helper),
        guard: guard,
        audit: QcAuditRepo(
          dbHelper: fixture.helper,
          actorReader: () => QcActor.fromSession(session),
        ),
        dbHelper: fixture.helper,
        sync: QcSyncWriter(queue: queue, guard: guard),
      );
      await expectLater(
        repo.saveProductSampleFinding(
          QcFindingNc(
            inspectionId: 0,
            productSampleId: sampleId,
            severity: 'Major',
            description: 'Outside product limits',
            qtyAffected: 2.5,
            qtyUnit: 'NCR-new-unit',
            createdAt: '2026-11-03',
            updatedAt: '2026-11-03',
            createdBy: session.uid,
            updatedBy: session.uid,
          ),
        ),
        throwsA(isA<CentralDraftPending>()),
      );
      final effects = (await outbox.list()).single.payload['writes'] as List;
      expect(effects.map((w) => w['entityType']).toSet(), {
        'qcFindingNc',
        'productBatchSample',
        'qcAudit',
        'labUnit',
      });
      expect(await fixture.db.query('qc_findings_nc'), isEmpty);
      expect(
        (await fixture.db.query(
          'product_batch_samples',
        )).single['decision_status'],
        isNot('NON_CONFORMANCE'),
      );
    },
  );

  for (final editing in [false, true]) {
    test(
      'delivery audit material ${editing ? 'edit' : 'create'} includes new reference parameter',
      () async {
        await fixture.db.update('reference_materials', {
          'remote_version': 1,
        }, where: 'id = 1');
        final reference = ServerConfirmedReferenceRepository(
          dbHelper: fixture.helper,
          guard: SessionWriteGuard(
            source: SessionSource(() => session),
            isOnline: () => true,
          ),
          queue: queue,
          audit: AuditLogger(queue: queue, session: () => session),
        );
        final operation = editing
            ? reference.updateMaterial(
                1,
                materialName: 'Cement',
                materialCode: 'M-CEM-01',
                chemicalReference: {'Delivery marker': '1'},
                units: {'Delivery marker': '%'},
              )
            : reference.createMaterial(
                materialName: 'New material',
                materialCode: 'DEL-01',
                chemicalReference: {'Delivery marker': '1'},
                units: {'Delivery marker': '%'},
              );
        await expectLater(operation, throwsA(isA<CentralDraftPending>()));
        final writes = (await outbox.list()).single.payload['writes'] as List;
        expect(writes.map((w) => w['entityType']), [
          'referenceMaterial',
          'parameter',
        ]);
        expect(writes.last['operation'], 'create');
        expect(
          await fixture.db.query(
            'parameters',
            where: 'parameter_name = ?',
            whereArgs: ['Delivery marker'],
          ),
          isEmpty,
        );
      },
    );
  }

  test(
    'delivery audit routine rename captures only its root and audit',
    () async {
      final templates = QcTemplateRepo(fixture.helper);
      final id = await templates.createTemplate(
        const QcTemplate(
          name: 'Routine',
          recurrence: 'daily',
          createdAt: '2026-11-06',
          updatedAt: '2026-11-06',
        ),
      );
      await fixture.db.update(
        'qc_templates',
        {'remote_version': 1, 'remote_id': 'routine-approved'},
        where: 'template_id = ?',
        whereArgs: [id],
      );
      await fixture.db.insert('central_entity_identities', {
        'entity_type': 'qcTemplate',
        'entity_id': 'routine-approved',
        'local_ref': id,
        'approved_version': 1,
      });
      final section = await fixture.db.insert('qc_sections', {
        'template_id': id,
        'title': 'Items',
        'order_index': 0,
      });
      for (var i = 0; i < 3; i++) {
        await fixture.db.insert('qc_items', {
          'section_id': section,
          'template_id': id,
          'label': 'Check $i',
          'order_index': i,
        });
      }
      final repository = RoutineListsRepositoryImpl(
        dbHelper: fixture.helper,
        guard: SessionWriteGuard(
          source: SessionSource(() => session),
          isOnline: () => true,
        ),
        audit: QcAuditRepo(
          dbHelper: fixture.helper,
          actorReader: () => QcActor.fromSession(session),
        ),
        templates: templates,
        inspections: QcInspectionRepo(fixture.helper),
        queue: queue,
      );
      await expectLater(
        repository.saveRoutineList(
          templateId: id,
          name: 'Renamed routine',
          items: ['Check 0', 'Check 1', 'Check 2'],
        ),
        throwsA(isA<CentralDraftPending>()),
      );
      final writes = (await outbox.list()).single.payload['writes'] as List;
      expect(writes.map((w) => w['entityType']), ['qcTemplate', 'qcAudit']);
      expect(
        (await fixture.db.query('qc_templates')).single['name'],
        'Routine',
      );
    },
  );

  for (final fields in [25, 1000]) {
    test(
      'actual analysis repository packs $fields list fields into one atomic analysis effect',
      () async {
        await LabRepo.registerUnit(fixture.db, '%');
        final unit = (await fixture.db.query(
          'lab_units',
          where: 'symbol = ?',
          whereArgs: ['%'],
        )).single;
        await fixture.db.update(
          'lab_units',
          {'version': 1, 'remote_version': 1, 'sync_state': 'synced'},
          where: 'id = ?',
          whereArgs: [unit['id']],
        );
        await fixture.db.insert('central_entity_identities', {
          'entity_type': 'labUnit',
          'entity_id': 'unit-percent',
          'local_ref': unit['id'],
          'approved_version': 1,
        });
        await expectLater(
          lab().createAnalysis(
            name: 'Large definition $fields',
            dynamicFields: List.generate(fields, (i) => 'Field $i'),
            fieldChemicalLinks: List.generate(
              fields,
              (i) => {
                'dynamic_field': 'Field $i',
                'kind': 'list',
                'list_values': [1, 2, 3],
              },
            ),
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        expect(await fixture.db.query('lab_analyses'), isEmpty);
        expect(await fixture.db.query('lab_field_chemical_links'), isEmpty);
        final drafts = await fixture.db.query('drafts');
        expect(drafts, hasLength(1));
        final writes =
            (jsonDecode(drafts.single['payload'] as String) as Map)['writes']
                as List;
        expect(writes, hasLength(1));
        expect(writes.where((w) => w['entityType'] == 'labFieldLink'), isEmpty);
        final config =
            jsonDecode(writes.single['payload']['formulaJson'] as String)
                as Map;
        expect(config['field_configs'], hasLength(fields));
        expect(
          (config['field_configs'] as List).every(
            (r) => '${r['list_values']}' == '[1.0, 2.0, 3.0]',
          ),
          isTrue,
        );
        expect(await outbox.list(), hasLength(1));
      },
    );
  }

  for (final action in ['formula', 'consumption', 'delete']) {
    test(
      'packed chemical definition $action preserves approved cache and stages one root',
      () async {
        final ids = <int>[];
        for (var i = 0; i < 7; i++) {
          final id = await fixture.db.insert('lab_inventory', {
            'name': 'Packed reagent $i',
            'category': 'liquid',
            'unit': 'mL',
            'current_qty': 100,
            'created_at': '2026-11-03',
            'updated_at': '2026-11-03',
          });
          ids.add(id);
          await fixture.db.insert('central_entity_identities', {
            'entity_type': 'inventoryItem',
            'entity_id': 'packed-stock-$i',
            'local_ref': id,
            'approved_version': 1,
          });
        }
        final defs = [
          for (var i = 0; i < 3; i++)
            {
              'kind': 'fixed',
              'inventoryId': 'packed-stock-$i',
              'quantity': i + 1,
              'unit': 'mL',
            },
          for (var i = 3; i < 7; i++)
            {
              'kind': 'link',
              'inventoryId': 'packed-stock-$i',
              'field': 'V$i',
              'unit': 'mL',
            },
        ];
        final formula = jsonEncode({
          'expression': 'V3',
          'chemical_definitions': defs,
          'field_configs': [
            for (var i = 3; i < 7; i++)
              {'dynamic_field': 'V$i', 'kind': 'link'},
          ],
        });
        final id = await fixture.db.insert('lab_analyses', {
          'name': 'Packed analysis',
          'unit': '%',
          'dynamic_fields_json': '["V3","V4","V5","V6"]',
          'formula_json': formula,
          'created_at': '2026-11-03',
          'active': 1,
          'version': 1,
          'remote_version': 1,
          'sync_state': 'synced',
        });
        await fixture.db.insert('central_entity_identities', {
          'entity_type': 'labAnalysis',
          'entity_id': 'packed-analysis',
          'local_ref': id,
          'approved_version': 1,
        });
        await expectLater(
          action == 'delete'
              ? lab().deleteAnalysis(id)
              : action == 'formula'
              ? lab().updateAnalysis(analysisId: id, formula: 'V3*2')
              : lab().updateAnalysis(
                  analysisId: id,
                  items: [
                    {'inventory_id': ids[0], 'qty_per_sample': 9, 'unit': 'mL'},
                  ],
                  fieldChemicalLinks: [
                    {
                      'dynamic_field': 'V6',
                      'kind': 'link',
                      'inventory_id': ids[6],
                      'unit': 'mL',
                    },
                  ],
                ),
          throwsA(isA<CentralDraftPending>()),
        );
        final writes = (await outbox.list()).single.payload['writes'] as List;
        expect(writes, hasLength(1));
        final write = writes.single as Map;
        expect(write['entityId'], 'packed-analysis');
        expect(write['operation'], action == 'delete' ? 'tombstone' : 'update');
        final definitions =
            (write['payload'] as Map)['chemicalDefinitions'] as List;
        expect(definitions, hasLength(action == 'consumption' ? 2 : 7));
        if (action == 'consumption') {
          expect((definitions.first as Map)['quantity'], 9);
          expect((definitions.last as Map)['inventoryId'], 'packed-stock-6');
        }
        expect(
          (await fixture.db.query(
            'lab_analyses',
            where: 'id = ?',
            whereArgs: [id],
          )).single['formula_json'],
          formula,
        );
        expect(await fixture.db.query('lab_analysis_items'), isEmpty);
        expect(await fixture.db.query('lab_field_chemical_links'), isEmpty);
      },
    );
  }

  for (final directRanges in [false, true]) {
    for (final changedCount in [0, 1, 6]) {
      test(
        'product with 25 references sends only actual changes: ranges=$directRanges changed=$changedCount',
        () async {
          final db = fixture.db;
          final reference = <String, dynamic>{
            for (var i = 0; i < 25; i++) 'Metric $i': '4-8',
          };
          final productId = await db.insert('lab_products', {
            'name': 'Delta product',
            'created_at': '2026-11-08',
            'active': 1,
            'chemical_reference_json': jsonEncode(reference),
            'remote_id': 'delta-product',
            'remote_version': 1,
            'version': 1,
            'sync_state': 'synced',
          });
          await db.insert('central_entity_identities', {
            'entity_type': 'labProduct',
            'entity_id': 'delta-product',
            'local_ref': productId,
            'approved_version': 1,
          });
          final ranges = <Map<String, dynamic>>[];
          for (var i = 0; i < 25; i++) {
            final analysisId = await db.insert('lab_analyses', {
              'name': 'Metric $i',
              'unit': '%',
              'created_at': '2026-11-08',
              'active': 1,
              'remote_version': 1,
              'remote_id': 'analysis-$i',
            });
            final rangeId = await db.insert('lab_product_analyses', {
              'product_id': productId,
              'analysis_id': analysisId,
              'min_value': 4.0,
              'max_value': 8.0,
              'unit': '%',
              'is_required': 0,
              'remote_version': 1,
              'version': 1,
              'remote_id': 'range-$i',
              'sync_state': 'synced',
            });
            for (final row in [
              ('labAnalysis', analysisId, 'analysis-$i'),
              ('labProductAnalysis', rangeId, 'range-$i'),
            ]) {
              await db.insert('central_entity_identities', {
                'entity_type': row.$1,
                'entity_id': row.$3,
                'local_ref': row.$2,
                'approved_version': 1,
              });
            }
            ranges.add({
              'analysis_id': analysisId,
              'min_value': 4,
              'max_value': i < changedCount ? 9 : 8,
              'unit': '%',
              'is_required': 0,
            });
          }
          for (var i = 0; i < changedCount; i++) {
            reference['Metric $i'] = '4-9';
          }
          await expectLater(
            lab().updateProduct(productId, {
              'description': 'Edited description',
              if (directRanges)
                'ranges': ranges
              else
                'chemical_reference': reference,
            }),
            throwsA(isA<CentralDraftPending>()),
          );
          final writes = (await outbox.list()).single.payload['writes'] as List;
          expect(writes, hasLength(changedCount + 1));
          expect(
            writes.where((w) => w['entityType'] == 'labAnalysis'),
            isEmpty,
          );
          if (changedCount > 0) {
            final link = writes.firstWhere(
              (w) => w['entityType'] == 'labProductAnalysis',
            );
            expect(link['entityId'], 'range-0');
            expect(link['payload']['maxValue'], 9);
          }
          expect(
            (await db.query(
              'lab_product_analyses',
              where: 'remote_id = ?',
              whereArgs: ['range-0'],
            )).single['max_value'],
            8,
          );
        },
      );
    }
  }

  test('saving identical product fields creates no command or draft', () async {
    final id = await fixture.db.insert('lab_products', {
      'name': 'Unchanged product',
      'category': 'Feed',
      'description': 'Same',
      'created_at': '2026-11-08',
      'active': 1,
      'remote_id': 'unchanged-product',
      'remote_version': 1,
      'version': 1,
      'sync_state': 'synced',
    });
    await fixture.db.insert('central_entity_identities', {
      'entity_type': 'labProduct',
      'entity_id': 'unchanged-product',
      'local_ref': id,
      'approved_version': 1,
    });
    final result = await lab().updateProduct(id, {
      'name': 'Unchanged product',
      'category': 'Feed',
      'description': 'Same',
    });
    expect(result['name'], 'Unchanged product');
    expect(await outbox.list(), isEmpty);
    expect(await fixture.db.query('drafts'), isEmpty);
    expect(
      (await fixture.db.query(
        'lab_products',
        where: 'id = ?',
        whereArgs: [id],
      )).single['version'],
      1,
    );
  });

  for (final remove in [false, true]) {
    test(
      'product reference ${remove ? 'removal stages a tombstone' : 'edit preserves analysis identity and captures a new unit'}',
      () async {
        final db = fixture.db;
        final productId = await db.insert('lab_products', {
          'name': 'QA product',
          'created_at': '2026-11-02',
          'active': 1,
          'chemical_reference_json': '{"Protein":"10-20"}',
          'remote_version': 1,
        });
        final analysisId = await db.insert('lab_analyses', {
          'name': 'Protein',
          'unit': '%',
          'created_at': '2026-11-02',
          'active': 1,
          'remote_version': 1,
        });
        final rangeId = await db.insert('lab_product_analyses', {
          'product_id': productId,
          'analysis_id': analysisId,
          'min_value': 10,
          'max_value': 20,
          'unit': '%',
          'remote_version': 1,
        });
        for (final row in [
          ('labProduct', productId),
          ('labAnalysis', analysisId),
          ('labProductAnalysis', rangeId),
        ]) {
          await db.insert('central_entity_identities', {
            'entity_type': row.$1,
            'entity_id': 'approved-${row.$1}',
            'local_ref': row.$2,
            'approved_version': 1,
          });
        }
        await expectLater(
          lab().updateProduct(productId, {
            'chemical_reference': remove
                ? <String, dynamic>{}
                : <String, dynamic>{
                    'Protein': {'value': '12-22', 'unit': 'QA-custom-unit'},
                  },
          }),
          throwsA(isA<CentralDraftPending>()),
        );
        final writes = (await outbox.list()).single.payload['writes'] as List;
        final range = writes.cast<Map>().singleWhere(
          (w) => w['entityType'] == 'labProductAnalysis',
        );
        expect(range['entityId'], 'approved-labProductAnalysis');
        expect(range['operation'], remove ? 'tombstone' : 'update');
        expect(range['expectedVersion'], 1);
        if (!remove) {
          final unit = writes.cast<Map>().singleWhere(
            (w) => w['entityType'] == 'labUnit',
          );
          expect(unit['payload']['symbol'], 'QA-custom-unit');
          expect(range['payload']['unit'], 'QA-custom-unit');
        }
        // Neither staging path changes the approved cache or its original row.
        final original = (await db.query(
          'lab_product_analyses',
          where: 'id = ?',
          whereArgs: [rangeId],
        )).single;
        expect(original['min_value'], 10);
        expect(original['deleted_at'], isNull);
      },
    );
  }

  test(
    'the actual inspection screen repository stages a full inspection without changing the archive',
    () async {
      await fixture.db.update('reference_materials', {
        'physical_reference_json': '{"color":"good"}',
      }, where: 'id = 1');
      final repository = ServerConfirmedInspectionRepository(
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
    'first product inspection stages without publishing its local FK helper',
    () async {
      final productId = await fixture.db.insert('lab_products', {
        'name': 'Launch product',
        'category': 'Feed',
        'description': '',
        'created_at': '2026-11-01',
        'active': 1,
        'remote_id': 'server-product-1',
      });
      await fixture.db.insert('central_entity_identities', {
        'entity_type': 'labProduct',
        'entity_id': 'server-product-1',
        'local_ref': productId,
        'approved_version': 1,
      });
      final repository = ServerConfirmedInspectionRepository(
        dbHelper: fixture.helper,
        referenceRepo: ReferenceRepo(
          dbHelper: fixture.helper,
          deviceTagProvider: () async => 'TEST',
        ),
        guard: SessionWriteGuard(
          source: SessionSource(() => session),
          isOnline: () => true,
        ),
        queue: queue,
        audit: AuditLogger(queue: queue, session: () => session),
      );
      await expectLater(
        repository.create({
          'inspection_kind': 'product',
          'product_id': productId,
          'entry_code': 'PRODUCT-FIRST',
          'formula_number': 'F-1',
          'batch_number': 'B-1',
          'inspection_date': '2026-11-01',
          'sample_taken_by': 'Valid Taker',
          'sample_names': ['Sample 1'],
          'physical_results': <String, dynamic>{},
          'chemical_results': <String, dynamic>{},
        }, const UserContext(id: 1, fullName: 'Admin', role: 'Admin')),
        throwsA(isA<CentralDraftPending>()),
      );
      final writes = (await outbox.list()).single.payload['writes'] as List;
      expect(writes, hasLength(1));
      expect(writes.single['entityType'], 'sample');
      expect(
        writes.single['relations']['productId']['entityId'],
        'server-product-1',
      );
      expect(writes.single['relations'], isNot(contains('materialId')));
      expect(await fixture.db.query('inspections'), isEmpty);
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

  test(
    'offline save remains an unsent draft until explicit online submission',
    () async {
      var online = false;
      fixture.helper.businessGateway = CentralAuthoringGateway(
        databaseHelper: fixture.helper,
        source: SessionSource(() => session),
        outbox: outbox,
        isOnline: () => online,
        chooseOfflineDraft: () async => true,
      );
      await expectLater(
        lab().addInventoryItem(
          name: 'Offline intent',
          category: 'powder',
          unit: 'g',
          qty: 10,
          minQty: 1,
          user: {'id': 1, 'full_name': 'Admin'},
        ),
        throwsA(isA<CentralDraftPending>()),
      );
      expect(await fixture.db.query('command_outbox'), isEmpty);
      expect(await fixture.db.query('lab_inventory'), isEmpty);
      final draft = (await fixture.db.query('drafts')).single;
      expect(draft['state'], 'local_draft');
      final service = DomainDraftService(
        drafts: DraftsStore(fixture.helper),
        outbox: outbox,
        source: SessionSource(() => session),
        isOnline: () => online,
      );
      await expectLater(
        service.submit(draft['id'] as String),
        throwsA(isA<ValidationError>()),
      );
      online = true;
      // Restoring connectivity alone cannot create or send an operation.
      expect(await fixture.db.query('command_outbox'), isEmpty);
      final staged = await service.submit(draft['id'] as String);
      expect(staged.schemaVersion, commandSchemaVersion);
      expect(await fixture.db.query('command_outbox'), hasLength(1));
      expect(
        (await fixture.db.query('drafts')).single['state'],
        'waiting_send',
      );
      await expectLater(
        service.submit(draft['id'] as String),
        throwsA(isA<ValidationError>()),
      );
      expect(await fixture.db.query('command_outbox'), hasLength(1));
    },
  );

  test('offline cancellation leaves no draft or request', () async {
    fixture.helper.businessGateway = CentralAuthoringGateway(
      databaseHelper: fixture.helper,
      source: SessionSource(() => session),
      outbox: outbox,
      isOnline: () => false,
      chooseOfflineDraft: () async => false,
    );
    await expectLater(
      lab().addInventoryItem(
        name: 'Cancelled',
        category: 'powder',
        unit: 'g',
        qty: 10,
        minQty: 1,
        user: {'id': 1, 'full_name': 'Admin'},
      ),
      throwsA(isA<BusinessActionCancelled>()),
    );
    for (final table in [
      'lab_inventory',
      'drafts',
      'command_outbox',
      'central_command_entities',
    ]) {
      expect(await fixture.db.query(table), isEmpty, reason: table);
    }
  });

  ServerConfirmedReferenceRepository references() =>
      ServerConfirmedReferenceRepository(
        dbHelper: fixture.helper,
        guard: SessionWriteGuard(
          source: SessionSource(() => session),
          isOnline: () => true,
        ),
        queue: queue,
        audit: AuditLogger(queue: queue, session: () => session),
      );

  test(
    'a refused edit permits a corrected edit without restarting or closing history',
    () async {
      var refuse = true;
      fixture.helper.businessGateway = CentralAuthoringGateway(
        databaseHelper: fixture.helper,
        source: SessionSource(() => session),
        outbox: outbox,
        isOnline: () => true,
        complete: (entry) async {
          if (!refuse) return false;
          await outbox.claim(operationId: entry.operationId, limit: 1);
          await outbox.settleTerminal(
            entry.operationId,
            state: OutboxState.rejected,
            code: CommandErrorCodes.permissionDenied,
            message: 'Denied by server',
          );
          throw const ValidationError('Denied by server');
        },
      );
      Future<int> edit(String name) => references().saveMaterialDefinition(
        id: 1,
        materialName: name,
        materialCode: 'CEM',
        bounds: [],
      );
      await expectLater(edit('Refused edit'), throwsA(isA<ValidationError>()));
      expect(await fixture.db.query('central_command_entities'), isEmpty);
      refuse = false;
      await expectLater(
        edit('Corrected edit'),
        throwsA(isA<CentralDraftPending>()),
      );
      final requests = await outbox.list();
      expect(requests, hasLength(2));
      expect(requests.map((e) => e.operationId).toSet(), hasLength(2));
      expect(requests.map((e) => e.state).toSet(), {
        OutboxState.rejected,
        OutboxState.pending,
      });
      expect(
        (await fixture.db.query(
          'reference_materials',
          where: 'id = 1',
        )).single['material_name'],
        'Cement',
      );
    },
  );

  test(
    'material and new parameter, analysis and bounds are one atomic request',
    () async {
      await expectLater(
        references().saveMaterialDefinition(
          materialName: 'Atomic material',
          materialCode: 'ATM',
          chemicalReference: {'Atomic analysis': '1 - 20'},
          bounds: [
            {
              'parameter_name': 'Atomic analysis',
              'parameter_type': 'chemical',
              'unit': '',
              'min_value': 1,
              'max_value': 20,
              'precision': 2,
              'is_required': true,
            },
          ],
        ),
        throwsA(isA<CentralDraftPending>()),
      );
      final writes = (await outbox.list()).single.payload['writes'] as List;
      expect(writes, hasLength(4));
      expect(
        writes.map((w) => w['entityType']),
        containsAll([
          'referenceMaterial',
          'parameter',
          'labAnalysis',
          'materialBound',
        ]),
      );
      final bound = writes.singleWhere(
        (w) => w['entityType'] == 'materialBound',
      );
      expect(bound['payload']['minValue'], 1);
      expect(bound['payload']['maxValue'], 20);
      expect(
        await fixture.db.query(
          'reference_materials',
          where: 'material_code = ?',
          whereArgs: ['ATM'],
        ),
        isEmpty,
      );
      expect(await fixture.db.query('material_parameter_bounds'), isEmpty);
    },
  );

  test(
    'renaming a material with ten unchanged bounds spends only one effect',
    () async {
      final bounds = <Map<String, dynamic>>[];
      for (var i = 0; i < 10; i++) {
        final name = 'Existing analysis $i';
        final pid = await fixture.db.insert('parameters', {
          'parameter_name': name,
          'parameter_type': 'chemical',
          'unit': '',
          'imported_at': '2026-11-01',
        });
        await fixture.db.insert('lab_analyses', {
          'name': name,
          'parameter_id': pid,
          'unit': '',
          'created_at': '2026-11-01',
        });
        await fixture.db.insert('material_parameter_bounds', {
          'material_id': 1,
          'parameter_id': pid,
          'parameter_type': 'chemical',
          'unit': '',
          'min_value': 1,
          'max_value': 20,
          'precision': 2,
          'is_required': 0,
        });
        bounds.add({
          'parameter_name': name,
          'parameter_type': 'chemical',
          'unit': '',
          'min_value': 1,
          'max_value': 20,
          'precision': 2,
          'is_required': false,
        });
      }
      await expectLater(
        references().saveMaterialDefinition(
          id: 1,
          materialName: 'Renamed only',
          materialCode: 'CEM',
          bounds: bounds,
        ),
        throwsA(isA<CentralDraftPending>()),
      );
      final writes = (await outbox.list()).single.payload['writes'] as List;
      expect(writes, hasLength(1));
      expect(writes.single['entityType'], 'referenceMaterial');
      expect(
        (await fixture.db.query(
          'reference_materials',
          where: 'id = 1',
        )).single['material_name'],
        'Cement',
      );
      expect(
        await fixture.db.query('material_parameter_bounds'),
        hasLength(10),
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

  test('a queued record cannot hide an unqueued shared mutation', () async {
    await expectLater(
      fixture.helper.businessTransaction((txn) async {
        final id = await txn.insert(
          'inspections',
          sampleRow(entryCode: 'PARTIAL'),
        );
        await queue.enqueue(
          txn,
          entityType: 'sample',
          entityId: 'PARTIAL',
          localRef: id,
          operation: 'create',
          baseVersion: 0,
          payload: {'entryCode': 'PARTIAL', 'updatedBy': 'uid_admin'},
        );
        await txn.update('reference_materials', {
          'material_name': 'Omitted',
        }, where: 'id = 1');
      }),
      throwsA(isA<StateError>()),
    );
    expect(await fixture.db.query('inspections'), isEmpty);
    expect(
      (await fixture.db.query('reference_materials')).single['material_name'],
      'Cement',
    );
    expect(await fixture.db.query('command_outbox'), isEmpty);
    expect(await fixture.db.query('drafts'), isEmpty);
  });

  test(
    'the request contains the final row even when enqueue preceded a later edit',
    () async {
      await expectLater(
        fixture.helper.businessTransaction((txn) async {
          final id = await txn.insert(
            'inspections',
            sampleRow(entryCode: 'FINAL'),
          );
          await queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'FINAL',
            localRef: id,
            operation: 'create',
            baseVersion: 0,
            payload: {'entryCode': 'STALE', 'updatedBy': 'uid_admin'},
          );
          await txn.update(
            'inspections',
            {'supplier': 'Final supplier'},
            where: 'id = ?',
            whereArgs: [id],
          );
        }),
        throwsA(isA<CentralDraftPending>()),
      );
      final request = (await fixture.db.query('command_outbox')).single;
      final writes =
          (jsonDecode(request['payload'] as String) as Map)['writes'] as List;
      expect(writes.single['payload']['entryCode'], 'FINAL');
      expect(writes.single['payload']['supplier'], 'Final supplier');
      expect(await fixture.db.query('inspections'), isEmpty);
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
    'a locally unauthorized write leaves neither an inspection nor an outbox command',
    () async {
      const nutrition = AppSession(
        uid: 'uid_admin',
        organizationId: 'org_test',
        memberId: 'm1',
        deviceId: 'dev_1',
        role: 'nutritionist',
        status: 'active',
      );
      await fixture.db.update('central_sync_state', {'role': 'nutritionist'});
      fixture.helper.businessGateway = CentralAuthoringGateway(
        databaseHelper: fixture.helper,
        source: SessionSource(() => nutrition),
        outbox: outbox,
      );
      await expectLater(
        fixture.helper.businessTransaction((txn) async {
          final id = await txn.insert(
            'inspections',
            sampleRow(entryCode: 'FORBIDDEN'),
          );
          await queue.enqueue(
            txn,
            entityType: 'sample',
            entityId: 'FORBIDDEN',
            localRef: id,
            operation: 'create',
            baseVersion: 0,
            payload: {'entryCode': 'FORBIDDEN', 'updatedBy': 'uid_admin'},
          );
        }),
        throwsA(isA<AuthorizationError>()),
      );
      expect(await fixture.db.query('inspections'), isEmpty);
      expect(await fixture.db.query('command_outbox'), isEmpty);
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

  test(
    'authoring refuses while the archive is missing or not ready and writes nothing',
    () async {
      // Fresh device: the driver has not installed a state row yet.
      await fixture.db.delete(
        'central_sync_state',
        where: 'organization_id = ?',
        whereArgs: ['org_test'],
      );
      await expectLater(
        fixture.helper.businessTransaction((txn) async {
          await txn.insert('inspections', sampleRow(entryCode: 'Bootstrap1'));
        }),
        throwsA(isA<ArchiveNotReadyError>()),
      );
      // Download interrupted: the snapshot exists but events are still applying.
      await fixture.db.insert('central_sync_state', {
        'organization_id': 'org_test',
        'uid': 'uid_admin',
        'role': 'admin',
        'bootstrap_state': 'catching_up',
        'applied_sequence': 1,
      });
      await expectLater(
        fixture.helper.businessTransaction((txn) async {
          await txn.insert('inspections', sampleRow(entryCode: 'Bootstrap2'));
        }),
        throwsA(isA<ArchiveNotReadyError>()),
      );
      for (final table in ['inspections', 'drafts', 'command_outbox']) {
        expect(
          await fixture.db.query(table),
          isEmpty,
          reason: '$table must not change on a not-ready archive',
        );
      }
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
