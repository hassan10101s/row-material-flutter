import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/central_projection.dart';
import 'package:material_lab/core/commands/central_sync_driver.dart';
import 'package:material_lab/core/commands/central_sync_transport.dart';
import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_run_scope.dart';

import '../sync/sync_test_fixture.dart';

/// Disk-staged bootstrap (production acceptance 2): pages land in
/// `central_bootstrap_staging` one transaction at a time, change events
/// committed during the download merge in under version rules, and one
/// transaction installs everything from staging â€” resumable, and never
/// holding the whole organization in memory.
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

  Future<ApprovedRecord> material({
    int version = 1,
    String updatedAt = '2026-10-26T00:00:00.000Z',
  }) async {
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
    final data = approved(
      buildRemotePayload(
        SyncEntity.byType('referenceMaterial')!,
        raw,
        context,
        asCreate: true,
      ),
      'new-material',
      version: version,
    )
      ..['updatedAt'] = updatedAt;
    return ApprovedRecord(
      entityType: 'referenceMaterial',
      entityId: 'new-material',
      version: version,
      data: data,
    );
  }

  ApprovedRecord sample({int version = 1, String? deletedAt}) {
    final row = sampleRow(entryCode: 'STAGED-1')
      ..['id'] = 913
      ..['material_id'] = 913;
    final data = approved(
      buildRemotePayload(
        SyncEntity.byType('sample')!,
        row,
        context,
        asCreate: true,
      ),
      'inspection-global',
      version: version,
      refs: {
        'materialId': {
          'entityType': 'referenceMaterial',
          'entityId': 'new-material',
          'version': 1,
        },
      },
    );
    if (deletedAt != null) data['deletedAt'] = deletedAt;
    return ApprovedRecord(
      entityType: 'sample',
      entityId: 'inspection-global',
      version: version,
      data: data,
    );
  }

  Map<String, dynamic> eventFrame(
    int sequence,
    List<ApprovedRecord> records, {
    String committedAt = '2026-10-26T00:00:00.000Z',
  }) => {
    'throughSequence': sequence,
    'events': [
      {
        'sequence': sequence,
        'operationId': 'op-$sequence',
        'committedAt': committedAt,
        'records': [
          for (final record in records)
            {
              'entityType': record.entityType,
              'entityId': record.entityId,
              'version': record.version,
              'data': record.data,
            },
        ],
      },
    ],
    'hasMore': false,
  };

  /// Serves the material on its snapshot page, empty pages for every other
  /// entity type, and drives `beginSnapshot` / `events` from counters.
  /// Returns the driver and its counting transport so tests can assert on
  /// the resumed run's page count.
  Future<(CentralSyncDriver, _CountingTransport)> driver({
    required List<int> beginWatermarks,
    Map<int, Map<String, dynamic>> eventsByCursor = const {},
    Object? Function(int afterSequence)? onEvents,
  }) async {
    var begins = 0;
    final transport = _CountingTransport((data) async {
      final mode = data['mode'] as String;
      switch (mode) {
        case 'beginSnapshot':
          return {
            'throughSequence': beginWatermarks[
                begins++ < beginWatermarks.length ? begins - 1 : beginWatermarks.length - 1],
            'manifestVersion': 1,
          };
        case 'snapshotPage':
          return {
            'throughSequence': data['throughSequence'],
            'records': '${data['entityType']}' == 'referenceMaterial'
                ? [
                    {
                      'entityType': 'referenceMaterial',
                      'entityId': 'new-material',
                      'version': 1,
                      'data': (await material()).data,
                    },
                  ]
                : const [],
            'nextAfter': null,
          };
        case 'events':
          final after = (data['afterSequence'] as num).toInt();
          final failure = onEvents?.call(after);
          if (failure != null) throw failure;
          return eventsByCursor[after] ??
              {
                'throughSequence': after,
                'events': const <Map<String, dynamic>>[],
                'hasMore': false,
              };
        default:
          throw StateError('Unexpected transport mode $mode');
      }
    });
    return (
      CentralSyncDriver(
        databaseHelper: fixture.helper,
        source: SessionSource(() => session),
        projection: projection,
        transport: transport,
        outbox: CommandOutbox(fixture.helper),
        metadata: SyncMetadata(fixture.helper),
      ),
      transport,
    );
  }

  group('staged bootstrap', () {
    test('a record created between the watermarks converges through the '
        'event merge and installs at H1', () async {
      final (d, _) = await driver(
        beginWatermarks: [0, 1],
        eventsByCursor: {0: eventFrame(1, [sample()])},
      );
      final cursor = await d.syncNow();

      expect(cursor, 1);
      final state = (await fixture.db.query('central_sync_state')).single;
      expect(state['bootstrap_state'], 'ready');
      expect(state['applied_sequence'], 1);
      // Material from the snapshot page, sample from the merged event.
      expect(await fixture.db.query('central_approved_records'), hasLength(2));
      final materialRow = (await fixture.db.query(
        'reference_materials',
        where: "remote_id = 'new-material'",
      )).single;
      final inspectionRow = (await fixture.db.query(
        'inspections',
        where: "remote_id = 'inspection-global'",
      )).single;
      expect(inspectionRow['material_id'], materialRow['id']);
      // Staging and the resume row are gone after the install.
      expect(await fixture.db.query('central_bootstrap_staging'), isEmpty);
      expect(await fixture.db.query('central_bootstrap_state'), isEmpty);
    });

    test('a document updated mid-download installs the newer version',
        () async {
      final (d, _) = await driver(
        beginWatermarks: [0, 1],
        eventsByCursor: {
          0: eventFrame(1, [
            await material(version: 2, updatedAt: '2026-10-26T01:00:00.000Z'),
          ]),
        },
      );
      await d.syncNow();

      final row = (await fixture.db.query(
        'reference_materials',
        where: "remote_id = 'new-material'",
      )).single;
      expect(row['remote_version'], 2);
      final stored = (await fixture.db.query(
        'central_approved_records',
        where: "entity_id = 'new-material'",
      )).single;
      expect(stored['version'], 2);
      expect(
        stored['payload_hash'],
        hashPayload(
(await material(version: 2, updatedAt: '2026-10-26T01:00:00.000Z')).data,
        ),
      );
    });

    test('a tombstone committed mid-download installs as a soft delete',
        () async {
      final (d, _) = await driver(
        beginWatermarks: [0, 2],
        eventsByCursor: {
          0: eventFrame(1, [sample()]),
          1: eventFrame(2, [
            sample(version: 2, deletedAt: '2026-10-26T02:00:00.000Z'),
          ]),
        },
      );
      final cursor = await d.syncNow();

      expect(cursor, 2);
      final row = (await fixture.db.query(
        'inspections',
        where: "remote_id = 'inspection-global'",
      )).single;
      expect(row['deleted_at'], '2026-10-26T02:00:00.000Z');
      expect(
        (await fixture.db.query('central_sync_state')).single['bootstrap_state'],
        'ready',
      );
    });

    test('a crash after the watermark resumes WITHOUT re-downloading pages',
        () async {
      final (failing, _) = await driver(
        beginWatermarks: [0, 1],
        onEvents: (after) => StateError('connection dropped'),
      );
      await expectLater(failing.syncNow(), throwsStateError);

      // The staged download survived: state row marks pages complete, the
      // canonical cache is still untouched.
      final resume = (await fixture.db.query('central_bootstrap_state')).single;
      expect(resume['h0'], 0);
      expect(resume['h1'], 1);
      expect(resume['manifest_version'], 1);
      expect(await fixture.db.query('central_sync_state'), isEmpty);
      expect(await fixture.db.query('central_approved_records'), isEmpty);
      expect(await fixture.db.query('central_bootstrap_staging'), hasLength(1));

      final (d, transport) = await driver(
        beginWatermarks: [0, 1],
        eventsByCursor: {
          0: eventFrame(1, [
            await material(version: 2, updatedAt: '2026-10-26T01:00:00.000Z'),
          ]),
        },
      );
      final cursor = await d.syncNow();
      expect(cursor, 1);
      // The resume path verified the manifest and went straight to the merge.
      expect(transport.snapshotPages, 0);
      expect(
        (await fixture.db.query('central_sync_state')).single['bootstrap_state'],
        'ready',
      );
      final row = (await fixture.db.query(
        'reference_materials',
        where: "remote_id = 'new-material'",
      )).single;
      expect(row['remote_version'], 2);
      expect(await fixture.db.query('central_bootstrap_state'), isEmpty);
    });

    test('two different payloads for the same approved version abort the '
        'bootstrap as a server inconsistency', () async {
      final (d, _) = await driver(
        beginWatermarks: [0, 1],
        eventsByCursor: {
          0: eventFrame(1, [
            // Same version as the staged snapshot record, different contents.
            await material(version: 1, updatedAt: '2026-10-26T09:00:00.000Z'),
          ]),
        },
      );
      await expectLater(d.syncNow(), throwsStateError);

      // Nothing was installed; the staged bytes and the resume row stay.
      expect(await fixture.db.query('central_sync_state'), isEmpty);
      expect(await fixture.db.query('central_approved_records'), isEmpty);
      final staged = (await fixture.db.query('central_bootstrap_staging')).single;
      expect(staged['version'], 1);
      expect(await fixture.db.query('central_bootstrap_state'), hasLength(1));
    });

    test('installFromStaging resolves a parent that stages after its child',
        () async {
      final scope = SyncRunScope(
        SessionSource(() => session),
        fixture.helper,
      );
      // The child is staged first â€” ordering by rowid puts it in an earlier
      // batch than the material it references.
      await projection.stageRecords([sample()], scope: scope);
      await projection.stageRecords([await material()], scope: scope);

      await projection.installFromStaging(throughSequence: 1, scope: scope);

      final materialRow = (await fixture.db.query(
        'reference_materials',
        where: "remote_id = 'new-material'",
      )).single;
      final inspectionRow = (await fixture.db.query(
        'inspections',
        where: "remote_id = 'inspection-global'",
      )).single;
      expect(inspectionRow['material_id'], materialRow['id']);
      expect(
        (await fixture.db.query('central_sync_state')).single['bootstrap_state'],
        'catching_up',
      );
      expect(await fixture.db.query('central_bootstrap_staging'), isEmpty);
    });
  });
}

class _CountingTransport implements CentralSyncTransport {
  _CountingTransport(this.handler);

  final Future<Map<String, dynamic>> Function(Map<String, Object?> data) handler;
  int snapshotPages = 0;
  int begins = 0;

  @override
  Future<Map<String, dynamic>> call(Map<String, Object?> data) async {
    if (data['mode'] == 'snapshotPage') snapshotPages++;
    if (data['mode'] == 'beginSnapshot') begins++;
    return handler(data);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
