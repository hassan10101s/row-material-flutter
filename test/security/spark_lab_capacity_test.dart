@Tags(['emulator'])
library;

import 'dart:convert';
import 'dart:io';
import 'package:material_lab/core/security/secure_payload_compiler.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/commands/central_authoring_gateway.dart';
import 'package:material_lab/core/commands/central_projection.dart';
import 'package:material_lab/core/commands/central_sync_driver.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/firestore_direct_command_transport.dart';
import 'package:material_lab/core/commands/firestore_direct_store.dart';
import 'package:material_lab/core/commands/firestore_direct_sync_reader.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';
import 'package:material_lab/features/lab/data/server_confirmed_lab_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import '../sync/sync_test_fixture.dart';

class _AlterProofCommit extends http.BaseClient {
  _AlterProofCommit(this.mutate);
  final void Function(List<dynamic>) mutate;
  final http.Client inner = http.Client();
  bool mutated = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request is http.Request && request.url.path.endsWith(':commit')) {
      final body = jsonDecode(request.body) as Map;
      mutate(body['writes'] as List);
      request.body = jsonEncode(body);
      mutated = true;
    }
    return inner.send(request);
  }

  @override
  void close() {
    inner.close();
    super.close();
  }
}

void main() {
  final host = Platform.environment['FIRESTORE_EMULATOR_HOST'];
  final authHost = Platform.environment['FIREBASE_AUTH_EMULATOR_HOST'];
  final enabled = host != null && authHost != null;
  const project = 'demo-materiallab';
  final org = 'spark_lab_${DateTime.now().microsecondsSinceEpoch}';
  final root = 'organizations/$org';
  late String uid, token;
  late FirestoreDirectStore store;
  late Map<String, dynamic> manifest;
  var device = 'dev0';
  SessionSource source() => SessionSource(
    () => AppSession(
      uid: uid,
      organizationId: org,
      deviceId: device,
      role: 'lab',
      status: 'active',
    ),
  );
  Future<void> seed(String path, Map<String, dynamic> data) async {
    final response = await http.patch(
      Uri.parse(
        'http://$host/v1/projects/$project/databases/(default)/documents/$path',
      ),
      headers: {
        'Authorization': 'Bearer owner',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'fields': {
          for (final e in data.entries)
            e.key: FirestoreDirectStore.encode(e.value),
        },
      }),
    );
    expect(response.statusCode, 200, reason: response.body);
  }

  FirestoreDirectCommandTransport transport() =>
      FirestoreDirectCommandTransport(
        store: store,
        source: source(),
        manifest: () async => manifest,
      );
  CentralSyncDriver driver(SyncFixture f) => CentralSyncDriver(
    databaseHelper: f.helper,
    source: source(),
    projection: CentralProjection(databaseHelper: f.helper, source: source()),
    transport: FirestoreDirectSyncReader(
      store: store,
      source: source(),
      manifest: () async => manifest,
    ),
    outbox: CommandOutbox(f.helper),
    metadata: SyncMetadata(f.helper),
  );
  Map<String, dynamic> analysisPayload(String name, [int fields = 25]) => {
    'configType': 'lab_analyses',
    'localId': 1,
    'name': name,
    'unit': '%',
    'description': '',
    'reference': '',
    'parameterId': null,
    'active': 1,
    'dynamicFieldsJson': jsonEncode(List.generate(fields, (i) => 'F$i')),
    'formulaJson': jsonEncode({
      'field_configs': List.generate(
        fields,
        (i) => {
          'dynamic_field': 'F$i',
          'kind': 'list',
          'list_values': [1, 2, 3],
        },
      ),
    }),
  };
  CommandEnvelope frame(String id, List<Map<String, dynamic>> writes) =>
      CommandEnvelope.create(
        organizationId: org,
        commandType: CommandTypes.domainCommit,
        entityId: id,
        expectedVersion: 0,
        payload: {'writes': writes},
        deviceId: device,
      );
  setUpAll(() async {
    if (!enabled) return;
    expect(host, matches(r'^(127\.0\.0\.1|localhost):\d+$'));
    expect(authHost, matches(r'^(127\.0\.0\.1|localhost):\d+$'));
    manifest =
        jsonDecode(
              await File(
                'tool/central_migration/domain_manifest.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    final response = await http.post(
      Uri.parse(
        'http://$authHost/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': '$org@example.test',
        'password': 'TestPassword123!',
        'returnSecureToken': true,
      }),
    );
    expect(response.statusCode, 200, reason: response.body);
    final user = jsonDecode(response.body) as Map;
    uid = user['localId'] as String;
    token = user['idToken'] as String;
    await seed('users/$uid', {
      'organizationId': org,
      'role': 'lab',
      'roles': ['lab'],
      'status': 'active',
    });
    await seed(root, {
      'status': 'active',
      'commandProtocol': {
        'enabled': true,
        'mode': firestoreDirectMode,
        'schemaVersion': 3,
        'domainManifestVersion': 1,
        'migrationId': 'test',
        'writePolicy': 'multi_authorized',
        'maintenance': false,
        'globalReferencesReady': true,
        'uniqueAdmissionComplete': true,
      },
    });
    for (var i = 0; i < 5; i++) {
      await seed('$root/devices/dev$i', {
        'uid': uid,
        'status': 'active',
        'readOnly': false,
      });
    }
    await seed('$root/counters/changeSequence', {'value': 0});
    await seed('$root/inventoryItems/reagent', {
      'organizationId': org,
      'remoteId': 'reagent',
      'localId': 1,
      'version': 1,
      'name': 'Reagent',
      'category': 'liquid',
      'unit': 'mL',
      'description': '',
      'currentQty': 100.0,
      'minQty': 0.0,
      'createdAt': DateTime.utc(2026),
      'updatedAt': DateTime.utc(2026),
      'createdBy': uid,
      'updatedBy': uid,
      'deviceId': 'dev0',
      'deletedAt': null,
    });
    store = FirestoreDirectStore(
      projectId: project,
      endpoint: Uri.parse('http://$host'),
      tokenProvider: () async => token,
    );
  });
  tearDownAll(() {
    if (enabled) store.close();
  });

  test(
    'twelve simple additions exhaust the atomic budget, replay once and reject forged proofs',
    () async {
      final writes = <Map<String, dynamic>>[
        for (var i = 0; i < 12; i++)
          {
            'entityType': 'worksheet',
            'entityId': 'capacity-sheet-$i',
            'operation': 'create',
            'expectedVersion': 0,
            'payload': {
              'localId': i + 1,
              'sourceType': 'sample',
              'status': 'DRAFT',
            },
            'relations': <String, dynamic>{},
          },
      ];
      final request = frame('twelve-simple', writes);
      for (final mutation in [
        'missing-image',
        'receipt',
        'shape',
        'proof',
        'tenant',
        'missing-proof',
        'proof-records',
      ]) {
        final client = _AlterProofCommit((effects) {
          final business = effects
              .where((w) => '${w['update']?['name']}'.contains('/worksheets/'))
              .toList();
          final fields = business.last['update']['fields'] as Map;
          if (mutation == 'missing-image') effects.remove(business.last);
          if (mutation == 'missing-proof') {
            effects.removeWhere(
              (w) =>
                  '${w['update']?['name']}'.contains('/simpleOperationProofs/'),
            );
          }
          if (mutation == 'proof-records') {
            final proof =
                effects.firstWhere(
                      (w) => '${w['update']?['name']}'.contains(
                        '/simpleOperationProofs/',
                      ),
                    )['update']['fields']
                    as Map;
            proof['recordPaths']['arrayValue']['values'].removeLast();
          }
          if (mutation == 'receipt') {
            effects.removeWhere(
              (w) => '${w['update']?['name']}'.contains('/commandReceipts/'),
            );
          }
          if (mutation == 'shape') fields['status'] = {'integerValue': '7'};
          if (mutation == 'tenant') {
            fields['organizationId'] = {'stringValue': 'foreign'};
          }
          if (mutation == 'proof') {
            fields['protocol']['mapValue']['fields']['effect']['mapValue']['fields']['entityId'] =
                {'stringValue': 'forged'};
          }
        });
        final altered = FirestoreDirectStore(
          projectId: project,
          endpoint: Uri.parse('http://$host'),
          tokenProvider: () async => token,
          client: client,
        );
        try {
          final result = await FirestoreDirectCommandTransport(
            store: altered,
            source: source(),
            manifest: () async => manifest,
          ).submit(request);
          expect(client.mutated, true, reason: mutation);
          expect(
            result.failure?.code,
            CommandErrorCodes.permissionDenied,
            reason: '$mutation ${result.failure?.toJson()}',
          );
          expect(await store.get('$root/worksheets/capacity-sheet-0'), isNull);
        } finally {
          altered.close();
        }
      }
      final before = store.usage.documentsWritten;
      final result = await transport().submit(request);
      expect(result.isApproved, true, reason: '${result.failure?.toJson()}');
      expect(store.usage.documentsWritten - before, 17);
      final committed = store.usage.documentsWritten;
      expect((await transport().submit(request)).toJson(), result.toJson());
      expect(store.usage.documentsWritten, committed);
      final oversized = frame('thirteen-simple', [
        ...writes,
        {...writes.last, 'entityId': 'capacity-sheet-extra'},
      ]);
      expect(
        (await transport().submit(oversized)).failure?.code,
        CommandErrorCodes.badPayload,
      );
    },
    skip: !enabled,
  );

  test(
    'six unique catalogue additions fit the budget and seven remain unsent',
    () async {
      List<Map<String, dynamic>> rows(int count) => [
        for (var i = 0; i < count; i++)
          {
            'entityType': 'parameter',
            'entityId': 'capacity-parameter-$i',
            'operation': 'create',
            'expectedVersion': 0,
            'payload': {
              'localId': i + 1,
              'parameterName': 'Capacity parameter $i',
              'unit': '%',
              'parameterType': 'chemical',
              'importedAt': '2026-11-08T00:00:00Z',
            },
            'relations': <String, dynamic>{},
          },
      ];
      final before = store.usage.documentsWritten;
      final oversized = await transport().submit(
        frame('seven-unique', rows(7)),
      );
      expect(oversized.failure?.code, CommandErrorCodes.badPayload);
      expect(store.usage.documentsWritten, before);
      final result = await transport().submit(frame('six-unique', rows(6)));
      expect(result.isApproved, true, reason: '${result.failure?.toJson()}');
      expect(store.usage.documentsWritten - before, 16);
    },
    skip: !enabled,
  );

  test(
    '36 chemical definitions fill nine proof blocks; missing, foreign and 37th entries fail',
    () async {
      final defs = <Map<String, dynamic>>[
        for (var i = 0; i < maxChemicalDefinitions; i++)
          {
            'kind': 'link',
            'inventoryId': 'reagent',
            'field': 'F$i',
            'unit': 'mL',
          },
      ];
      Map<String, dynamic> row(List<Map<String, dynamic>> entries) => {
        'entityType': 'labAnalysis',
        'entityId': 'maximum-chemical-definitions',
        'operation': 'create',
        'expectedVersion': 0,
        'relations': <String, dynamic>{},
        'payload': {
          ...analysisPayload('Maximum chemical definitions', entries.length),
          'chemicalDefinitions': entries,
        },
      };
      final request = frame('maximum-chemicals', [row(defs)]);
      for (final mutation in ['missing-block', 'foreign', '37th-entry']) {
        final client = _AlterProofCommit((effects) {
          if (mutation == 'missing-block') {
            effects.removeWhere(
              (w) => '${w['update']?['name']}'.endsWith('_8'),
            );
          }
          final fields =
              effects.firstWhere(
                    (w) => '${w['update']?['name']}'.contains('/labConfig/'),
                  )['update']['fields']
                  as Map;
          if (mutation == 'foreign') {
            fields['chemicalDefinitions'] = FirestoreDirectStore.encode([
              ...defs.take(35),
              {...defs.last, 'inventoryId': 'foreign'},
            ]);
          }
          if (mutation == '37th-entry') {
            fields['chemicalDefinitions'] = FirestoreDirectStore.encode([
              ...defs,
              {...defs.last, 'field': 'F36'},
            ]);
          }
        });
        final altered = FirestoreDirectStore(
          projectId: project,
          endpoint: Uri.parse('http://$host'),
          tokenProvider: () async => token,
          client: client,
        );
        try {
          final result = await FirestoreDirectCommandTransport(
            store: altered,
            source: source(),
            manifest: () async => manifest,
          ).submit(request);
          expect(client.mutated, true, reason: mutation);
          expect(
            result.failure?.code,
            CommandErrorCodes.permissionDenied,
            reason: '$mutation ${result.failure?.toJson()}',
          );
        } finally {
          altered.close();
        }
      }
      final tooMany = await transport().submit(
        frame('too-many-chemicals', [
          row([
            ...defs,
            {...defs.last, 'field': 'F36'},
          ]),
        ]),
      );
      expect(tooMany.failure?.code, CommandErrorCodes.badPayload);
      final result = await transport().submit(request);
      expect(result.isApproved, true, reason: '${result.failure?.toJson()}');
      expect(
        (await store.get(
          '$root/labConfig/maximum-chemical-definitions',
        ))!.data['chemicalDefinitions'],
        hasLength(36),
      );
    },
    skip: !enabled,
  );

  test(
    'Secure result plus two chemical deductions fits ten effects and deletes atomically',
    () async {
      final oldOrg = (await store.get(root))!.data;
      final cache = await openSyncFixture();
      dynamic remap(dynamic value) {
        if (value is String && value.startsWith('case-')) {
          return 'secure10-$value';
        }
        if (value is List) return value.map(remap).toList();
        if (value is Map) {
          return value.map(
            (k, v) => MapEntry('$k', k == 'name' ? 'Secure10 $v' : remap(v)),
          );
        }
        return value;
      }

      try {
        await seed(root, {
          ...oldOrg,
          'commandProtocol': {
            ...oldOrg['commandProtocol'] as Map,
            'secureFieldsEnabled': true,
          },
        });
        final fixture =
            remap(
                  jsonDecode(
                    await File(
                      'test/security/fixtures/lab_run_two_chemicals.json',
                    ).readAsString(),
                  ),
                )
                as Map;
        for (final raw in fixture['records'] as List) {
          final record = raw as Map;
          final data = Map<String, dynamic>.from(record['data'] as Map)
            ..['organizationId'] = org;
          for (final actor
              in manifest['entities'][record['type']]['actors'] as List) {
            if (data[actor] != null) data[actor as String] = uid;
          }
          await seed(
            '$root/${manifest['entities'][record['type']]['collection']}/${record['id']}',
            data,
          );
        }
        final writes = [
          for (final raw in fixture['writes'] as List)
            Map<String, dynamic>.from(raw as Map),
        ];
        for (final write in writes) {
          final payload = Map<String, dynamic>.from(write['payload'] as Map)
            ..['organizationId'] = org;
          for (final actor
              in manifest['entities'][write['entityType']]['actors'] as List) {
            if (payload[actor] != null) payload[actor as String] = uid;
          }
          write['payload'] = payload;
        }
        (writes.first['payload'] as Map)['secureResult'] = 1;
        await compileSecurePayloads(
          db: cache.db,
          session: source().session,
          writes: writes,
        );
        expect(writes, hasLength(10));
        expect(businessEffectLimit(writes), greaterThanOrEqualTo(10));
        final request = frame('secure-ten', writes);
        final saved = await transport().submit(request);
        expect(saved.isApproved, true, reason: '${saved.failure?.toJson()}');
        expect((await transport().submit(request)).toJson(), saved.toJson());
        final resultId = writes.first['entityId'];
        final public = (await store.get('$root/labResults/$resultId'))!.data;
        expect(public['secureResult'], 1);
        expect(public['resultText'], '');
        expect(public['dynamicValuesJson'], '{}');
        await expectLater(
          store.get('$root/labConfig/${writes.last['entityId']}'),
          throwsA(isA<DirectStoreError>()),
        );
        await driver(cache).syncNow();
        final outbox = CommandOutbox(cache.helper)
          ..scopeProvider = (() => CommandScope(org, uid, device))
          ..deviceProvider = () => device;
        cache.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: cache.helper,
          source: source(),
          outbox: outbox,
        );
        final queue = SyncQueue(cache.helper);
        final repo = ServerConfirmedLabRepository(
          dbHelper: cache.helper,
          guard: SessionWriteGuard(source: source(), isOnline: () => true),
          queue: queue,
          audit: AuditLogger(queue: queue, session: () => source().session),
        );
        final local = (await cache.db.query(
          'lab_sample_tests',
          where: 'remote_id = ?',
          whereArgs: [resultId],
        )).single;
        await expectLater(
          repo.deleteSampleTest(local['id'] as int),
          throwsA(isA<CentralDraftPending>()),
        );
        final deletion = (await outbox.list()).single.envelope();
        final effects = deletion.payload['writes'] as List;
        expect(effects, hasLength(7));
        expect(
          businessEffectLimit(effects),
          greaterThanOrEqualTo(effects.length),
        );
        final removed = await transport().submit(deletion);
        expect(
          removed.isApproved,
          true,
          reason: '${removed.failure?.toJson()}',
        );
        expect((await transport().submit(deletion)).toJson(), removed.toJson());
        expect(
          (await store.get('$root/labResults/$resultId'))!.data['deletedAt'],
          isNotNull,
        );
        for (final record in fixture['records'] as List) {
          if (record['type'] != 'inventoryItem') continue;
          final item = (await store.get(
            '$root/inventoryItems/${record['id']}',
          ))!.data;
          expect(item['currentQty'], record['data']['currentQty']);
        }
      } finally {
        await seed(root, oldOrg);
        await cache.dispose();
      }
    },
    skip: !enabled,
  );

  test(
    'actual-nine: result and two chemical deductions commit atomically and replay once',
    () async {
      final fixture =
          jsonDecode(
                await File(
                  'test/security/fixtures/lab_run_two_chemicals.json',
                ).readAsString(),
              )
              as Map;
      for (final raw in fixture['records'] as List) {
        final record = raw as Map;
        final data = Map<String, dynamic>.from(record['data'] as Map)
          ..['organizationId'] = org;
        for (final actor in [
          'createdBy',
          'updatedBy',
          'receivedBy',
          'testedBy',
          'consumedBy',
        ]) {
          if (data.containsKey(actor)) data[actor] = uid;
        }
        final collection = manifest['entities'][record['type']]['collection'];
        await seed('$root/$collection/${record['id']}', data);
      }
      final writes = (fixture['writes'] as List).map((raw) {
        final w = Map<String, dynamic>.from(raw as Map);
        final payload = Map<String, dynamic>.from(w['payload'] as Map);
        for (final actor
            in (manifest['entities'][w['entityType']]['actors'] as List)) {
          if (payload[actor] != null) payload[actor] = uid;
        }
        payload['organizationId'] = org;
        w['payload'] = payload;
        return w;
      }).toList();
      expect(writes, hasLength(9));
      expect(businessEffectLimit(writes), greaterThanOrEqualTo(9));
      final command = frame('actual-nine', writes);
      Future<void> deny(void Function(List<dynamic>) mutate) async {
        final client = _AlterProofCommit(mutate);
        final altered = FirestoreDirectStore(
          projectId: project,
          endpoint: Uri.parse('http://$host'),
          tokenProvider: () async => token,
          client: client,
        );
        try {
          final response = await FirestoreDirectCommandTransport(
            store: altered,
            source: source(),
            manifest: () async => manifest,
          ).submit(command);
          expect(
            client.mutated,
            isTrue,
            reason: '${response.failure?.toJson()}',
          );
          expect(response.isApproved, isFalse);
          expect(response.failure?.code, CommandErrorCodes.permissionDenied);
          expect(
            await store.get('$root/labResults/${writes.first['entityId']}'),
            isNull,
          );
        } finally {
          altered.close();
        }
      }

      await deny(
        (effects) => effects.removeWhere(
          (e) => '${e['update']?['name']}'.contains('/inventoryLots/'),
        ),
      );
      await deny((effects) {
        final stock = effects.firstWhere(
          (e) => '${e['update']?['name']}'.contains('/inventoryItems/'),
        );
        stock['update']['fields']['currentQty'] = {'doubleValue': 999999};
      });
      await deny((effects) {
        final log = effects.firstWhere(
          (e) => '${e['update']?['name']}'.contains('/consumption/'),
        );
        for (final field in ['qtyUsed', 'requestedQty', 'appliedQty']) {
          log['update']['fields'][field] = {'doubleValue': 999};
        }
      });
      await deny((effects) {
        final stock = effects.firstWhere(
          (e) => '${e['update']?['name']}'.contains('/inventoryItems/'),
        );
        stock['update']['fields']['name'] = {
          'stringValue': 'Unreserved renamed chemical',
        };
      });
      final result = await transport().submit(command);
      expect(result.isApproved, isTrue, reason: '${result.failure?.toJson()}');
      for (final w in writes.where((w) => w['entityType'] == 'inventoryItem')) {
        expect(
          (await store.get(
            '$root/inventoryItems/${w['entityId']}',
          ))!.data['currentQty'],
          (w['payload'] as Map)['currentQty'],
        );
      }
      final replay = await transport().submit(command);
      expect(replay.isApproved, isTrue);
      for (final w in writes.where((w) => w['entityType'] == 'inventoryItem')) {
        expect(
          (await store.get(
            '$root/inventoryItems/${w['entityId']}',
          ))!.data['currentQty'],
          (w['payload'] as Map)['currentQty'],
        );
      }
      // Calibration inclusion is one metadata effect even when the original
      // result consumed two chemicals. It must never consume or restore stock.
      CommandEnvelope selectionChange(int version, String exclusions) =>
          frame('nir-selection-$version', [
            {
              ...Map<String, dynamic>.from(writes.first as Map),
              'operation': 'update',
              'expectedVersion': version,
              'payload': {
                ...Map<String, dynamic>.from(writes.first['payload'] as Map),
                'nirExclusionsJson': exclusions,
              },
            },
          ]);
      final no = selectionChange(1, '["specific-pair"]');
      final noReceipt = await transport().submit(no);
      expect(
        noReceipt.isApproved,
        isTrue,
        reason: '${noReceipt.failure?.toJson()}',
      );
      expect((await transport().submit(no)).toJson(), noReceipt.toJson());
      expect(
        (await store.get(
          '$root/labResults/${writes.first['entityId']}',
        ))!.data['nirExclusionsJson'],
        '["specific-pair"]',
      );
      expect(
        (await transport().submit(selectionChange(1, '[]'))).isApproved,
        isFalse,
      );
      final eraser = _AlterProofCommit((effects) {
        for (final effect in effects) {
          if ('${effect['update']?['name']}'.contains('/labResults/')) {
            (effect['update']['fields'] as Map).remove('nirExclusionsJson');
          }
        }
      });
      final erasingStore = FirestoreDirectStore(
        projectId: project,
        endpoint: Uri.parse('http://$host'),
        tokenProvider: () async => token,
        client: eraser,
      );
      try {
        final denied = await FirestoreDirectCommandTransport(
          store: erasingStore,
          source: source(),
          manifest: () async => manifest,
        ).submit(selectionChange(2, '[]'));
        expect(eraser.mutated, isTrue);
        expect(denied.isApproved, isFalse);
      } finally {
        erasingStore.close();
      }
      final yes = await transport().submit(selectionChange(2, '[]'));
      expect(yes.isApproved, isTrue, reason: '${yes.failure?.toJson()}');
      for (final w in writes.where((w) => w['entityType'] == 'inventoryItem')) {
        expect(
          (await store.get(
            '$root/inventoryItems/${w['entityId']}',
          ))!.data['currentQty'],
          (w['payload'] as Map)['currentQty'],
        );
      }
      // A previous client already returned part of the first chemical during
      // an edit, without linking its return line to the original draw.
      final originalLog = (await store.get(
        '$root/consumption/case-consumption-1',
      ))!.data;
      await seed('$root/consumption/legacy-partial-return', {
        ...originalLog,
        'remoteId': 'legacy-partial-return',
        'eventType': 'REVERSAL',
        'qtyUsed': -1,
        'appliedQty': 1,
        'requestedQty': 1,
        'shortfallQty': 0,
        'reversalOfLogId': null,
      });
      final returnedItem = (await store.get(
        '$root/inventoryItems/case-inventoryItem-1',
      ))!.data;
      await seed('$root/inventoryItems/case-inventoryItem-1', {
        ...returnedItem,
        'currentQty': (returnedItem['currentQty'] as num) + 1,
      });
      final returnedLot = (await store.get(
        '$root/inventoryLots/case-inventoryLot-1',
      ))!.data;
      await seed('$root/inventoryLots/case-inventoryLot-1', {
        ...returnedLot,
        'qtyRemaining': (returnedLot['qtyRemaining'] as num) + 1,
      });

      // Exercise the actual delete facade, captured against a downloaded cache.
      // The result tombstone and both exact stock returns must commit together.
      final cache = await openSyncFixture();
      try {
        await driver(cache).syncNow();
        final outbox = CommandOutbox(cache.helper)
          ..scopeProvider = (() => CommandScope(org, uid, device))
          ..deviceProvider = () => device;
        cache.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: cache.helper,
          source: source(),
          outbox: outbox,
        );
        final queue = SyncQueue(cache.helper);
        final repo = ServerConfirmedLabRepository(
          dbHelper: cache.helper,
          guard: SessionWriteGuard(source: source(), isOnline: () => true),
          queue: queue,
          audit: AuditLogger(queue: queue, session: () => source().session),
        );
        final local = (await cache.db.query(
          'lab_sample_tests',
          where: 'remote_id = ?',
          whereArgs: [writes.first['entityId']],
        )).single;
        await expectLater(
          repo.deleteSampleTest(local['id'] as int),
          throwsA(isA<CentralDraftPending>()),
        );
        final deletion = (await outbox.list()).single.envelope();
        final effects = deletion.payload['writes'] as List;
        expect(effects, hasLength(7));
        expect(
          businessEffectLimit(effects),
          greaterThanOrEqualTo(effects.length),
        );
        expect(
          (await cache.db.query(
            'lab_sample_tests',
            where: 'id = ?',
            whereArgs: [local['id']],
          )).single['deleted_at'],
          isNull,
        );
        Future<void> rejectDeletion(void Function(List<dynamic>) mutate) async {
          final client = _AlterProofCommit(mutate);
          final altered = FirestoreDirectStore(
            projectId: project,
            endpoint: Uri.parse('http://$host'),
            tokenProvider: () async => token,
            client: client,
          );
          try {
            final denied = await FirestoreDirectCommandTransport(
              store: altered,
              source: source(),
              manifest: () async => manifest,
            ).submit(deletion);
            expect(
              client.mutated,
              isTrue,
              reason: '${denied.failure?.toJson()}',
            );
            expect(denied.isApproved, isFalse);
            expect(
              (await store.get(
                '$root/labResults/${writes.first['entityId']}',
              ))!.data['deletedAt'],
              isNull,
            );
          } finally {
            altered.close();
          }
        }

        await rejectDeletion(
          (commit) => commit.removeWhere(
            (e) => '${e['update']?['name']}'.contains('/inventoryLots/'),
          ),
        );
        await rejectDeletion((commit) {
          final logs = commit
              .where((e) => '${e['update']?['name']}'.contains('/consumption/'))
              .toList();
          final first = logs
              .first['update']['fields']['parentRefs']['mapValue']['fields'];
          final second =
              logs.last['update']['fields']['parentRefs']['mapValue']['fields'];
          first['reversalOfLogId'] = second['reversalOfLogId'];
        });
        final removed = await transport().submit(deletion);
        expect(
          removed.isApproved,
          isTrue,
          reason: '${removed.failure?.toJson()}',
        );
        expect(
          (await store.get(
            '$root/labResults/${writes.first['entityId']}',
          ))!.data['deletedAt'],
          isNotNull,
        );
        for (final original in (fixture['records'] as List).where(
          (r) => r['type'] == 'inventoryItem',
        )) {
          expect(
            (await store.get(
              '$root/inventoryItems/${original['id']}',
            ))!.data['currentQty'],
            original['data']['currentQty'],
          );
        }
        final committedWrites = store.usage.documentsWritten;
        expect((await transport().submit(deletion)).isApproved, isTrue);
        expect(store.usage.documentsWritten, committedWrites);
      } finally {
        await cache.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'real app saves 25 inline lists, replays one receipt, and downloads them to five empty devices',
    () async {
      final f = await openSyncFixture();
      try {
        await driver(f).syncNow();
        final outbox = CommandOutbox(f.helper)
          ..scopeProvider = (() => CommandScope(org, uid, device))
          ..deviceProvider = () => device;
        f.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: f.helper,
          source: source(),
          outbox: outbox,
        );
        final queue = SyncQueue(f.helper);
        final repo = ServerConfirmedLabRepository(
          dbHelper: f.helper,
          guard: SessionWriteGuard(source: source(), isOnline: () => true),
          queue: queue,
          audit: AuditLogger(queue: queue, session: () => source().session),
        );
        final approvedAnalysesBefore = await f.db.query('lab_analyses');
        await expectLater(
          repo.createAnalysis(
            name: 'Inline 25 lists',
            dynamicFields: List.generate(25, (i) => 'F$i'),
            fieldChemicalLinks: List.generate(
              25,
              (i) => {
                'dynamic_field': 'F$i',
                'kind': 'list',
                'list_values': [1, 2, 3],
              },
            ),
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        final command = (await outbox.list()).single;
        expect(
          command.payload['writes'],
          hasLength(1),
          reason:
              'intrinsic percent unit is packed with the analysis; no catalogue effect',
        );
        expect(
          await f.db.query('lab_analyses'),
          approvedAnalysesBefore,
          reason: 'no success before the server',
        );
        final result = await transport().submit(command.envelope());
        expect(
          result.isApproved,
          isTrue,
          reason: '${result.failure?.toJson()}',
        );
        final writes = store.usage.documentsWritten;
        expect(
          (await transport().submit(command.envelope())).toJson(),
          result.toJson(),
        );
        expect(
          store.usage.documentsWritten,
          writes,
          reason: 'replay never duplicates effects',
        );
        for (var i = 0; i < 5; i++) {
          device = 'dev$i';
          final cache = await openSyncFixture();
          try {
            await driver(cache).syncNow();
            final row = (await LabRepo(dbHelper: cache.helper).listAnalyses())
                .singleWhere((row) => row['name'] == 'Inline 25 lists');
            final links = row['field_chemical_links'] as List;
            expect(links, hasLength(25));
            expect(
              links.every((r) => '${r['list_values']}' == '[1.0, 2.0, 3.0]'),
              isTrue,
            );
            expect(
              await cache.db.query('lab_field_chemical_links'),
              isEmpty,
              reason: 'choices are stored atomically inside the analysis',
            );
          } finally {
            await cache.dispose();
          }
        }
      } finally {
        await f.dispose();
        device = 'dev0';
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'user case: three fixed and four variable consumptions on seven different chemicals save atomically',
    () async {
      final f = await openSyncFixture();
      try {
        final base = (await store.get('$root/inventoryItems/reagent'))!.data;
        for (var i = 0; i < 7; i++) {
          await seed('$root/inventoryItems/user-reagent-$i', {
            ...base,
            'remoteId': 'user-reagent-$i',
            'localId': 100 + i,
            'name': 'User reagent $i',
          });
        }
        await driver(f).syncNow();
        final inventory = await f.db.query(
          'lab_inventory',
          where: 'name LIKE ?',
          whereArgs: ['User reagent %'],
          orderBy: 'name',
        );
        final ids = inventory.map((r) => r['id'] as int).toList();
        expect(ids, hasLength(7));
        final outbox = CommandOutbox(f.helper)
          ..scopeProvider = (() => CommandScope(org, uid, device))
          ..deviceProvider = () => device;
        f.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: f.helper,
          source: source(),
          outbox: outbox,
        );
        final queue = SyncQueue(f.helper);
        final repo = ServerConfirmedLabRepository(
          dbHelper: f.helper,
          guard: SessionWriteGuard(source: source(), isOnline: () => true),
          queue: queue,
          audit: AuditLogger(queue: queue, session: () => source().session),
        );
        final fields = List.generate(3, (i) => 'Choice$i');
        await expectLater(
          repo.createAnalysis(
            name: 'User three lists with consumption',
            dynamicFields: [...fields, for (var i = 0; i < 4; i++) 'Titer$i'],
            fieldChemicalLinks: [
              for (final field in fields)
                {
                  'dynamic_field': field,
                  'kind': 'list',
                  'list_values': [1, 2, 3],
                },
              for (var i = 0; i < 4; i++)
                {
                  'dynamic_field': 'Titer$i',
                  'kind': 'link',
                  'inventory_id': ids[i + 3],
                  'unit': 'mL',
                },
            ],
            items: [
              for (var i = 0; i < 3; i++)
                {'inventory_id': ids[i], 'qty_per_sample': i + 1, 'unit': 'mL'},
            ],
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        final command = (await outbox.list()).single;
        expect(
          (command.payload['writes'] as List).length,
          lessThanOrEqualTo(5),
        );
        final result = await transport().submit(command.envelope());
        expect(
          result.isApproved,
          isTrue,
          reason: '${result.failure?.toJson()}',
        );
        expect(
          (await store.get('$root/inventoryItems/reagent'))!.data['currentQty'],
          100,
        );
        await driver(f).syncNow();
        final rows = await repo.listAnalyses();
        final saved = rows.singleWhere(
          (r) => r['name'] == 'User three lists with consumption',
        );
        expect(saved['field_chemical_links'], hasLength(7));
        expect(saved['items'], hasLength(3));
        for (var i = 0; i < 7; i++) {
          expect(
            (await store.get(
              '$root/inventoryItems/user-reagent-$i',
            ))!.data['currentQty'],
            100,
          );
        }
        final fresh = await openSyncFixture();
        try {
          await driver(fresh).syncNow();
          final pulled = (await LabRepo(dbHelper: fresh.helper).listAnalyses())
              .singleWhere(
                (r) => r['name'] == 'User three lists with consumption',
              );
          expect((pulled['items'] as List).map((r) => r['inventory_name']), [
            'User reagent 0',
            'User reagent 1',
            'User reagent 2',
          ]);
          expect(
            (pulled['field_chemical_links'] as List)
                .where((r) => r['kind'] == 'link')
                .map((r) => r['inventory_name']),
            [
              'User reagent 3',
              'User reagent 4',
              'User reagent 5',
              'User reagent 6',
            ],
          );
        } finally {
          await fresh.dispose();
        }
      } finally {
        await f.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'seven consumption security: forged, missing and partial proofs fail; 25 links save',
    () async {
      await seed(
        'organizations/other-consumption-institution/inventoryItems/belongs-only-to-other-institution',
        {
          ...(await store.get('$root/inventoryItems/reagent'))!.data,
          'organizationId': 'other-consumption-institution',
          'remoteId': 'belongs-only-to-other-institution',
        },
      );
      Map<String, dynamic> definition(String inventory, int i) => {
        'kind': 'link',
        'inventoryId': inventory,
        'field': 'F$i',
        'unit': 'mL',
      };
      CommandEnvelope request(String id, List<Map<String, dynamic>> defs) =>
          frame(id, [
            {
              'entityType': 'labAnalysis',
              'entityId': id,
              'operation': 'create',
              'expectedVersion': 0,
              'relations': <String, dynamic>{},
              'payload': {
                ...analysisPayload(id),
                'chemicalDefinitions': defs,
                'formulaJson': jsonEncode({
                  'field_configs': [
                    for (var i = 0; i < defs.length; i++)
                      {'dynamic_field': 'F$i', 'kind': 'link'},
                  ],
                }),
              },
            },
          ]);
      var attempt = 0;
      Future<void> deny(void Function(List<dynamic>) mutate) async {
        final client = _AlterProofCommit(mutate);
        final malicious = FirestoreDirectStore(
          projectId: project,
          endpoint: Uri.parse('http://$host'),
          tokenProvider: () async => token,
          client: client,
        );
        final id = 'bad-proof-${attempt++}';
        final before = (await store.get(
          '$root/counters/changeSequence',
        ))!.data['value'];
        try {
          final result = await FirestoreDirectCommandTransport(
            store: malicious,
            source: source(),
            manifest: () async => manifest,
          ).submit(request(id, [definition('reagent', 0)]));
          expect(client.mutated, isTrue);
          expect(result.isApproved, isFalse);
          expect(result.failure?.code, CommandErrorCodes.permissionDenied);
          expect(await store.get('$root/labConfig/$id'), isNull);
          expect(
            (await store.get('$root/counters/changeSequence'))!.data['value'],
            before,
          );
        } finally {
          malicious.close();
        }
      }

      await deny(
        (writes) => writes.removeWhere(
          (w) =>
              '${w['update']?['name']}'.contains(
                '/analysisDefinitionProofs/',
              ) &&
              '${w['update']['name']}'.endsWith('_summary'),
        ),
      );
      await deny(
        (writes) => writes.removeWhere(
          (w) =>
              '${w['update']?['name']}'.contains(
                '/analysisDefinitionProofs/',
              ) &&
              '${w['update']['name']}'.endsWith('_0'),
        ),
      );
      await deny((writes) {
        final rootWrite = writes.firstWhere(
          (w) => '${w['update']?['name']}'.contains('/labConfig/'),
        );
        rootWrite['update']['fields']['chemicalDefinitions'] =
            FirestoreDirectStore.encode([
              definition('belongs-only-to-other-institution', 0),
            ]);
      });
      final result = await transport().submit(
        request(
          'twenty-five-consuming-links',
          List.generate(25, (i) => definition('reagent', i)),
        ),
      );
      expect(result.isApproved, isTrue, reason: '${result.failure?.toJson()}');
      final f = await openSyncFixture();
      CommandEnvelope resultFrame(String id) => frame(id, [
        {
          'entityType': 'labResult',
          'entityId': id,
          'operation': 'create',
          'expectedVersion': 0,
          'relations': {
            'analysisId': {
              'entityType': 'labAnalysis',
              'entityId': 'twenty-five-consuming-links',
              'expectedVersion': 1,
            },
          },
          'payload': {
            'localId': 999,
            'analysisId': 1,
            'sourceType': 'sample',
            'sourceName': 'Zero consumption',
            'sampleName': id,
            'resultText': '0',
            'testedAt': '2026-11-03T00:00:00Z',
            'testedBy': uid,
            'dynamicValuesJson': jsonEncode({
              for (var i = 0; i < 25; i++) 'F$i': 0,
            }),
          },
        },
      ]);
      final oldClient = _AlterProofCommit((writes) {
        for (final w in writes) {
          final protocol =
              w['update']?['fields']?['protocol']?['mapValue']?['fields'];
          if (protocol is Map) protocol.remove('chemicalDefinitionAware');
        }
      });
      final oldStore = FirestoreDirectStore(
        projectId: project,
        endpoint: Uri.parse('http://$host'),
        tokenProvider: () async => token,
        client: oldClient,
      );
      try {
        final oldResult = await FirestoreDirectCommandTransport(
          store: oldStore,
          source: source(),
          manifest: () async => manifest,
        ).submit(resultFrame('old-format-result'));
        expect(oldClient.mutated, isTrue);
        expect(oldResult.isApproved, isFalse);
        expect(oldResult.failure?.code, CommandErrorCodes.permissionDenied);
      } finally {
        oldStore.close();
      }
      final awareResult = await transport().submit(
        resultFrame('aware-format-result'),
      );
      expect(
        awareResult.isApproved,
        isTrue,
        reason: '${awareResult.failure?.toJson()}',
      );
      try {
        await driver(f).syncNow();
        final repo = LabRepo(dbHelper: f.helper);
        final analysis = (await repo.listAnalyses()).singleWhere(
          (a) => a['name'] == 'twenty-five-consuming-links',
        );
        expect(analysis['field_chemical_links'], hasLength(25));
        expect(
          (analysis['field_chemical_links'] as List).every(
            (r) => r['inventory_name'] == 'Reagent',
          ),
          isTrue,
        );
        expect(
          (await repo.batchLoadAnalyses(null, {
            analysis['id'] as int,
          }))[analysis['id']]!['field_chemical_links'],
          analysis['field_chemical_links'],
        );
        expect(
          (await store.get('$root/inventoryItems/reagent'))!.data['currentQty'],
          100,
        );
      } finally {
        await f.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'consumption-ledger-three chemicals save, replay, rebuild and reverse',
    () async {
      dynamic remap(dynamic v, [bool third = false]) {
        if (v is String) {
          if (v.startsWith('case-')) {
            final id =
                third &&
                    const {
                      'case-inventoryItem-1',
                      'case-inventoryLot-1',
                      'case-consumption-1',
                    }.contains(v)
                ? '$v-third'
                : v;
            return 'compact-$id';
          }
          if (v == 'fixture-user') return uid;
        }
        if (v is List) return v.map((x) => remap(x, third)).toList();
        if (v is Map) {
          return <String, dynamic>{
            for (final e in v.entries) e.key as String: remap(e.value, third),
          };
        }
        return v;
      }

      final original =
          jsonDecode(
                await File(
                  'test/security/fixtures/lab_run_two_chemicals.json',
                ).readAsString(),
              )
              as Map;
      final fixture = remap(original) as Map;
      final records = fixture['records'] as List;
      for (final r in (original['records'] as List).where(
        (r) => const {
          'case-inventoryItem-1',
          'case-inventoryLot-1',
        }.contains(r['id']),
      )) {
        final third = remap(r, true) as Map;
        // Unique business labels must differ too.
        final data = third['data'] as Map;
        if (data['name'] is String) data['name'] = '${data['name']} third';
        if (data['lotNo'] is String) data['lotNo'] = '${data['lotNo']}-third';
        records.add(third);
      }
      final writes = <Map<String, dynamic>>[
        for (final w in fixture['writes'] as List)
          if (w['entityType'] != 'inventoryTransaction')
            Map<String, dynamic>.from(w as Map),
        for (final w in original['writes'] as List)
          if (const {
            'case-inventoryItem-1',
            'case-inventoryLot-1',
            'case-consumption-1',
          }.contains(w['entityId']))
            Map<String, dynamic>.from(remap(w, true) as Map),
      ];
      for (final r in records) {
        final data = Map<String, dynamic>.from(r['data'] as Map)
          ..['organizationId'] = org;
        if (data['name'] is String) data['name'] = 'Compact ${data['name']}';
        for (final key in [
          'createdBy',
          'updatedBy',
          'receivedBy',
          'testedBy',
          'consumedBy',
        ]) {
          if (data[key] != null) data[key] = uid;
        }
        await seed(
          '$root/${manifest['entities'][r['type']]['collection']}/${r['id']}',
          data,
        );
      }
      for (final w in writes) {
        final p = w['payload'] as Map;
        p['organizationId'] = org;
        if (p['name'] is String) p['name'] = 'Compact ${p['name']}';
        for (final key
            in manifest['entities'][w['entityType']]['actors'] as List) {
          if (p[key] != null) p[key] = uid;
        }
        if ('${w['entityId']}'.endsWith('-third') && p['name'] is String) {
          p['name'] = '${p['name']} third';
        }
        if ('${w['entityId']}'.endsWith('-third') && p['lotNo'] is String) {
          p['lotNo'] = '${p['lotNo']}-third';
        }
      }
      expect(writes, hasLength(10));
      expect(isConsumptionLedgerOperation(writes), true);
      expect(businessEffectLimit(writes), 10);
      final request = frame('compact-three', writes);
      for (final mutation in [
        'lot',
        'stock',
        'amount',
        'lot-mode',
        'paths',
        'missing-lot',
        'receipt',
        'root-proof',
        'qty-sign',
        'child-proof',
        'foreign-lot',
      ]) {
        final client = _AlterProofCommit((effects) {
          Map fields(String collection) =>
              effects.firstWhere(
                    (w) => '${w['update']?['name']}'.contains('/$collection/'),
                  )['update']['fields']
                  as Map;
          if (mutation == 'lot') {
            fields('inventoryLots')['qtyRemaining'] = {'doubleValue': 0.0};
          }
          if (mutation == 'stock') {
            fields('inventoryItems')['currentQty'] = {'doubleValue': 0.0};
          }
          if (mutation == 'amount') {
            fields('consumption')['appliedQty'] = {'doubleValue': 123.0};
          }
          if (mutation == 'lot-mode') {
            fields(
              'inventoryLots',
            )['protocol']['mapValue']['fields'].remove('ledgerMode');
          }
          if (mutation == 'paths') {
            fields(
              'inventoryItems',
            )['protocol']['mapValue']['fields']['consumptionPaths'] = {
              'arrayValue': {'values': []},
            };
          }
          if (mutation == 'missing-lot') {
            effects.removeWhere(
              (w) => '${w['update']?['name']}'.contains('/inventoryLots/'),
            );
          }
          if (mutation == 'receipt') {
            effects.removeWhere(
              (w) => '${w['update']?['name']}'.contains('/commandReceipts/'),
            );
          }
          if (mutation == 'root-proof') {
            fields(
              'labResults',
            )['protocol']['mapValue']['fields'].remove('effect');
          }
          if (mutation == 'qty-sign') {
            fields('consumption')['qtyUsed'] = {'doubleValue': -999.0};
          }
          if (mutation == 'child-proof') {
            fields(
              'consumption',
            )['protocol']['mapValue']['fields']['effect']['mapValue']['fields']['entityId'] = {
              'stringValue': 'forged-child',
            };
          }
          if (mutation == 'foreign-lot') {
            fields(
              'consumption',
            )['parentRefs']['mapValue']['fields']['lotId']['mapValue']['fields']['entityId'] = {
              'stringValue': 'foreign-lot',
            };
          }
        });
        final altered = FirestoreDirectStore(
          projectId: project,
          endpoint: Uri.parse('http://$host'),
          tokenProvider: () async => token,
          client: client,
        );
        try {
          final result = await FirestoreDirectCommandTransport(
            store: altered,
            source: source(),
            manifest: () async => manifest,
          ).submit(request);
          expect(
            client.mutated,
            true,
            reason: '$mutation ${result.failure?.toJson()}',
          );
          expect(
            result.failure?.code,
            CommandErrorCodes.permissionDenied,
            reason: mutation,
          );
        } finally {
          altered.close();
        }
      }
      final result = await transport().submit(request);
      expect(result.isApproved, true, reason: '${result.failure?.toJson()}');
      expect((await transport().submit(request)).toJson(), result.toJson());
      final cache = await openSyncFixture();
      final rebuilt = await openSyncFixture();
      try {
        for (final f in [cache, rebuilt]) {
          await driver(f).syncNow();
          await driver(f).syncNow();
          final ledger = await f.db.query(
            'inventory_transactions',
            where: 'remote_id LIKE ?',
            whereArgs: ['derived_consumption_v1_compact-case-%'],
          );
          expect(ledger, hasLength(3));
          expect(
            ledger.every(
              (r) =>
                  r['quantity_delta'] is num &&
                  (r['quantity_delta'] as num) < 0,
            ),
            true,
          );
        }
        final box = CommandOutbox(cache.helper);
        box.scopeProvider = () => CommandScope(org, uid, device);
        box.deviceProvider = () => device;
        cache.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: cache.helper,
          source: source(),
          outbox: box,
        );
        final queue = SyncQueue(cache.helper);
        final repo = ServerConfirmedLabRepository(
          dbHelper: cache.helper,
          guard: SessionWriteGuard(source: source(), isOnline: () => true),
          queue: queue,
          audit: AuditLogger(queue: queue, session: () => source().session),
        );
        final local = (await cache.db.query(
          'lab_sample_tests',
          where: 'remote_id = ?',
          whereArgs: [writes.first['entityId']],
        )).single;
        await expectLater(
          repo.deleteSampleTest(local['id'] as int),
          throwsA(isA<CentralDraftPending>()),
        );
        final deletion = (await box.list()).single.envelope();
        expect(deletion.payload['writes'], hasLength(10));
        final removed = await transport().submit(deletion);
        expect(
          removed.isApproved,
          true,
          reason: '${removed.failure?.toJson()}',
        );
        expect((await transport().submit(deletion)).toJson(), removed.toJson());
        await driver(cache).syncNow();
        final ledger = await cache.db.query(
          'inventory_transactions',
          where: 'remote_id LIKE ?',
          whereArgs: ['derived_consumption_v1_%'],
        );
        expect(
          ledger.where(
            (r) => r['reference_remote_id'] == writes.first['entityId'],
          ),
          hasLength(6),
        );
        for (final r in records.where((r) => r['type'] == 'inventoryItem')) {
          expect(
            (await store.get(
              '$root/inventoryItems/${r['id']}',
            ))!.data['currentQty'],
            r['data']['currentQty'],
          );
        }
      } finally {
        await cache.dispose();
        await rebuilt.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'product-reference-seven updates fit and reject expanded identity changes',
    () async {
      const product = 'reference-seven';
      Map<String, dynamic> write(
        String type,
        String id,
        Map<String, dynamic> payload, {
        bool update = false,
        Map<String, dynamic> relations = const {},
      }) => {
        'entityType': type,
        'entityId': id,
        'operation': update ? 'update' : 'create',
        'expectedVersion': update ? 1 : 0,
        'payload': payload,
        'relations': relations,
      };
      final rootPayload = <String, dynamic>{
        'configType': 'lab_products',
        'localId': 1,
        'name': product,
        'description': 'original',
        'active': 1,
      };
      expect(
        (await transport().submit(
          frame('product-create', [write('labProduct', product, rootPayload)]),
        )).isApproved,
        true,
      );
      final updates = <Map<String, dynamic>>[
        write('labProduct', product, {
          ...rootPayload,
          'description': 'updated',
        }, update: true),
      ];
      for (var i = 0; i < 6; i++) {
        final analysis = 'reference-analysis-$i';
        expect(
          (await transport().submit(
            frame('analysis-create-$i', [
              write('labAnalysis', analysis, analysisPayload(analysis)),
            ]),
          )).isApproved,
          true,
        );
        final payload = <String, dynamic>{
          'configType': 'lab_product_analyses',
          'localId': i + 1,
          'productId': 1,
          'analysisId': i + 1,
          'minValue': 4.0,
          'maxValue': 8.0,
          'unit': '%',
          'isRequired': 0,
        };
        final refs = <String, dynamic>{
          'productId': {
            'entityType': 'labProduct',
            'entityId': product,
            'expectedVersion': 1,
          },
          'analysisId': {
            'entityType': 'labAnalysis',
            'entityId': analysis,
            'expectedVersion': 1,
          },
        };
        expect(
          (await transport().submit(
            frame('link-create-$i', [
              write(
                'labProductAnalysis',
                'reference-link-$i',
                payload,
                relations: refs,
              ),
            ]),
          )).isApproved,
          true,
        );
        updates.add(
          write(
            'labProductAnalysis',
            'reference-link-$i',
            {...payload, 'maxValue': 9.0},
            update: true,
            relations: refs,
          ),
        );
      }
      expect(businessEffectLimit(updates), 7);
      final request = frame('reference-seven-update', updates);
      for (final mutation in ['rename', 'parent', 'type', 'duplicate']) {
        final client = _AlterProofCommit((writes) {
          final records = writes
              .where((w) => '${w['update']?['name']}'.contains('/labConfig/'))
              .toList();
          final fields = records.first['update']['fields'] as Map;
          if (mutation == 'rename') {
            fields['name'] = {'stringValue': 'forged-rename'};
          }
          if (mutation == 'parent') {
            final refs = records
                .last['update']['fields']['parentRefs']['mapValue']['fields'];
            refs['analysisId']['mapValue']['fields']['entityId'] = {
              'stringValue': 'reference-analysis-0',
            };
          }
          if (mutation == 'type') {
            records.last['update']['fields']['maxValue'] = {
              'stringValue': 'wrong',
            };
          }
          if (mutation == 'duplicate') {
            final event = writes.singleWhere(
              (w) => '${w['update']?['name']}'.contains('/changeEvents/'),
            );
            final paths =
                event['update']['fields']['recordPaths']['arrayValue']['values']
                    as List;
            paths[6] = paths[5];
          }
        });
        final altered = FirestoreDirectStore(
          projectId: project,
          endpoint: Uri.parse('http://$host'),
          tokenProvider: () async => token,
          client: client,
        );
        try {
          final result = await FirestoreDirectCommandTransport(
            store: altered,
            source: source(),
            manifest: () async => manifest,
          ).submit(request);
          expect(client.mutated, true);
          expect(
            result.failure?.code,
            CommandErrorCodes.permissionDenied,
            reason: mutation,
          );
        } finally {
          altered.close();
        }
      }
      var physicalWrites = 0;
      final counting = _AlterProofCommit(
        (writes) => physicalWrites = writes.length,
      );
      final counted = FirestoreDirectStore(
        projectId: project,
        endpoint: Uri.parse('http://$host'),
        tokenProvider: () async => token,
        client: counting,
      );
      try {
        final result = await FirestoreDirectCommandTransport(
          store: counted,
          source: source(),
          manifest: () async => manifest,
        ).submit(request);
        expect(result.isApproved, true, reason: '${result.failure?.toJson()}');
        expect(
          physicalWrites,
          11,
          reason:
              '7 real updates + 4 protocol records; unchanged unique reservations are not rewritten',
        );
        expect((await transport().submit(request)).toJson(), result.toJson());
        for (var i = 0; i < 6; i++) {
          expect(
            (await store.get(
              '$root/labConfig/reference-link-$i',
            ))!.data['maxValue'],
            9,
          );
        }
      } finally {
        counted.close();
      }
      expect(
        businessEffectLimit([
          ...updates,
          {...updates.last, 'entityId': 'seventh-link'},
        ]),
        lessThan(8),
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'six physical lab records with one shared inventory parent fit the actual rules budget',
    () async {
      final rootId = 'physical-six';
      final writes = <Map<String, dynamic>>[
        {
          'entityType': 'labAnalysis',
          'entityId': rootId,
          'operation': 'create',
          'expectedVersion': 0,
          'payload': analysisPayload(rootId),
          'relations': <String, dynamic>{},
        },
      ];
      for (var i = 0; i < 5; i++) {
        writes.add({
          'entityType': 'labFieldLink',
          'entityId': '$rootId-$i',
          'operation': 'create',
          'expectedVersion': 0,
          'payload': {
            'configType': 'lab_field_chemical_links',
            'localId': i + 1,
            'analysisId': 1,
            'dynamicField': 'Chemical$i',
            'kind': 'link',
            'inventoryId': 1,
            'unit': 'mL',
            'fixedValue': null,
            'listValues': null,
          },
          'relations': {
            'analysisId': {
              'entityType': 'labAnalysis',
              'entityId': rootId,
              'expectedVersion': 0,
            },
            'inventoryId': {
              'entityType': 'inventoryItem',
              'entityId': 'reagent',
              'expectedVersion': 1,
            },
          },
        });
      }
      final result = await transport().submit(frame(rootId, writes));
      expect(result.isApproved, isTrue, reason: '${result.failure?.toJson()}');
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '100 saves across five devices measure actual direct writes and preserve atomic receipts',
    () async {
      final before = store.usage.toJson();
      final start = DateTime.now();
      for (var i = 0; i < 100; i++) {
        device = 'dev${i % 5}';
        final id = 'load-$i';
        final result = await transport().submit(
          frame(id, [
            {
              'entityType': 'labAnalysis',
              'entityId': id,
              'operation': 'create',
              'expectedVersion': 0,
              'payload': analysisPayload(id),
              'relations': <String, dynamic>{},
            },
          ]),
        );
        expect(
          result.isApproved,
          isTrue,
          reason: 'save $i: ${result.failure?.toJson()}',
        );
      }
      final after = store.usage.toJson();
      final pollers = List.generate(
        5,
        (_) => FirestoreDirectStore(
          projectId: project,
          endpoint: Uri.parse('http://$host'),
          tokenProvider: () async => token,
        ),
      );
      final pollStart = DateTime.now();
      const pollingHours = 8;
      final refreshSeconds = CentralSyncDriver.defaultInterval.inSeconds;
      final pollingTicks =
          const Duration(hours: pollingHours).inSeconds ~/ refreshSeconds;
      try {
        for (var tick = 0; tick < pollingTicks; tick++) {
          final heads = await Future.wait([
            for (final poller in pollers)
              poller.head('$root/counters/changeSequence'),
          ]);
          expect(heads.every((head) => head.document != null), isTrue);
        }
      } finally {
        for (final poller in pollers) {
          poller.close();
        }
      }
      final polling = {
        'hoursRepresented': pollingHours,
        'refreshSeconds': refreshSeconds,
        'devices': 5,
        'elapsedMs': DateTime.now().difference(pollStart).inMilliseconds,
        'requests': pollers.fold(0, (n, p) => n + p.usage.requests),
        'documentsRead': pollers.fold(0, (n, p) => n + p.usage.documentsRead),
        'responseBytes': pollers.fold(0, (n, p) => n + p.usage.responseBytes),
      };
      final report = {
        'project': project,
        'functions': false,
        'saves': 100,
        'devices': 5,
        'elapsedMs': DateTime.now().difference(start).inMilliseconds,
        'observedUsage': {
          for (final e in after.entries) e.key: e.value - before[e.key]!,
        },
        'unchangedHeadPolling': polling,
        'freeQuota': {
          'readsPerDay': 50000,
          'writesPerDay': 20000,
          'deletesPerDay': 20000,
          'storageBytes': 1073741824,
          'outboundBytesPerMonth': 10737418240,
        },
        'note':
            'Emulator counters exclude internal rule/index reads and do not enforce Spark daily billing quotas.',
      };
      await Directory('build').create(recursive: true);
      await File(
        'build/spark_lab_capacity_results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      expect(report['observedUsage'], containsPair('documentsWritten', 600));
      expect(polling['documentsRead'], pollingTicks * pollers.length);
      expect(polling['documentsRead'], 4800);
      device = 'dev0';
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
