import 'dart:convert';
import 'dart:io';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/central_authoring_gateway.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/inspections/data/offline_first_inspection_repository.dart';
import 'package:material_lab/features/lab/data/offline_first_lab_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

import '../test/sync/sync_test_fixture.dart';

/// Real repository output, used by the Node contract tests. No hand-written
/// subset of the UI payload stands in for the actual Dart serialization.
Future<void> generateDomainWireVectors(SyncFixture fixture) async {
  await fixture.seedOrganization();
  await fixture.db.update('reference_materials', {
    'physical_reference_json': '{"color":"good"}',
  }, where: 'id = 1');
  await fixture.db.insert('central_entity_identities', {
    'entity_type': 'referenceMaterial',
    'entity_id': 'server-material-1',
    'local_ref': 1,
    'approved_version': 1,
  });
  const session = AppSession(
    uid: 'uid_admin',
    organizationId: 'org_test',
    deviceId: 'dev_1',
    memberId: 'm1',
    role: 'admin',
    status: 'active',
  );
  final source = SessionSource(() => session);
  await fixture.db.insert('central_sync_state', {
    'organization_id': session.organizationId,
    'uid': session.uid,
    'role': session.rolesKey,
    'bootstrap_state': 'ready',
    'applied_sequence': 1,
  });
  final guard = SessionWriteGuard(source: source, isOnline: () => true);
  final queue = SyncQueue(fixture.helper);
  final outbox = CommandOutbox(fixture.helper);
  outbox.scopeProvider = () =>
      const CommandScope('org_test', 'uid_admin', 'dev_1');
  outbox.deviceProvider = () => 'dev_1';
  final audit = AuditLogger(queue: queue, session: () => session);
  fixture.helper.businessGateway = CentralAuthoringGateway(
    databaseHelper: fixture.helper,
    source: source,
    outbox: outbox,
  );
  final inspections = OfflineFirstInspectionRepository(
    dbHelper: fixture.helper,
    referenceRepo: ReferenceRepo(
      dbHelper: fixture.helper,
      deviceTagProvider: () async => 'TEST',
    ),
    guard: guard,
    queue: queue,
    audit: audit,
  );
  final lab = OfflineFirstLabRepository(
    dbHelper: fixture.helper,
    guard: guard,
    queue: queue,
    audit: audit,
  );
  const user = UserContext(
    id: 1,
    fullName: 'Test Admin',
    role: 'Admin',
    uid: 'uid_admin',
  );
  final vectors = <String, dynamic>{};
  Future<void> capture(String name, Future<Object?> Function() action) async {
    try {
      await action();
      throw StateError('Expected an unapproved draft');
    } on CentralDraftPending {
      final row = (await fixture.db.query(
        'command_outbox',
        orderBy: 'id DESC',
        limit: 1,
      )).single;
      vectors[name] = {
        'payload': jsonDecode(row['payload'] as String),
        'payloadHash': row['payload_hash'],
      };
    }
  }

  await capture(
    'inspection',
    () => inspections.create({
      'entry_code': 'WIRE-INSPECTION',
      'material_id': 1,
      'inspection_date': '2026-10-26',
      'supplier': 'Test Supplier',
      'sample_taken_by': 'Test Taker',
      'quantity': '10,5',
      'sample_names': ['S1'],
      'physical_results': {'color': 'good'},
      'decision_status': 'APPROVED',
    }, user),
  );
  await capture(
    'inventory',
    () => lab.addInventoryItem(
      name: 'Test Reagent',
      category: 'liquid',
      unit: 'mL',
      qty: 10,
      minQty: 1,
      user: {'id': 1, 'full_name': 'Test Admin'},
    ),
  );
  final row = sampleRow(entryCode: 'WIRE-EXISTING')
    ..['quantity'] = '10'
    ..['remote_id'] = 'server-existing-inspection'
    ..['remote_version'] = 1
    ..['version'] = 1
    ..['sync_state'] = 'synced';
  final id = await fixture.db.insert('inspections', row);
  await fixture.db.insert('central_entity_identities', {
    'entity_type': 'sample',
    'entity_id': 'server-existing-inspection',
    'local_ref': id,
    'approved_version': 1,
  });
  final original =
      buildRemotePayload(
          SyncEntity.byType('sample')!,
          {...row, 'id': id},
          const SyncPayloadContext(
            organizationId: 'org_test',
            uid: 'uid_admin',
            deviceId: 'dev_1',
            version: 1,
            versionField: 'version',
          ),
          asCreate: true,
        )
        ..['createdBy'] = 'uid_admin'
        ..['createdAt'] = '2026-10-26T00:00:00.000Z'
        ..['updatedAt'] = '2026-10-26T00:00:00.000Z'
        ..['parentRefs'] = {
          'materialId': {
            'entityType': 'referenceMaterial',
            'entityId': 'server-material-1',
            'version': 1,
          },
        };
  await capture(
    'qualityDecision',
    () => inspections.updateStatus(id, {
      'decision_status': 'FULL_REJECTION',
      'decision_reason': 'Test rejection',
      'rejected_quantity': '10',
    }, user),
  );
  vectors['qualityDecision']['current'] = original;
  await File(
    'functions/test/fixtures/domain_wire_vectors.json',
  ).writeAsString('${const JsonEncoder.withIndent('  ').convert(vectors)}\n');
}
