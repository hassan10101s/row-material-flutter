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

class FakeCentralTransport implements CentralSyncTransport {
  FakeCentralTransport(this.onCall);

  final Future<Map<String, dynamic>> Function(Map<String, Object?> data) onCall;
  void Function()? sessionSwitch;

  @override
  Future<Map<String, dynamic>> call(Map<String, Object?> data) async {
    final response = await onCall(data);
    if (response.remove('switchSession') == true) sessionSwitch?.call();
    return response;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  const otherSession = AppSession(
    uid: 'uid_other',
    organizationId: 'org_test',
    deviceId: 'device',
    memberId: 'member-2',
    role: 'viewer',
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
    await fixture.db.insert('central_sync_state', {
      'organization_id': 'org_test',
      'uid': 'uid_admin',
      'role': 'admin',
      'bootstrap_state': 'ready',
      'applied_sequence': 0,
    });
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

  Future<Map<String, dynamic>> materialData() async {
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
    return approved(
      buildRemotePayload(
        SyncEntity.byType('referenceMaterial')!,
        raw,
        context,
        asCreate: true,
      ),
      'new-material',
    );
  }

  Future<List<ApprovedRecord>> aggregate() async {
    final row = sampleRow(entryCode: 'CENTRAL-EVENT')
      ..['id'] = 913
      ..['material_id'] = 913;
    return [
      ApprovedRecord(
        entityType: 'sample',
        entityId: 'inspection-global',
        version: 1,
        data: approved(
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
        ),
      ),
      ApprovedRecord(
        entityType: 'referenceMaterial',
        entityId: 'new-material',
        version: 1,
        data: await materialData(),
      ),
    ];
  }

  Map<String, dynamic> withPlaceholder(Map<String, dynamic> data) => {
    ...data,
    'createdAt': centralCommitTimePlaceholder,
    'updatedAt': centralCommitTimePlaceholder,
  };

  group('commit-time placeholder resolution', () {
    test(
      'an event carrying the placeholder resolves to the approval time and hashes exactly like its snapshot twin',
      () async {
        // On the real server, the approval time IS the timestamp the live
        // document carries, so a resolved placeholder reproduces the twin.
        final real = await materialData();
        const approvalTime = '2026-10-26T00:00:00.000Z';
        final normalized = normalizeApprovedPayload(
          withPlaceholder(real),
          approvalTime,
        );
        expect(normalized, real);
        expect(normalized['updatedAt'], approvalTime);
        expect(hashPayload(normalized), hashPayload(real));
      },
    );

    test('a placeholder without a known approval time is rejected', () {
      final data = withPlaceholder(<String, dynamic>{'version': 1});
      expect(() => normalizeApprovedPayload(data, null), throwsStateError);
      expect(() => normalizeApprovedPayload(data, ''), throwsStateError);
    });

    test('the projection refuses to store a raw placeholder after-image',
        () async {
      final records = [
        for (final record in await aggregate())
          ApprovedRecord(
            entityType: record.entityType,
            entityId: record.entityId,
            version: record.version,
            data: withPlaceholder(record.data),
          ),
      ];
      await expectLater(
        projection.applyEvent(
          sequence: 1,
          operationId: 'poisoned',
          records: records,
        ),
        throwsStateError,
      );
      expect(await fixture.db.query('inspections'), isEmpty);
      expect(await fixture.db.query('central_approved_records'), isEmpty);
    });

    test(
      'a placeholder event applied through the projection lands with the real approval time',
      () async {
        const committedAt = '2026-10-26T08:30:00.000Z';
        final normalized = [
          for (final record in await aggregate())
            ApprovedRecord(
              entityType: record.entityType,
              entityId: record.entityId,
              version: record.version,
              data: normalizeApprovedPayload(
                withPlaceholder(record.data),
                committedAt,
              ),
            ),
        ];
        await projection.applyEvent(
          sequence: 1,
          operationId: 'legacy-event',
          records: normalized,
        );
        final material = normalized
            .singleWhere((record) => record.entityType == 'referenceMaterial')
            .data;
        final stored = (await fixture.db.query(
          'central_approved_records',
          where: 'entity_type = ?',
          whereArgs: ['referenceMaterial'],
        )).single;
        expect(stored['payload_hash'], hashPayload(material));
        expect(stored['payload'], contains(committedAt));
        expect(
          stored['payload'],
          isNot(contains(centralCommitTimePlaceholder)),
        );
        final row = (await fixture.db.query(
          'inspections',
          where: 'entry_code = ?',
          whereArgs: ['CENTRAL-EVENT'],
        )).single;
        expect(row['updated_at'], committedAt);
        expect(row['created_at'], committedAt);
      },
    );

    test(
      'hasCommitTimePlaceholder detects archives built from placeholder events',
      () async {
        expect(await projection.hasCommitTimePlaceholder(), isFalse);
        await fixture.db.insert('central_approved_records', {
          'entity_type': 'sample',
          'entity_id': 'inspection-global',
          'version': 1,
          'payload': '{"updatedAt":"$centralCommitTimePlaceholder"}',
          'payload_hash': 'legacy',
        });
        expect(await projection.hasCommitTimePlaceholder(), isTrue);
      },
    );
  });

  group('download run consistency', () {
    late List<String> calls;
    late List<Map<String, dynamic>> script;
    late AppSession current;
    late CentralSyncDriver driver;
    late List<Object> reported;

    setUp(() {
      current = session;
    });

    Future<void> pump() async {
      calls = [];
      script = [];
      reported = [];
      // The driver suite starts from a FRESH device: no central checkpoint.
      await fixture.db.delete('central_sync_state');
      final transport = FakeCentralTransport((data) async {
        final mode = data['mode'] as String;
        calls.add('$mode/${data['entityType'] ?? ''}');
        // Snapshot pages are answered lazily: every entity type gets an empty
        // page carrying its own watermark.
        if (mode == 'snapshotPage') {
          return {
            'throughSequence': data['throughSequence'],
            'records': const [],
            'nextAfter': null,
          };
        }
        return script.removeAt(0);
      });
      driver = CentralSyncDriver(
        databaseHelper: fixture.helper,
        source: SessionSource(() => current),
        projection: projection,
        transport: transport,
        outbox: CommandOutbox(fixture.helper),
        metadata: SyncMetadata(fixture.helper),
        onError: reported.add,
      );
    }

    Map<String, dynamic> beginFrame(int through) =>
        {'throughSequence': through, 'manifestVersion': 1};

    Map<String, dynamic> eventFrame(
      int sequence,
      List<ApprovedRecord> records, {
      String committedAt = '2026-10-26T00:00:00.000Z',
      bool hasMore = false,
      int through = 0,
    }) => {
      'throughSequence': through,
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
      'hasMore': hasMore,
    };

    test(
      'ready is granted only after the snapshot AND the change-event feed drain to a server head',
      () async {
        await pump();
        // The staged bootstrap probes the watermark twice: H0 before the
        // page download and H1 after it.
        script = [
          beginFrame(0),
          beginFrame(0),
          eventFrame(1, await aggregate()),
        ];
        final cursor = await driver.syncNow();
        expect(cursor, 1);
        final state = (await fixture.db.query(
          'central_sync_state',
        )).single;
        expect(state['bootstrap_state'], 'ready');
        expect(state['applied_sequence'], 1);
        expect(calls.first, 'beginSnapshot/');
        expect(reported, isEmpty);
        expect(
          await fixture.db.query('central_approved_records'),
          hasLength(2),
        );
      },
    );

    test(
      'a placeholder event from the pre-fix wire matches the snapshot twin fingerprint',
      () async {
        await pump();
        script = [
          beginFrame(0),
          beginFrame(0),
          eventFrame(1, [
            for (final record in await aggregate())
              ApprovedRecord(
                entityType: record.entityType,
                entityId: record.entityId,
                version: record.version,
                data: withPlaceholder(record.data),
              ),
          ]),
        ];
        await driver.syncNow();
        final stored = (await fixture.db.query(
          'central_approved_records',
          where: 'entity_type = ?',
          whereArgs: ['referenceMaterial'],
        )).single;
        // The event carried placeholders; the stored fingerprint must equal
        // the hash of the real-timestamp twin the snapshot channel delivers.
        expect(stored['payload_hash'], hashPayload(await materialData()));
        expect(
          (await fixture.db.query(
            'central_sync_state',
          )).single['bootstrap_state'],
          'ready',
        );
      },
    );

    test(
      'the state stays catching_up when the run stops before the feed drains',
      () async {
        await pump();
        script = [
          beginFrame(0),
          beginFrame(0),
          eventFrame(1, const [], hasMore: true, through: 2),
          // The head moved during the download; the next page finds a gap.
          {'throughSequence': 2, 'events': [], 'hasMore': false},
        ];
        await expectLater(
          driver.syncNow(),
          throwsA(isA<CentralSyncGap>()),
        );
        expect(
          (await fixture.db.query(
            'central_sync_state',
          )).single['bootstrap_state'],
          'catching_up',
        );
        expect(reported.single, isA<CentralSyncGap>());
      },
    );

      test(
      'an account switch between pages cancels the run instead of mixing sessions',
      () async {
        await pump();
        script = [beginFrame(0)];
        var snapshotPages = 0;
        final fake = FakeCentralTransport((data) async {
          final mode = data['mode'] as String;
          calls.add('$mode/${data['entityType'] ?? ''}');
          if (mode == 'snapshotPage') {
            snapshotPages += 1;
            if (snapshotPages == 2) {
              return {
                'throughSequence': 0,
                'records': const [],
                'nextAfter': null,
                'switchSession': true,
              };
            }
            return {
              'throughSequence': 0,
              'records': const [],
              'nextAfter': null,
            };
          }
          return script.removeAt(0);
        });
        fake.sessionSwitch = () => current = otherSession;
        driver = CentralSyncDriver(
          databaseHelper: fixture.helper,
          source: SessionSource(() => current),
          projection: projection,
          transport: fake,
          outbox: CommandOutbox(fixture.helper),
          metadata: SyncMetadata(fixture.helper),
          onError: reported.add,
        );
        await expectLater(
          driver.syncNow(),
          throwsA(isA<SyncRunCancelled>()),
        );
        // Nothing was materialized and no checkpoint exists for either account.
        expect(await fixture.db.query('central_approved_records'), isEmpty);
        expect(await fixture.db.query('central_sync_state'), isEmpty);
        expect(reported, isEmpty);
      },
    );

    test(
      'an archive built from placeholder events is re-downloaded before anything else',
      () async {
        await pump();
        // A "ready" legacy archive whose stored payload carries the placeholder.
        await fixture.db.insert('central_sync_state', {
          'organization_id': 'org_test',
          'uid': 'uid_admin',
          'role': 'admin',
          'bootstrap_state': 'ready',
          'applied_sequence': 5,
        });
        await fixture.db.insert('central_approved_records', {
          'entity_type': 'sample',
          'entity_id': 'inspection-global',
          'version': 1,
          'payload': '{"updatedAt":"$centralCommitTimePlaceholder"}',
          'payload_hash': 'legacy',
        });
        script = [
          beginFrame(5),
          beginFrame(5),
          {'throughSequence': 5, 'events': [], 'hasMore': false},
        ];
        await driver.syncNow();
        // Despite the ready state, the migration forced a full re-download.
        expect(calls.first, 'beginSnapshot/');
        final state = (await fixture.db.query(
          'central_sync_state',
        )).single;
        expect(state['bootstrap_state'], 'ready');
        expect(await projection.hasCommitTimePlaceholder(), isFalse);
      },
    );
  });
}
