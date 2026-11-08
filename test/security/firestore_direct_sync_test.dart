@Tags(['emulator'])
library;

import 'dart:convert';
import 'dart:io';
import 'package:material_lab/core/security/secure_payload_compiler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/constants/app_strings.dart';
import 'package:material_lab/design_system/widgets/app_field.dart';
import 'package:material_lab/core/commands/command_contract.dart';
import 'package:material_lab/core/commands/firestore_direct_store.dart';
import 'package:material_lab/core/commands/firestore_direct_command_transport.dart';
import 'package:material_lab/core/commands/firestore_direct_admission.dart'
    show directUniqueClaims;
import 'package:material_lab/core/commands/firestore_direct_sync_reader.dart';
import 'package:material_lab/core/commands/central_authoring_gateway.dart';
import 'package:material_lab/core/commands/central_projection.dart';
import 'package:material_lab/core/commands/central_sync_driver.dart';
import 'package:material_lab/core/commands/command_outbox.dart';
import 'package:material_lab/core/commands/direct_write_service.dart';
import 'package:material_lab/features/reference/data/server_confirmed_reference_repository.dart';
import 'package:material_lab/features/reference/presentation/materials/mobile/material_editor.dart';
import '../support/retired/core/commands/command_worker.dart';
import 'package:material_lab/core/commands/drafts_store.dart';
import 'package:material_lab/core/commands/domain_draft_service.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/features/formulations/data/sqlite_formulation_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/qc_manager/data/qc_audit_repo.dart';
import 'package:material_lab/features/qc_manager/data/qc_repo.dart';
import 'package:material_lab/features/qc_manager/data/server_confirmed_qc_repository.dart';
import 'package:material_lab/features/qc_manager/data/ncr_report_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_nc_capa.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_filters.dart';
import 'package:material_lab/features/qc_manager/data/routine_lists_repository.dart';
import 'package:material_lab/features/qc_manager/data/server_confirmed_qc_custom_tables.dart';
import 'package:material_lab/features/qc_manager/data/qc_custom_tables_repo.dart';
import 'package:material_lab/features/qc_manager/domain/qc_custom_table.dart';
import 'package:material_lab/features/inspections/data/server_confirmed_inspection_repository.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:material_lab/features/lab/data/server_confirmed_lab_repository.dart';
import '../sync/sync_test_fixture.dart';

class _TransactionProbeClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  int rollbacks = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.endsWith(':rollback')) rollbacks++;
    return delegate.send(request);
  }

  @override
  void close() => delegate.close();
}

class _EmulatorWidgetBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  final host = Platform.environment['FIRESTORE_EMULATOR_HOST'];
  final authHost = Platform.environment['FIREBASE_AUTH_EMULATOR_HOST'];
  final enabled = host != null && authHost != null;
  if (enabled) _EmulatorWidgetBinding();
  const project = 'demo-materiallab';
  final org = 'direct_${DateTime.now().microsecondsSinceEpoch}';
  final root = 'organizations/$org';
  late String uid, token, viewerToken, viewerUid;
  late AppSession session;
  late FirestoreDirectStore store, viewerStore;
  late _TransactionProbeClient writerClient;
  late FirestoreDirectCommandTransport transport;
  late FirestoreDirectSyncReader reader;
  final manifest =
      jsonDecode(
            File(
              'tool/central_migration/domain_manifest.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final vectors =
      jsonDecode(
            File('test/fixtures/domain_wire_vectors.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  var n = 0;
  Future<void> seed(String path, Map<String, dynamic> data) async {
    final r = await http.patch(
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
    expect(r.statusCode, 200, reason: r.body);
  }

  Future<Map<String, dynamic>> user(String prefix) async {
    final r = await http.post(
      Uri.parse(
        'http://$authHost/identitytoolkit.googleapis.com/v1/accounts:signUp?key=fake',
      ),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': '$prefix-$org@example.test',
        'password': 'TestPassword123!',
        'returnSecureToken': true,
      }),
    );
    expect(r.statusCode, 200, reason: r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  CommandEnvelope frame([String kind = 'inspection']) {
    final payload =
        jsonDecode(jsonEncode((vectors[kind] as Map)['payload']))
            as Map<String, dynamic>;
    final writes = payload['writes'] as List;
    final ids = {
      for (final w in writes)
        if (w['operation'] == 'create')
          '${w['entityType']}/${w['entityId']}': const Uuid().v4(),
    };
    for (final w in writes) {
      final key = '${w['entityType']}/${w['entityId']}';
      if (ids[key] != null) {
        w['entityId'] = ids[key];
        w['payload']['remoteId'] = ids[key];
      }
      w['payload']['organizationId'] = org;
      if (w['payload']['entryCode'] != null) {
        w['payload']['entryCode'] = 'DIRECT-${++n}';
      }
      if (w['payload']['name'] != null) w['payload']['name'] = 'Item-${++n}';
      if (w['payload']['lotNo'] != null) w['payload']['lotNo'] = 'Lot-${++n}';
      for (final r in (w['relations'] as Map? ?? {}).values) {
        final replacement = ids['${r['entityType']}/${r['entityId']}'];
        if (replacement != null) r['entityId'] = replacement;
      }
    }
    return CommandEnvelope.create(
      organizationId: org,
      commandType: CommandTypes.domainCommit,
      entityId: const Uuid().v4(),
      expectedVersion: 0,
      payload: payload,
      deviceId: 'writer',
    );
  }

  setUpAll(() async {
    if (!enabled) return;
    final admin = await user('admin');
    uid = admin['localId'] as String;
    token = admin['idToken'] as String;
    final viewer = await user('viewer');
    viewerUid = viewer['localId'] as String;
    viewerToken = viewer['idToken'] as String;
    session = AppSession(
      uid: uid,
      organizationId: org,
      deviceId: 'writer',
      role: 'admin',
      status: 'active',
    );
    await seed('users/$uid', {
      'organizationId': org,
      'role': 'admin',
      'status': 'active',
      'displayName': 'Admin',
    });
    await seed('users/$viewerUid', {
      'organizationId': org,
      'role': 'viewer',
      'status': 'active',
    });
    await seed(root, {
      'status': 'active',
      'ownerUid': uid,
      'commandProtocol': {
        'enabled': true,
        'mode': firestoreDirectMode,
        'schemaVersion': commandSchemaVersion,
        'domainManifestVersion': 1,
        'migrationId': 'test',
        'globalReferencesReady': true,
        'uniqueAdmissionComplete': true,
        'writePolicy': 'multi_authorized',
        'maintenance': false,
      },
    });
    await seed('$root/devices/writer', {
      'uid': uid,
      'status': 'active',
      'readOnly': false,
    });
    await seed('$root/devices/viewer', {
      'uid': viewerUid,
      'status': 'active',
      'readOnly': true,
    });
    await seed('$root/counters/changeSequence', {'value': 0});
    await seed('$root/referenceMaterials/server-material-1', {
      'organizationId': org,
      'version': 1,
      'materialName': 'Cement',
      'materialCode': 'M-CEM-01',
      'createdAt': DateTime.utc(2026),
      'updatedAt': DateTime.utc(2026),
      'createdBy': uid,
      'updatedBy': uid,
      'localId': 1,
      'deviceId': 'writer',
      'remoteId': 'server-material-1',
      'physicalReferenceJson': '{}',
      'chemicalReferenceJson': '{}',
      'importedAt': '2026-01-01',
      'active': 1,
      'deletedAt': null,
    });
    store = FirestoreDirectStore(
      projectId: project,
      tokenProvider: () async => token,
      endpoint: Uri.parse('http://$host'),
      client: writerClient = _TransactionProbeClient(),
    );
    viewerStore = FirestoreDirectStore(
      projectId: project,
      tokenProvider: () async => viewerToken,
      endpoint: Uri.parse('http://$host'),
    );
    transport = FirestoreDirectCommandTransport(
      store: store,
      source: SessionSource(() => session),
      manifest: () async => manifest,
    );
    reader = FirestoreDirectSyncReader(
      store: store,
      source: SessionSource(() => session),
      manifest: () async => manifest,
    );
  });
  tearDownAll(() {
    if (enabled) {
      store.close();
      viewerStore.close();
    }
  });
  test(
    'direct atomic save, replay and pointer feed work as a real Firebase user',
    () async {
      final command = frame();
      final rollbacks = writerClient.rollbacks;
      final result = await transport.submit(command);
      expect(result.isApproved, isTrue, reason: result.failure?.messageAr);
      expect(
        writerClient.rollbacks,
        rollbacks,
        reason:
            'An already committed transaction must not add a blocking rollback request',
      );
      final replay = await transport.submit(command);
      expect(replay.toJson(), result.toJson());
      final head = await reader.call({
        'mode': 'beginSnapshot',
        'organizationId': org,
        'deviceId': 'writer',
      });
      expect(head['throughSequence'], result.changeSequence);
      final page = await reader.call({
        'mode': 'events',
        'organizationId': org,
        'deviceId': 'writer',
        'afterSequence': result.changeSequence! - 1,
      });
      final records =
          ((page['events'] as List).single as Map)['records'] as List;
      expect(records, hasLength(1));
      expect(
        (records.single as Map)['data'],
        containsPair(
          'entryCode',
          (command.payload['writes'] as List).single['payload']['entryCode'],
        ),
      );
      final changed = CommandEnvelope.create(
        organizationId: org,
        commandType: CommandTypes.domainCommit,
        entityId: command.entityId,
        expectedVersion: 0,
        payload: command.payload,
        deviceId: 'writer',
      );
      final duplicate = await transport.submit(changed);
      expect(duplicate.isApproved, isFalse);
      expect(duplicate.failure?.code, CommandErrorCodes.versionConflict);
    },
    skip: !enabled,
  );
  test(
    'Secure blind write hides saved readings until explicit authorized reveal',
    () async {
      final previous = (await store.get(root))!.data;
      final fixture = await openSyncFixture();
      try {
        await seed(root, {
          ...previous,
          'commandProtocol': {
            ...previous['commandProtocol'] as Map,
            'secureFieldsEnabled': true,
          },
        });
        final original = frame();
        final writes = [
          for (final w in original.payload['writes'] as List)
            Map<String, Object?>.from(w as Map),
        ];
        final payload = writes.single['payload'] as Map;
        payload['chemicalReferenceJson'] = jsonEncode({
          'Moisture': {'value': '10-12', 'secure': true},
        });
        payload['chemicalResultsJson'] = jsonEncode({
          'Moisture': [17],
        });
        payload['snapshotJson'] = jsonEncode({
          'chemical_results': {
            'Moisture': [17],
          },
        });
        await compileSecurePayloads(
          db: fixture.db,
          session: session,
          writes: writes,
        );
        final command = CommandEnvelope.create(
          organizationId: org,
          commandType: CommandTypes.domainCommit,
          entityId: const Uuid().v4(),
          expectedVersion: 0,
          deviceId: 'writer',
          payload: {'writes': writes},
        );
        final approved = await transport.submit(command);
        expect(
          approved.isApproved,
          true,
          reason: '${approved.failure?.code}: ${approved.failure?.messageAr}',
        );
        final source = (await store.get(
          '$root/samples/${writes.first['entityId']}',
        ))!;
        expect(
          jsonDecode(source.data['chemicalResultsJson'] as String),
          isEmpty,
        );
        expect(jsonDecode(source.data['snapshotJson'] as String), {
          'chemical_results': {},
        });
        final secretPath = '$root/labConfig/${writes.last['entityId']}';
        await expectLater(
          viewerStore.get(secretPath),
          throwsA(isA<DirectStoreError>()),
        );
        await expectLater(
          store.get(secretPath),
          throwsA(isA<DirectStoreError>()),
        );
        final claims =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(base64Url.normalize(token.split('.')[1])),
                  ),
                )
                as Map;
        final viewPath = '$root/secureVisibility/$uid';
        await store.request(
          '${store.documents}:commit',
          body: {
            'writes': [
              store.write(
                viewPath,
                {
                  'enabled': true,
                  'authTime': claims['auth_time'],
                  'deviceId': 'writer',
                },
                timestamps: ['updatedAt'],
              ),
            ],
          },
        );
        final secret = (await store.get(secretPath))!;
        expect(secret.data['fieldsJson'], contains('17'));
        await expectLater(
          viewerStore.get(secretPath),
          throwsA(isA<DirectStoreError>()),
        );
      } finally {
        await seed(root, previous);
        await fixture.dispose();
      }
    },
    skip: !enabled,
  );

  for (final key in [
    'product_daily_report_form_no',
    'product_monthly_report_form_no',
    'product_yearly_report_form_no',
  ]) {
    test(
      'product form key $key can be created and updated with server receipts',
      () async {
        final id = const Uuid().v4();
        final localId = ++n;
        CommandEnvelope command(int version, String value) =>
            CommandEnvelope.create(
              organizationId: org,
              commandType: CommandTypes.domainCommit,
              entityId: const Uuid().v4(),
              expectedVersion: 0,
              deviceId: 'writer',
              payload: {
                'writes': [
                  {
                    'entityType': 'organizationSetting',
                    'entityId': id,
                    'operation': version == 0 ? 'create' : 'update',
                    'expectedVersion': version,
                    'payload': {'key': key, 'value': value, 'localId': localId},
                  },
                ],
              },
            );
        for (var version = 0; version < 2; version++) {
          final result = await transport.submit(
            command(version, 'PRODUCT-$version'),
          );
          expect(result.isApproved, isTrue, reason: result.failure?.messageAr);
          final saved = await store.get('$root/organizationSettings/$id');
          expect(saved!.data['value'], 'PRODUCT-$version');
          expect(saved.data['version'], version + 1);
        }
      },
      skip: !enabled,
    );
  }

  test(
    'legacy enrolled writer works; revoked, foreign and read-only devices fail',
    () async {
      try {
        await seed('$root/devices/writer', {'uid': uid, 'readOnly': false});
        final accepted = await transport.submit(frame());
        expect(accepted.isApproved, isTrue, reason: '${accepted.failure}');
        for (final device in [
          {'uid': uid, 'readOnly': false, 'status': 'revoked'},
          {'uid': viewerUid, 'readOnly': false, 'status': 'active'},
          {'uid': uid, 'readOnly': true, 'status': 'active'},
        ]) {
          await seed('$root/devices/writer', device);
          expect((await transport.submit(frame())).isApproved, isFalse);
        }
      } finally {
        await seed('$root/devices/writer', {
          'uid': uid,
          'readOnly': false,
          'status': 'active',
        });
      }
    },
    skip: !enabled,
  );

  test(
    'nine-column QC definition commits atomically and reaches a second cache',
    () async {
      final first = await openSyncFixture(), second = await openSyncFixture();
      final source = SessionSource(() => session);
      final outbox = CommandOutbox(first.helper);
      outbox.scopeProvider = () => CommandScope(org, uid, 'writer');
      outbox.deviceProvider = () => 'writer';
      CentralSyncDriver driver(SyncFixture fixture) => CentralSyncDriver(
        databaseHelper: fixture.helper,
        source: source,
        projection: CentralProjection(
          databaseHelper: fixture.helper,
          source: source,
        ),
        transport: reader,
        outbox: fixture == first ? outbox : CommandOutbox(fixture.helper),
        metadata: SyncMetadata(fixture.helper),
      );
      try {
        final firstDriver = driver(first), secondDriver = driver(second);
        await firstDriver.syncNow();
        first.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: first.helper,
          source: source,
          outbox: outbox,
        );
        final repository = ServerConfirmedQcCustomTablesRepository(
          local: QcCustomTablesRepo(first.helper),
          guard: SessionWriteGuard(source: source, isOnline: () => true),
          dbHelper: first.helper,
          queue: SyncQueue(first.helper),
        );
        const now = '2026-10-29T00:00:00Z';
        final columns = List.generate(
          maxQcCustomTableColumns,
          (i) => QcCustomTableField(
            label: 'Column $i',
            colType: QcCustomColType.text,
            sortOrder: i,
            createdAt: now,
            updatedAt: now,
          ),
        );
        await expectLater(
          repository.createTable(
            const QcCustomTable(
              title: 'Atomic nine columns',
              createdAt: now,
              updatedAt: now,
            ),
            columns,
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        final command = (await outbox.list()).single;
        expect(command.payload['writes'], hasLength(10));
        expect(await first.db.query('qc_custom_tables'), isEmpty);
        for (final attack in [
          'record8',
          'record9',
          'effect',
          'device',
          'partial',
          'legacy',
        ]) {
          final client = _MutateCommitClient((writes) {
            final event = writes.singleWhere(
              (w) => w['update']['name'].toString().contains('/changeEvents/'),
            )['update']['fields'];
            if (attack.startsWith('record')) {
              final index = attack == 'record8' ? 8 : 9;
              event['records']['arrayValue']['values'][index]['mapValue']['fields']['version'] =
                  {'integerValue': '99'};
            } else if (attack == 'effect') {
              final column = writes.firstWhere(
                (w) => w['update']['name'].toString().contains(
                  '/qcCustomTableFields/',
                ),
              )['update']['fields'];
              column['protocol']['mapValue']['fields']['effect']['mapValue']['fields']['version'] =
                  {'integerValue': '99'};
              // Match the forged event too: denial must come from the
              // business record's independent proof/version validation.
              final records = event['records']['arrayValue']['values'] as List;
              final matching = records.singleWhere(
                (r) =>
                    r['mapValue']['fields']['entityId']['stringValue'] ==
                    column['remoteId']['stringValue'],
              );
              matching['mapValue']['fields']['version'] = {
                'integerValue': '99',
              };
            } else if (attack == 'device') {
              event['deviceId'] = {'stringValue': 'foreign-device'};
            } else if (attack == 'partial') {
              final column = writes.firstWhere(
                (w) => w['update']['name'].toString().contains(
                  '/qcCustomTableFields/',
                ),
              );
              writes.remove(column);
            } else {
              for (final write in writes) {
                (write['update']['fields']['protocol']?['mapValue']?['fields']
                        as Map?)
                    ?.remove('effect');
              }
            }
          });
          final malicious = FirestoreDirectStore(
            projectId: project,
            tokenProvider: () async => token,
            endpoint: Uri.parse('http://$host'),
            client: client,
          );
          try {
            final denied = await FirestoreDirectCommandTransport(
              store: malicious,
              source: source,
              manifest: () async => manifest,
            ).submit(command.envelope());
            expect(client.mutated, isTrue);
            expect(
              denied.failure?.code,
              CommandErrorCodes.permissionDenied,
              reason: attack,
            );
            expect(
              await store.get('$root/commandReceipts/${command.operationId}'),
              isNull,
            );
          } finally {
            malicious.close();
          }
        }
        final result = await transport.submit(command.envelope());
        expect(
          result.isApproved,
          isTrue,
          reason: '${result.failure?.toJson()}',
        );
        expect(
          (await transport.submit(command.envelope())).toJson(),
          result.toJson(),
        );
        await firstDriver.syncNow();
        await secondDriver.syncNow();
        for (final fixture in [first, second]) {
          final table = (await fixture.db.query(
            'qc_custom_tables',
            where: 'title = ?',
            whereArgs: ['Atomic nine columns'],
          )).single;
          final fields = await fixture.db.query(
            'qc_custom_table_fields',
            where: 'table_id = ? AND deleted_at IS NULL',
            whereArgs: [table['table_id']],
          );
          expect(fields, hasLength(9));
        }
        final localTable = (await first.db.query(
          'qc_custom_tables',
          where: 'title = ?',
          whereArgs: ['Atomic nine columns'],
        )).single;
        final bundle = (await repository.getTableBundle(
          localTable['table_id'] as int,
        ))!;
        await expectLater(
          repository.saveTable(
            QcCustomTable(
              tableId: bundle.table.tableId,
              remoteId: bundle.table.remoteId,
              title: 'Edited nine columns',
              createdAt: bundle.table.createdAt,
              updatedAt: now,
              version: bundle.table.version,
            ),
            bundle.fields,
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        final edit = (await outbox.list()).singleWhere(
          (e) => e.operationId != command.operationId,
        );
        expect(edit.payload['writes'], hasLength(10));
        final edited = await transport.submit(edit.envelope());
        expect(
          edited.isApproved,
          isTrue,
          reason: '${edited.failure?.toJson()}',
        );
        await firstDriver.syncNow();
        await secondDriver.syncNow();
        expect(
          await second.db.query(
            'qc_custom_tables',
            where: 'title = ?',
            whereArgs: ['Edited nine columns'],
          ),
          hasLength(1),
        );
        final values = {
          for (final field in bundle.fields)
            field.remoteId: 'Value ${field.label}',
        };
        await expectLater(
          repository.addRow(
            QcCustomTableRow(
              tableId: bundle.table.tableId,
              tableRemoteId: bundle.table.remoteId,
              valuesJson: jsonEncode(values),
              recordedAt: now,
              createdAt: now,
              updatedAt: now,
            ),
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        final rowRequest = (await outbox.list()).singleWhere(
          (e) => (e.payload['writes'] as List).any(
            (w) => w['entityType'] == 'qcCustomTableRow',
          ),
        );
        final added = await transport.submit(rowRequest.envelope());
        expect(added.isApproved, isTrue, reason: '${added.failure?.toJson()}');
        await firstDriver.syncNow();
        await secondDriver.syncNow();
        final syncedRows = await second.db.query(
          'qc_custom_table_rows',
          where: 'table_remote_id = ?',
          whereArgs: [bundle.table.remoteId],
        );
        expect(jsonDecode(syncedRows.single['values_json'] as String), values);
        await expectLater(
          repository.createTable(
            const QcCustomTable(
              title: 'Ten forbidden',
              createdAt: now,
              updatedAt: now,
            ),
            [
              ...columns,
              const QcCustomTableField(
                label: 'Tenth',
                colType: QcCustomColType.text,
                createdAt: now,
                updatedAt: now,
              ),
            ],
          ),
          throwsA(isA<ValidationError>()),
        );
        expect(await outbox.list(), hasLength(3));
      } finally {
        await first.dispose();
        await second.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'existing clients without the compact effect proof retain small atomic saves',
    () async {
      final client = _MutateCommitClient((writes) {
        for (final write in writes) {
          (write['update']['fields']['protocol']?['mapValue']?['fields']
                  as Map?)
              ?.remove('effect');
        }
      });
      final legacyStore = FirestoreDirectStore(
        projectId: project,
        tokenProvider: () async => token,
        endpoint: Uri.parse('http://$host'),
        client: client,
      );
      try {
        final result = await FirestoreDirectCommandTransport(
          store: legacyStore,
          source: SessionSource(() => session),
          manifest: () async => manifest,
        ).submit(frame());
        expect(client.mutated, isTrue);
        expect(
          result.isApproved,
          isTrue,
          reason: '${result.failure?.toJson()}',
        );
      } finally {
        legacyStore.close();
      }
    },
    skip: !enabled,
  );

  test(
    'lab specialist creates final approved and rejected inspections without admin privileges',
    () async {
      final account = await user('lab-specialist');
      final specialistUid = account['localId'] as String;
      await seed('users/$specialistUid', {
        'organizationId': org,
        'role': 'lab',
        'roles': ['lab'],
        'status': 'active',
      });
      await seed('$root/devices/lab-writer', {
        'uid': specialistUid,
        'status': 'active',
        'readOnly': false,
      });
      final specialist = AppSession(
        uid: specialistUid,
        organizationId: org,
        deviceId: 'lab-writer',
        role: 'lab',
        status: 'active',
      );
      final specialistStore = FirestoreDirectStore(
        projectId: project,
        tokenProvider: () async => account['idToken'] as String,
        endpoint: Uri.parse('http://$host'),
      );
      try {
        final specialistTransport = FirestoreDirectCommandTransport(
          store: specialistStore,
          source: SessionSource(() => specialist),
          manifest: () async => manifest,
        );
        for (final decision in ['APPROVED', 'FULL_REJECTION']) {
          final original = frame();
          final payload =
              jsonDecode(jsonEncode(original.payload)) as Map<String, dynamic>;
          final sample = (payload['writes'] as List).single['payload'] as Map;
          sample['decisionStatus'] = decision;
          sample['decisionReason'] = decision == 'FULL_REJECTION'
              ? 'Failed specification'
              : '';
          sample['rejectedQuantity'] = decision == 'FULL_REJECTION'
              ? sample['quantity']
              : '';
          final command = CommandEnvelope.create(
            organizationId: org,
            commandType: CommandTypes.domainCommit,
            entityId: const Uuid().v4(),
            expectedVersion: 0,
            deviceId: 'lab-writer',
            payload: payload,
          );
          final result = await specialistTransport.submit(command);
          expect(
            result.isApproved,
            isTrue,
            reason: '$decision: ${result.failure?.toJson()}',
          );
          final id = (payload['writes'] as List).single['entityId'];
          final saved = (await specialistStore.get('$root/samples/$id'))!.data;
          expect(saved['createdBy'], specialistUid);
          expect(saved['decisionStatus'], decision);
        }
        // A different employee's inspection remains editable; the creator
        // identity is preserved and changing its decision includes history.
        final other = frame();
        expect((await transport.submit(other)).isApproved, isTrue);
        final originalWrite = (other.payload['writes'] as List).single as Map;
        final targetId = originalWrite['entityId'];
        final before = (await store.get('$root/samples/$targetId'))!.data;
        final decision =
            jsonDecode(jsonEncode(frame('qualityDecision').payload))
                as Map<String, dynamic>;
        final writes = decision['writes'] as List;
        final edited =
            writes.singleWhere((w) => w['entityType'] == 'sample') as Map;
        edited['entityId'] = targetId;
        edited['expectedVersion'] = 1;
        edited['payload'] = {
          ...Map<String, dynamic>.from(originalWrite['payload'] as Map),
          'decisionStatus': 'FULL_REJECTION',
          'rejectedQuantity': before['quantity'],
          'decisionReason': 'Specialist decision',
          'supplier': 'Edited by specialist',
        };
        final history =
            writes.singleWhere((w) => w['entityType'] == 'qualityCheck') as Map;
        history['relations'] = {
          'inspectionId': {
            'entityType': 'sample',
            'entityId': targetId,
            'expectedVersion': 1,
          },
        };
        (history['payload'] as Map).addAll(<String, dynamic>{
          'oldStatus': before['decisionStatus'],
          'newStatus': 'FULL_REJECTION',
          'rejectedQuantity': before['quantity'],
        });
        final command = CommandEnvelope.create(
          organizationId: org,
          commandType: CommandTypes.domainCommit,
          entityId: const Uuid().v4(),
          expectedVersion: 0,
          deviceId: 'lab-writer',
          payload: decision,
        );
        final updated = await specialistTransport.submit(command);
        expect(
          updated.isApproved,
          isTrue,
          reason: '${updated.failure?.toJson()}',
        );
        final after = (await specialistStore.get(
          '$root/samples/$targetId',
        ))!.data;
        expect(after['createdBy'], uid);
        expect(after['updatedBy'], specialistUid);
        expect(after['supplier'], 'Edited by specialist');
        expect(after['version'], 2);
        final tx = await specialistStore.begin();
        await expectLater(
          specialistStore.commit([
            specialistStore.write(root, {
              'name': 'Unauthorized organization edit',
            }),
          ], tx),
          throwsA(isA<DirectStoreError>()),
        );
        try {
          await specialistStore.rollback(tx);
        } on Object {
          /* denied transaction */
        }
      } finally {
        specialistStore.close();
      }
    },
    skip: !enabled,
  );

  test(
    'all standard employee roles can bootstrap their permission-scoped archive',
    () async {
      for (final role in ['lab', 'quality_manager', 'nutritionist', 'viewer']) {
        final account = await user('archive-$role');
        final actor = account['localId'] as String;
        await seed('users/$actor', {
          'organizationId': org,
          'role': role,
          'status': 'active',
        });
        await seed('$root/devices/archive-$role', {
          'uid': actor,
          'status': 'active',
          'readOnly': role == 'viewer',
        });
        final readSession = AppSession(
          uid: actor,
          organizationId: org,
          deviceId: 'archive-$role',
          role: role,
          status: 'active',
          readOnlyDevice: role == 'viewer',
        );
        final readSource = SessionSource(() => readSession);
        final remote = FirestoreDirectStore(
          projectId: project,
          tokenProvider: () async => account['idToken'] as String,
          endpoint: Uri.parse('http://$host'),
        );
        final cache = await openSyncFixture();
        try {
          final driver = CentralSyncDriver(
            databaseHelper: cache.helper,
            source: readSource,
            projection: CentralProjection(
              databaseHelper: cache.helper,
              source: readSource,
            ),
            transport: FirestoreDirectSyncReader(
              store: remote,
              source: readSource,
              manifest: () async => manifest,
            ),
            outbox: CommandOutbox(cache.helper),
            metadata: SyncMetadata(cache.helper),
          );
          final head = await driver.syncNow();
          expect(await driver.currentSequence(), head, reason: role);
          expect(await cache.db.query('inspections'), isNotEmpty, reason: role);
          expect(await cache.db.query('command_outbox'), isEmpty);
          expect(remote.usage.documentsWritten, 0);
        } finally {
          remote.close();
          await cache.dispose();
        }
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('inventory balance, lot and ledger commit together', () async {
    final command = frame('inventory');
    final result = await transport.submit(command);
    expect(result.isApproved, isTrue, reason: result.failure?.messageAr);
    final head = await store.get(
      '$root/changeEvents/event_${result.changeSequence}',
    );
    expect(head!.data['records'], hasLength(3));
  }, skip: !enabled);
  test(
    'screen repositories publish raw and product inspections, samples, analyses and worksheets to two caches',
    () async {
      final first = await openSyncFixture(), second = await openSyncFixture();
      final source = SessionSource(() => session);
      final outbox = CommandOutbox(first.helper);
      outbox.scopeProvider = () => CommandScope(org, uid, 'writer');
      outbox.deviceProvider = () => 'writer';
      CentralSyncDriver driver(SyncFixture f) => CentralSyncDriver(
        databaseHelper: f.helper,
        source: source,
        projection: CentralProjection(databaseHelper: f.helper, source: source),
        transport: reader,
        outbox: f == first ? outbox : CommandOutbox(f.helper),
        metadata: SyncMetadata(f.helper),
      );
      try {
        final a = driver(first), b = driver(second);
        await a.syncNow();
        await first.seedOrganization(uid: uid);
        final actors = await first.db.query(
          'users',
          where: 'uid = ?',
          whereArgs: [uid],
        );
        final actorId = actors.single['id'] as int;
        first.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: first.helper,
          source: source,
          outbox: outbox,
        );
        final guard = SessionWriteGuard(source: source, isOnline: () => true);
        final queue = SyncQueue(first.helper),
            audit = AuditLogger(
              queue: SyncQueue(first.helper),
              session: () => session,
            );
        final lab = ServerConfirmedLabRepository(
          dbHelper: first.helper,
          guard: guard,
          queue: queue,
          audit: audit,
        );
        final inspections = ServerConfirmedInspectionRepository(
          dbHelper: first.helper,
          referenceRepo: ReferenceRepo(
            dbHelper: first.helper,
            deviceTagProvider: () async => 'SCREEN',
          ),
          guard: guard,
          queue: queue,
          audit: audit,
        );
        Future<void> commit(
          String label,
          Future<dynamic> Function() action,
        ) async {
          final before = (await outbox.list())
              .map((e) => e.operationId)
              .toSet();
          await expectLater(
            action(),
            throwsA(isA<CentralDraftPending>()),
            reason: label,
          );
          final command = (await outbox.list()).singleWhere(
            (e) => !before.contains(e.operationId),
          );
          final result = await transport.submit(command.envelope());
          expect(
            result.isApproved,
            isTrue,
            reason: '$label: ${result.failure?.toJson()}',
          );
          await a.syncNow();
          await b.syncNow();
        }

        final tag = const Uuid().v4();
        final rawCode = 'RAW-$tag', batchCode = 'BATCH-$tag';
        final initialProductUnit = 'qa-${tag.substring(0, 8)}';
        final updatedProductUnit = '$initialProductUnit-b';
        final user = {'id': actorId, 'uid': uid, 'full_name': 'Screen tester'};
        await commit(
          'raw inspection',
          () => inspections.create(
            {
              'entry_code': rawCode,
              'material_id': 1,
              'inspection_date': '2026-11-01',
              'supplier': 'Valid Supplier',
              'sample_taken_by': 'Valid Taker',
              'quantity': '20',
              'sample_names': ['S1', 'S2'],
              'physical_results': <String, dynamic>{},
              'chemical_results': <String, dynamic>{},
              'decision_status': 'APPROVED',
            },
            UserContext(id: actorId, fullName: 'Screen tester', role: 'admin'),
          ),
        );
        final rawId =
            (await first.db.query(
                  'inspections',
                  where: 'entry_code = ?',
                  whereArgs: [rawCode],
                )).single['id']
                as int;
        for (final status in ['FULL_REJECTION', 'APPROVED']) {
          await commit(
            'raw decision $status',
            () => inspections.updateStatus(
              rawId,
              {
                'decision_status': status,
                'decision_reason': status == 'FULL_REJECTION'
                    ? 'Out of spec'
                    : '',
                'rejected_quantity': status == 'FULL_REJECTION' ? '20' : '',
              },
              UserContext(
                id: actorId,
                fullName: 'Screen tester',
                role: 'admin',
              ),
            ),
          );
          if (status == 'FULL_REJECTION') {
            await commit(
              'decision reason without changing status',
              () => inspections.updateStatus(
                rawId,
                {
                  'decision_status': status,
                  'decision_reason': 'Reviewed specification again',
                },
                UserContext(
                  id: actorId,
                  fullName: 'Screen tester',
                  role: 'admin',
                ),
              ),
            );
          }
        }
        await commit(
          'analysis definition',
          () => lab.createAnalysis(name: 'Screen analysis $tag', unit: '%'),
        );
        final analysisId =
            (await first.db.query(
                  'lab_analyses',
                  where: 'name = ?',
                  whereArgs: ['Screen analysis $tag'],
                )).single['id']
                as int;
        await commit(
          'inspection test result',
          () => lab.runSampleTest(
            analysisId: analysisId,
            sourceType: 'raw_material',
            sourceRefId: rawId,
            sourceName: 'Cement',
            sampleName: 'S1',
            entryCode: rawCode,
            resultText: '12',
            manualResult: true,
            user: user,
          ),
        );
        await commit(
          'worksheet result',
          () => lab.saveWorksheet([
            {
              'source_type': 'raw_material',
              'source_name': 'Cement',
              'sample_name': 'S2',
              'entry_code': rawCode,
              'tests': {
                '$analysisId': {'result_text': '13'},
              },
            },
          ], user),
        );
        await commit(
          'product definition',
          () => lab.createProduct(
            name: 'Screen product $tag',
            category: 'Feed',
            physicalReference: {'Color': 'normal'},
            chemicalReference: {
              'Screen analysis $tag': {
                'value': '10-20',
                'unit': initialProductUnit,
              },
            },
            user: user,
          ),
        );
        final productId =
            (await first.db.query(
                  'lab_products',
                  where: 'name = ?',
                  whereArgs: ['Screen product $tag'],
                )).single['id']
                as int;
        final originalRange = (await first.db.query(
          'lab_product_analyses',
          where: 'product_id = ? AND deleted_at IS NULL',
          whereArgs: [productId],
        )).single;
        expect(originalRange['unit'], initialProductUnit);
        await commit(
          'product reference edit with stable identity',
          () => lab.updateProduct(productId, {
            'chemical_reference': {
              'Screen analysis $tag': {
                'value': '11-21',
                'unit': updatedProductUnit,
              },
            },
          }),
        );
        final editedRange = (await first.db.query(
          'lab_product_analyses',
          where: 'product_id = ? AND deleted_at IS NULL',
          whereArgs: [productId],
        )).single;
        expect(editedRange['id'], originalRange['id']);
        expect(editedRange['remote_id'], originalRange['remote_id']);
        expect(editedRange['min_value'], 11);
        expect(editedRange['unit'], updatedProductUnit);
        final syncedRange = (await second.db.query(
          'lab_product_analyses',
          where: 'remote_id = ?',
          whereArgs: [originalRange['remote_id']],
        )).single;
        expect(syncedRange['unit'], updatedProductUnit);
        final syncedUnits = await second.db.query(
          'lab_units',
          where: 'symbol IN (?, ?) AND deleted_at IS NULL',
          whereArgs: [initialProductUnit, updatedProductUnit],
        );
        expect(
          syncedUnits.map((row) => row['symbol']),
          unorderedEquals([initialProductUnit, updatedProductUnit]),
        );
        await commit(
          'first product inspection',
          () => inspections.create(
            {
              'inspection_kind': 'product',
              'product_id': productId,
              'entry_code': batchCode,
              'formula_number': 'F-1',
              'batch_number': 'B-1',
              'inspection_date': '2026-11-01',
              'sample_taken_by': 'Valid Taker',
              'quantity': '20',
              'sample_names': ['Result'],
              'physical_results': <String, dynamic>{},
              'chemical_results': <String, dynamic>{},
            },
            UserContext(id: actorId, fullName: 'Screen tester', role: 'admin'),
          ),
        );
        final batchId =
            (await first.db.query(
                  'inspections',
                  where: 'entry_code = ?',
                  whereArgs: [batchCode],
                )).single['id']
                as int;
        await commit(
          'product batch sample',
          () => lab.addBatchSample(
            batchId: batchId,
            sampleName: 'Batch sample',
            sampleTaker: 'Valid Taker',
            user: user,
          ),
        );
        await commit(
          'remove product analysis link',
          () => lab.updateProduct(productId, {
            'chemical_reference': <String, dynamic>{},
          }),
        );
        expect(await lab.getProductRanges(productId), isEmpty);
        await commit(
          'archive product after a linked inspection',
          () => lab.deleteProduct(productId),
        );
        final preservedBatch = await inspections.getById(batchId);
        expect(preservedBatch['physical_reference'], {'Color': 'normal'});
        expect(
          preservedBatch['chemical_reference'],
          contains('Screen analysis $tag'),
        );
        expect(
          await second.db.query(
            'inspections',
            where: 'entry_code IN (?, ?)',
            whereArgs: [rawCode, batchCode],
          ),
          hasLength(2),
        );
        expect(
          await second.db.query(
            'lab_analyses',
            where: 'name = ?',
            whereArgs: ['Screen analysis $tag'],
          ),
          hasLength(1),
        );
        expect(
          await second.db.rawQuery(
            'SELECT t.* FROM lab_sample_tests t JOIN lab_analyses a ON a.id=t.analysis_id WHERE a.name=?',
            ['Screen analysis $tag'],
          ),
          hasLength(2),
        );
        expect(
          await second.db.rawQuery(
            'SELECT s.* FROM product_batch_samples s JOIN inspections i ON i.id=s.batch_id WHERE i.entry_code=?',
            [batchCode],
          ),
          hasLength(1),
        );
        for (final entry in await outbox.list()) {
          expect(
            (entry.payload['writes'] as List).any(
              (w) =>
                  w['entityType'] == 'referenceMaterial' &&
                  w['payload']['materialName'] == '__PRODUCT_SENTINEL__',
            ),
            isFalse,
          );
        }
      } finally {
        await first.dispose();
        await second.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  for (final role in ['admin', 'lab']) {
    test(
      '$role product sample NCR is one atomic server-confirmed command and remaps its link on a second device',
      () async {
        final saved = session;
        session = session.copyWith(role: role, roles: [role]);
        await seed('users/$uid', {
          'organizationId': org,
          'role': role,
          'roles': [role],
          'status': 'active',
        });
        addTearDown(() async {
          session = saved;
          await seed('users/$uid', {
            'organizationId': org,
            'role': saved.role,
            'roles': saved.effectiveRoles,
            'status': 'active',
          });
        });
        final productId = const Uuid().v4(),
            headerId = const Uuid().v4(),
            sampleId = const Uuid().v4(),
            otherSampleId = const Uuid().v4();
        final common = <String, dynamic>{
          'organizationId': org,
          'version': 1,
          'createdAt': DateTime.utc(2026, 11, 2),
          'updatedAt': DateTime.utc(2026, 11, 2),
          'createdBy': uid,
          'updatedBy': uid,
          'deviceId': 'writer',
          'deletedAt': null,
        };
        await seed('$root/labConfig/$productId', {
          ...common,
          'remoteId': productId,
          'localId': 1,
          'configType': 'lab_products',
          'name': 'NCR Product $role',
          'physicalReferenceJson': '{}',
          'chemicalReferenceJson': '{}',
          'active': 1,
        });
        final base = Map<String, dynamic>.from(
          (frame().payload['writes'] as List).single['payload'] as Map,
        );
        await seed('$root/samples/$headerId', {
          ...base,
          ...common,
          'remoteId': headerId,
          'localId': 1,
          'entryCode': 'NCR-PRODUCT-${++n}',
          'inspectionKind': 'product',
          'productId': 1,
          'materialId': null,
          'materialName': 'NCR Product $role',
          'materialCode': 'NCR-P',
          'formulaNumber': 'F-1',
          'batchNumber': 'B-NCR',
          'parentRefs': {
            'productId': {
              'entityType': 'labProduct',
              'entityId': productId,
              'version': 1,
            },
          },
        });
        for (final id in [sampleId, otherSampleId]) {
          await seed('$root/productBatchSamples/$id', {
            ...common,
            'remoteId': id,
            'localId': id == sampleId ? 3 : 4,
            'batchId': 1,
            'batchRemoteId': headerId,
            'batchEntryCode': 'NCR-PRODUCT-$n',
            'sampleNo': id == sampleId ? 3 : 4,
            'sampleName': id == sampleId
                ? 'NCR sample 3 $role'
                : 'Other sample 4',
            'sampleTaker': 'Mohamed Said',
            'physicalResultsJson': '{}',
            'chemicalResultsJson': '[]',
            'testedAt': '2026-11-02T10:00:00',
            'decisionStatus': 'APPROVED',
            'decisionReason': '',
            'nonConformanceRemoteId': '',
            'parentRefs': {
              'batchId': {
                'entityType': 'sample',
                'entityId': headerId,
                'version': 1,
              },
            },
          });
        }
        final first = await openSyncFixture(), second = await openSyncFixture();
        final source = SessionSource(() => session);
        final outbox = CommandOutbox(first.helper)
          ..scopeProvider = () => CommandScope(org, uid, 'writer');
        outbox.deviceProvider = () => 'writer';
        CentralSyncDriver driver(SyncFixture cache) => CentralSyncDriver(
          databaseHelper: cache.helper,
          source: source,
          projection: CentralProjection(
            databaseHelper: cache.helper,
            source: source,
          ),
          transport: reader,
          outbox: cache == first ? outbox : CommandOutbox(cache.helper),
          metadata: SyncMetadata(cache.helper),
        );
        try {
          final a = driver(first), b = driver(second);
          await a.syncNow();
          await b.syncNow();
          // Cache-local IDs are device-specific. Give this sample a different
          // local ID on device B before receiving the finding incrementally.
          await second.db.transaction((txn) async {
            final before = (await txn.query(
              'product_batch_samples',
              where: 'remote_id = ?',
              whereArgs: [sampleId],
            )).single;
            final remapped = (before['id'] as int) + 5000;
            await txn.update(
              'product_batch_samples',
              {'id': remapped},
              where: 'remote_id = ?',
              whereArgs: [sampleId],
            );
            await txn.update(
              'central_entity_identities',
              {'local_ref': remapped},
              where: 'entity_type = ? AND entity_id = ?',
              whereArgs: ['productBatchSample', sampleId],
            );
          });
          final localId =
              (await first.db.query(
                    'product_batch_samples',
                    where: 'remote_id = ?',
                    whereArgs: [sampleId],
                  )).single['id']
                  as int;
          first.helper.businessGateway = CentralAuthoringGateway(
            databaseHelper: first.helper,
            source: source,
            outbox: outbox,
          );
          final repo = QcRepositories.serverConfirmed(
            dbHelper: first.helper,
            queue: SyncQueue(first.helper),
            syncAudit: AuditLogger(
              queue: SyncQueue(first.helper),
              session: () => source.session,
            ),
            guard: SessionWriteGuard(source: source, isOnline: () => true),
            actorReader: () =>
                QcActor(uid: uid, name: 'Lab specialist', deviceId: 'writer'),
          ).ncCapa;
          await expectLater(
            repo.saveProductSampleFinding(
              QcFindingNc(
                inspectionId: 0,
                productSampleId: localId,
                severity: 'Major',
                description: 'Protein is outside the approved range',
                qtyAffected: 2.5,
                qtyUnit: 'new-product-unit-$role',
                createdAt: '2026-11-02T10:00:00',
                updatedAt: '2026-11-02T10:00:00',
                createdBy: uid,
                updatedBy: uid,
              ),
            ),
            throwsA(isA<CentralDraftPending>()),
          );
          expect(
            await first.db.query(
              'qc_findings_nc',
              where: 'product_sample_id = ?',
              whereArgs: [localId],
            ),
            isEmpty,
          );
          expect(
            (await first.db.query(
              'product_batch_samples',
              where: 'id = ?',
              whereArgs: [localId],
            )).single['decision_status'],
            'APPROVED',
          );
          final command = (await outbox.list()).single;
          expect(
            command.payload['writes'],
            hasLength(4),
            reason:
                'Decision, finding, new quantity unit and audit are indivisible.',
          );
          for (final attack in ['missing_pointer', 'wrong_sample']) {
            final proxy = _MutateCommitClient((writes) {
              if (attack == 'missing_pointer') {
                final fields =
                    (writes.singleWhere(
                          (w) => '${w['update']['name']}'.contains(
                            '/productBatchSamples/',
                          ),
                        )['update']['fields'])
                        as Map;
                fields['nonConformanceRemoteId'] = {'stringValue': ''};
              } else {
                final fields =
                    (writes.singleWhere(
                          (w) => '${w['update']['name']}'.contains(
                            '/qcFindingsNc/',
                          ),
                        )['update']['fields'])
                        as Map;
                final ref =
                    fields['parentRefs']['mapValue']['fields']['productSampleId']['mapValue']['fields']
                        as Map;
                ref['entityId'] = {'stringValue': otherSampleId};
                ref['version'] = {'integerValue': '1'};
              }
            });
            final remote = FirestoreDirectStore(
              projectId: project,
              tokenProvider: () async => token,
              endpoint: Uri.parse('http://$host'),
              client: proxy,
            );
            try {
              final denied = await FirestoreDirectCommandTransport(
                store: remote,
                source: source,
                manifest: () async => manifest,
              ).submit(command.envelope());
              expect(denied.isApproved, isFalse, reason: attack);
              expect(
                (await store.get(
                  '$root/productBatchSamples/$sampleId',
                ))!.data['decisionStatus'],
                'APPROVED',
              );
            } finally {
              remote.close();
            }
          }
          final receipt = await transport.submit(command.envelope());
          expect(
            receipt.isApproved,
            isTrue,
            reason: receipt.failure?.messageAr,
          );
          expect(
            (await transport.submit(command.envelope())).changeSequence,
            receipt.changeSequence,
          );
          await a.syncNow();
          await b.syncNow();
          final localSecond = (await second.db.query(
            'product_batch_samples',
            where: 'remote_id = ?',
            whereArgs: [sampleId],
          )).single;
          final linked = (await second.db.query(
            'qc_findings_nc',
            where: 'product_sample_id = ?',
            whereArgs: [localSecond['id']],
          )).single;
          expect(localSecond['id'], isNot(localId));
          expect(localSecond['non_conformance_remote_id'], linked['remote_id']);
          final row = (await QcNcReportRepo(
            dbHelper: second.helper,
          ).list(NcrFilters(query: 'NCR sample 3 $role'))).single;
          expect(row.productSampleId, localSecond['id']);
          expect(
            (await QcAuditRepo(dbHelper: second.helper).verifyChain()).isValid,
            isTrue,
          );
        } finally {
          await first.dispose();
          await second.dispose();
        }
      },
      skip: !enabled,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'QC routine authoring keeps original audit hashes and rejects forged audits',
    () async {
      final first = await openSyncFixture();
      final second = await openSyncFixture();
      final source = SessionSource(() => session);
      final outbox = CommandOutbox(first.helper);
      outbox.scopeProvider = () => CommandScope(org, uid, 'writer');
      outbox.deviceProvider = () => 'writer';
      CentralSyncDriver driver(SyncFixture fixture) => CentralSyncDriver(
        databaseHelper: fixture.helper,
        source: source,
        projection: CentralProjection(
          databaseHelper: fixture.helper,
          source: source,
        ),
        transport: reader,
        outbox: fixture == first ? outbox : CommandOutbox(fixture.helper),
        metadata: SyncMetadata(fixture.helper),
      );
      try {
        final firstDriver = driver(first), secondDriver = driver(second);
        await firstDriver.syncNow();
        first.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: first.helper,
          source: source,
          outbox: outbox,
        );
        final audit = QcAuditRepo(
          dbHelper: first.helper,
          actorReader: () => QcActor(
            uid: uid,
            name: 'مستخدم "دقيق" \\ 🧪',
            deviceId: 'writer',
          ),
        );
        final repository = RoutineListsRepositoryImpl(
          dbHelper: first.helper,
          guard: SessionWriteGuard(source: source, isOnline: () => true),
          audit: audit,
          templates: QcTemplateRepo(first.helper),
          inspections: QcInspectionRepo(first.helper),
          queue: SyncQueue(first.helper),
        );
        await expectLater(
          repository.saveRoutineList(
            name: 'Verified routine',
            recurrence: 'yearly',
            items: ['Check'],
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        expect(await first.db.query('qc_templates'), isEmpty);
        expect(await first.db.query('qc_audits'), isEmpty);
        final command = (await outbox.list()).single;
        expect(
          command.payload['writes'],
          hasLength(4),
          reason: 'Template, section, item and audit remain atomic',
        );
        final originalAudit =
            (command.payload['writes'] as List).singleWhere(
                  (w) => w['entityType'] == 'qcAudit',
                )['payload']
                as Map;
        for (final field in [
          'byUserId',
          'hash',
          'targetGlobalId',
          'previousAuditId',
        ]) {
          final client = _MutateCommitClient((writes) {
            final fields =
                (writes.singleWhere(
                          (w) => w['update']['name'].toString().contains(
                            '/qcAudits/',
                          ),
                        )
                        as Map)['update']['fields']
                    as Map;
            fields[field] = {
              'stringValue': field == 'hash' ? '0' * 64 : 'forged-value',
            };
          });
          final maliciousStore = FirestoreDirectStore(
            projectId: project,
            tokenProvider: () async => token,
            endpoint: Uri.parse('http://$host'),
            client: client,
          );
          try {
            final result = await FirestoreDirectCommandTransport(
              store: maliciousStore,
              source: source,
              manifest: () async => manifest,
            ).submit(command.envelope());
            expect(client.mutated, isTrue);
            expect(
              result.failure?.code,
              CommandErrorCodes.permissionDenied,
              reason: '$field must be independently checked',
            );
          } finally {
            maliciousStore.close();
          }
        }
        final result = await transport.submit(command.envelope());
        expect(result.isApproved, isTrue, reason: result.failure?.messageAr);
        await firstDriver.syncNow();
        await secondDriver.syncNow();
        // Enable the same canonical read surface on the independently bootstrapped client.
        expect(
          (await second.db.query(
            'qc_templates',
            where: 'name = ?',
            whereArgs: ['Verified routine'],
          )).single['recurrence'],
          'yearly',
        );
        second.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: second.helper,
          source: source,
          outbox: CommandOutbox(second.helper),
        );
        final secondAudit = QcAuditRepo(dbHelper: second.helper);
        expect(
          (await audit.list()).any((row) => row.hash == originalAudit['hash']),
          isTrue,
        );
        expect(
          (await secondAudit.list()).any(
            (row) => row.hash == originalAudit['hash'],
          ),
          isTrue,
        );
        expect((await audit.verifyChain()).isValid, isTrue);
        expect((await secondAudit.verifyChain()).isValid, isTrue);
        final beforeLarge = (await store.get(
          '$root/counters/changeSequence',
        ))!.data['value'];
        await expectLater(
          repository.saveRoutineList(
            name: 'Oversized routine',
            items: List.generate(maxBusinessEffects, (i) => 'Item $i'),
          ),
          throwsA(
            isA<CentralDraftPending>().having(
              (e) => e.message,
              'explicit first release limit',
              largeOperationMessage,
            ),
          ),
        );
        expect(await outbox.list(), hasLength(1));
        final large = (await DraftsStore(first.helper).listOpen()).singleWhere(
          (d) => (d.payload['writes'] as List).length > maxBusinessEffects,
        );
        await expectLater(
          DomainDraftService(
            drafts: DraftsStore(first.helper),
            outbox: outbox,
            source: source,
            isOnline: () => true,
          ).submit(large.id),
          throwsA(isA<ValidationError>()),
        );
        expect(
          (await store.get('$root/counters/changeSequence'))!.data['value'],
          beforeLarge,
        );
        expect(await first.db.query('qc_templates'), hasLength(1));
        await expectLater(
          repository.saveRoutineList(
            name: 'Second small routine',
            items: ['Second check'],
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        final next = (await outbox.list()).singleWhere(
          (e) => e.operationId != command.operationId,
        );
        expect((await transport.submit(next.envelope())).isApproved, isTrue);
        await firstDriver.syncNow();
        await secondDriver.syncNow();
        expect((await audit.verifyChain()).isValid, isTrue);
        expect((await secondAudit.verifyChain()).isValid, isTrue);
        final observerTarget = (await second.db.query(
          'qc_templates',
          where: 'name = ?',
          whereArgs: ['Second small routine'],
        )).single;
        final originTarget = (await first.db.query(
          'qc_templates',
          where: 'name = ?',
          whereArgs: ['Second small routine'],
        )).single;
        expect(
          originTarget['template_id'],
          isNot(observerTarget['template_id']),
          reason: 'Unsent drafts reserve only origin-local ids',
        );
        expect(
          await secondAudit.list(
            entityType: 'TEMPLATE',
            entityId: '${observerTarget['template_id']}',
          ),
          hasLength(1),
        );
        expect(
          await first.db.query('qc_audits'),
          isEmpty,
          reason:
              'The immutable original table is never rewritten by projection',
        );
      } finally {
        await first.dispose();
        await second.dispose();
      }
    },
    skip: !enabled,
  );

  test(
    'QC routine two-item period opens, edits and records without approval authority',
    () async {
      final fixture = await openSyncFixture();
      final source = SessionSource(() => session);
      final outbox = CommandOutbox(fixture.helper);
      outbox.scopeProvider = () => CommandScope(org, uid, 'writer');
      outbox.deviceProvider = () => 'writer';
      final driver = CentralSyncDriver(
        databaseHelper: fixture.helper,
        source: source,
        projection: CentralProjection(
          databaseHelper: fixture.helper,
          source: source,
        ),
        transport: reader,
        outbox: outbox,
        metadata: SyncMetadata(fixture.helper),
      );
      Future<void> role(String value) async {
        await seed('users/$uid', {
          'organizationId': org,
          'role': value,
          'status': 'active',
          'displayName': 'Admin',
        });
        session = AppSession(
          uid: uid,
          organizationId: org,
          deviceId: 'writer',
          role: value,
          status: 'active',
        );
      }

      try {
        await driver.syncNow();
        fixture.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: fixture.helper,
          source: source,
          outbox: outbox,
        );
        final repository = RoutineListsRepositoryImpl(
          dbHelper: fixture.helper,
          guard: SessionWriteGuard(source: source, isOnline: () => true),
          audit: QcAuditRepo(
            dbHelper: fixture.helper,
            actorReader: () =>
                QcActor(uid: uid, name: 'Operator', deviceId: 'writer'),
          ),
          templates: QcTemplateRepo(fixture.helper),
          inspections: QcInspectionRepo(fixture.helper),
          queue: SyncQueue(fixture.helper),
        );
        Future<CommandOutboxEntry> stage(
          Future<dynamic> Function() action,
        ) async {
          final before = {
            for (final row in await outbox.list()) row.operationId,
          };
          await expectLater(action(), throwsA(isA<CentralDraftPending>()));
          return (await outbox.list()).singleWhere(
            (row) => !before.contains(row.operationId),
          );
        }

        Future<void> approve(
          CommandOutboxEntry command, {
          bool ordinaryWriter = false,
        }) async {
          try {
            if (ordinaryWriter) await role('trial_owner');
            final result = await transport.submit(command.envelope());
            expect(
              result.isApproved,
              true,
              reason:
                  '${command.payload['writes'].map((w) => w['entityType']).toList()}: ${result.failure?.code} ${result.failure?.messageAr}',
            );
            expect(
              (await transport.submit(command.envelope())).isApproved,
              true,
            );
          } finally {
            await role('admin');
          }
          await driver.syncNow();
        }

        final name = 'Period regression ${const Uuid().v4()}';
        await approve(
          await stage(
            () => repository.saveRoutineList(name: name, items: ['First']),
          ),
        );
        final templateId =
            (await fixture.db.query(
                  'qc_templates',
                  where: 'name = ?',
                  whereArgs: [name],
                )).single['template_id']
                as int;
        await approve(
          await stage(
            () => repository.saveRoutineList(
              templateId: templateId,
              name: '$name edited',
              items: ['First', 'Second'],
            ),
          ),
          ordinaryWriter: true,
        );
        final opening = await stage(
          () => repository.openPeriodSheet(templateId),
        );
        expect(opening.payload['writes'], hasLength(2));
        expect(
          (opening.payload['writes'] as List).any(
            (w) => w['entityType'] == 'qcResponse',
          ),
          false,
          reason: 'Opening a list never uploads empty responses for every item',
        );
        final inspectionPayload =
            (opening.payload['writes'] as List).singleWhere(
                  (w) => w['entityType'] == 'qcInspection',
                )['payload']
                as Map;
        expect(inspectionPayload['status'], 'InProgress');
        for (final field in [
          'approvedBy',
          'approvedAt',
          'closedAt',
          'rejectedAt',
        ]) {
          expect(inspectionPayload[field], '');
        }
        await role('trial_owner');
        for (final field in [
          'approvedBy',
          'approvedAt',
          'closedAt',
          'rejectedAt',
          'status',
          'scorePct',
        ]) {
          final client = _MutateCommitClient((writes) {
            final fields =
                (writes.singleWhere(
                      (w) => '${w['update']?['name'] ?? ''}'.contains(
                        '/qcInspections/',
                      ),
                    )['update']['fields'])
                    as Map;
            fields[field] = field == 'scorePct'
                ? {'doubleValue': 101}
                : {
                    'stringValue': field == 'status'
                        ? 'Approved'
                        : field == 'approvedBy'
                        ? uid
                        : '2026-11-08T12:00:00Z',
                  };
          });
          final malicious = FirestoreDirectStore(
            projectId: project,
            tokenProvider: () async => token,
            endpoint: Uri.parse('http://$host'),
            client: client,
          );
          try {
            final result = await FirestoreDirectCommandTransport(
              store: malicious,
              source: source,
              manifest: () async => manifest,
            ).submit(opening.envelope());
            expect(client.mutated, true);
            expect(
              result.failure?.code,
              CommandErrorCodes.permissionDenied,
              reason: field,
            );
          } finally {
            malicious.close();
          }
        }
        await approve(opening, ordinaryWriter: true);
        final sheet = await repository.openPeriodSheet(templateId);
        expect(sheet.rows, hasLength(2));
        final inspectionId = sheet.inspection.inspectionId!;
        final itemId = sheet.rows.first.item.itemId!;
        await approve(
          await stage(
            () => repository.toggleCheck(
              inspectionId: inspectionId,
              itemId: itemId,
            ),
          ),
          ordinaryWriter: true,
        );
        expect(
          (await repository.loadSheet(inspectionId)).rows.first.recorded,
          true,
        );
        await approve(
          await stage(
            () => repository.toggleCheck(
              inspectionId: inspectionId,
              itemId: itemId,
            ),
          ),
          ordinaryWriter: true,
        );
        expect(
          (await repository.loadSheet(inspectionId)).rows.first.recorded,
          false,
        );
        await approve(
          await stage(
            () => repository.recordDone(
              inspectionId: inspectionId,
              itemId: itemId,
            ),
          ),
          ordinaryWriter: true,
        );
        expect((await repository.taskLogs(inspectionId)).length, 1);
        expect(
          (await repository.loadSheet(inspectionId)).rows.first.recorded,
          true,
        );
      } finally {
        await role('admin');
        await fixture.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'five writable devices create concurrently and stale updates never overwrite',
    () async {
      final stores = <FirestoreDirectStore>[];
      final commands = <CommandEnvelope>[];
      final transports = <FirestoreDirectCommandTransport>[];
      final diagnostics = <String>[];
      try {
        for (var i = 0; i < 5; i++) {
          final device = 'multi_$i';
          await seed('$root/devices/$device', {
            'uid': uid,
            'status': 'active',
            'readOnly': false,
          });
          final actor = session.copyWith(deviceId: device);
          final s = FirestoreDirectStore(
            projectId: project,
            tokenProvider: () async => token,
            endpoint: Uri.parse('http://$host'),
          );
          stores.add(s);
          transports.add(
            FirestoreDirectCommandTransport(
              store: s,
              source: SessionSource(() => actor),
              manifest: () async => manifest,
              onDiagnostic: (code, message) =>
                  diagnostics.add('$device $code: $message'),
            ),
          );
          final original = frame();
          commands.add(
            CommandEnvelope.create(
              organizationId: org,
              commandType: CommandTypes.domainCommit,
              entityId: const Uuid().v4(),
              expectedVersion: 0,
              payload: original.payload,
              deviceId: device,
            ),
          );
        }
        final results = await Future.wait([
          for (var i = 0; i < 5; i++) transports[i].submit(commands[i]),
        ]);
        expect(
          results.every((r) => r.isApproved),
          isTrue,
          reason:
              '${results.map((r) => r.failure?.messageAr).join('; ')}\n${diagnostics.join('\n')}',
        );
        final original =
            (commands.first.payload['writes'] as List).single as Map;
        CommandEnvelope update(int device, String supplier) {
          final write =
              jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
          write['operation'] = 'update';
          write['expectedVersion'] = 1;
          (write['payload'] as Map)['supplier'] = supplier;
          return CommandEnvelope.create(
            organizationId: org,
            commandType: CommandTypes.domainCommit,
            entityId: const Uuid().v4(),
            expectedVersion: 0,
            payload: {
              'writes': [write],
            },
            deviceId: 'multi_$device',
          );
        }

        final race = await Future.wait([
          transports[0].submit(update(0, 'first')),
          transports[1].submit(update(1, 'second')),
        ]);
        expect(race.where((r) => r.isApproved), hasLength(1));
        expect(
          race.where((r) => !r.isApproved).single.failure?.code,
          CommandErrorCodes.versionConflict,
        );
        final saved = await store.get('$root/samples/${original['entityId']}');
        expect(saved!.data['version'], 2);
      } finally {
        for (final s in stores) {
          s.close();
        }
      }
    },
    skip: !enabled,
  );

  test(
    'rules reject forged fields, quantities, reservations and phantom event effects',
    () async {
      Future<void> deny(
        void Function(List<dynamic>) mutate, [
        String kind = 'inspection',
      ]) async {
        final client = _MutateCommitClient(mutate);
        final s = FirestoreDirectStore(
          projectId: project,
          tokenProvider: () async => token,
          endpoint: Uri.parse('http://$host'),
          client: client,
        );
        try {
          final before = (await store.get(
            '$root/counters/changeSequence',
          ))!.data['value'];
          final result = await FirestoreDirectCommandTransport(
            store: s,

            source: SessionSource(() => session),
            manifest: () async => manifest,
          ).submit(frame(kind));
          expect(
            client.mutated,
            isTrue,
            reason:
                'The malicious write must reach the server: ${result.failure?.messageAr}',
          );
          expect(result.isApproved, isFalse);
          expect(result.failure?.code, CommandErrorCodes.permissionDenied);
          expect(
            (await store.get('$root/counters/changeSequence'))!.data['value'],
            before,
          );
        } finally {
          s.close();
        }
      }

      Map fields(List<dynamic> writes, String collection) =>
          (writes.firstWhere(
                    (w) => ((w as Map)['update'] as Map)['name']
                        .toString()
                        .contains('/$collection/'),
                  )
                  as Map)['update']['fields']
              as Map;
      await deny(
        (writes) => fields(writes, 'samples')['untrustedField'] = {
          'stringValue': 'injected',
        },
      );
      await deny(
        (writes) => fields(writes, 'samples')['rejectedQuantity'] = {
          'stringValue': '9999',
        },
      );
      await deny(
        (writes) =>
            fields(writes, 'samples')['supplier'] = {'integerValue': '123'},
      );
      await deny(
        (writes) => fields(writes, 'samples')['chemicalReferenceJson'] = {
          'integerValue': '1',
        },
      );
      await deny(
        (writes) => fields(writes, 'samples')['decisionVersion'] = {
          'booleanValue': false,
        },
      );
      await deny(
        (writes) => writes.removeWhere(
          (w) =>
              w['update']['name'].toString().contains('/uniqueReservations/'),
        ),
      );
      await deny((writes) {
        final event = fields(writes, 'changeEvents');
        final records = event['records']['arrayValue']['values'] as List;
        records.first['mapValue']['fields']['version'] = {'integerValue': '99'};
      });
      await deny(
        (writes) => fields(writes, 'inventoryItems')['currentQty'] = {
          'doubleValue': 999,
        },
        'inventory',
      );
    },
    skip: !enabled,
  );

  test(
    'entry identity stays immutable even with a correctly replaced unique reservation',
    () async {
      final create = frame();
      expect((await transport.submit(create)).isApproved, isTrue);
      final write =
          jsonDecode(jsonEncode((create.payload['writes'] as List).single))
              as Map<String, dynamic>;
      final sampleId = write['entityId'];
      final originalCode = (write['payload'] as Map)['entryCode'];
      write['operation'] = 'update';
      write['expectedVersion'] = 1;
      (write['payload'] as Map)['supplier'] =
          'Valid edit with tampered identity';
      final changedCode = 'FORGED-${const Uuid().v4()}';
      final newKey = directUniqueClaims(
        'sample',
        (manifest['entities'] as Map)['sample'] as Map,
        {
          ...Map<String, dynamic>.from(write['payload'] as Map),
          'entryCode': changedCode,
        },
        write['relations'] as Map,
      ).single;
      final before = (await store.get(
        '$root/counters/changeSequence',
      ))!.data['value'];
      final originalReservationKey = directUniqueClaims(
        'sample',
        (manifest['entities'] as Map)['sample'] as Map,
        write['payload'] as Map<String, dynamic>,
        write['relations'] as Map,
      ).single;
      final heldReservation = (await store.get(
        '$root/uniqueReservations/$originalReservationKey',
      ))!;
      final client = _MutateCommitClient((writes) {
        final sample =
            writes.singleWhere(
                  (w) => w['update']['name'].toString().contains('/samples/'),
                )
                as Map;
        final fields = sample['update']['fields'] as Map;
        fields['entryCode'] = {'stringValue': changedCode};
        fields['protocol']['mapValue']['fields']['uniqueKeys'] = {
          'arrayValue': {
            'values': [
              {'stringValue': newKey},
            ],
          },
        };
        // Unchanged reservations are deliberately absent from normal updates.
        // Author both malicious reservation changes explicitly, so this test
        // continues to exercise the server rather than a transport accident.
        final previous = <String, dynamic>{
          'update': {
            'name': heldReservation.name,
            'fields': jsonDecode(jsonEncode(heldReservation.encodedFields)),
          },
          'currentDocument': {'updateTime': heldReservation.updateTime},
        };
        final receipt =
            writes.singleWhere(
                  (w) =>
                      '${w['update']?['name']}'.contains('/commandReceipts/'),
                )['update']['fields']
                as Map;
        for (final key in [
          'organizationId',
          'deviceId',
          'operationId',
          'sequence',
        ]) {
          previous['update']['fields'][key] = receipt[key];
        }
        writes.add(previous);
        final next = jsonDecode(jsonEncode(previous)) as Map<String, dynamic>;
        previous['update']['fields']['released'] = {'booleanValue': true};
        next['update']['name'] = store.name('$root/uniqueReservations/$newKey');
        next['update']['fields']['released'] = {'booleanValue': false};
        next['currentDocument'] = {'exists': false};
        writes.add(next);
      });
      final maliciousStore = FirestoreDirectStore(
        projectId: project,
        tokenProvider: () async => token,
        endpoint: Uri.parse('http://$host'),
        client: client,
      );
      try {
        final result =
            await FirestoreDirectCommandTransport(
              store: maliciousStore,
              source: SessionSource(() => session),
              manifest: () async => manifest,
            ).submit(
              CommandEnvelope.create(
                organizationId: org,
                commandType: CommandTypes.domainCommit,
                entityId: const Uuid().v4(),
                expectedVersion: 0,
                deviceId: 'writer',
                payload: {
                  'writes': [write],
                },
              ),
            );
        expect(client.mutated, isTrue);
        expect(result.failure?.code, CommandErrorCodes.permissionDenied);
        expect(
          (await store.get('$root/samples/$sampleId'))!.data['entryCode'],
          originalCode,
        );
        expect(
          (await store.get('$root/counters/changeSequence'))!.data['value'],
          before,
        );
      } finally {
        maliciousStore.close();
      }
    },
    skip: !enabled,
  );

  test(
    'one hundred replays preserve the original receipt and single effect',
    () async {
      final command = frame();
      final first = await transport.submit(command);
      expect(first.isApproved, isTrue);
      final head = (await store.get(
        '$root/counters/changeSequence',
      ))!.data['value'];
      for (var i = 0; i < 100; i++) {
        final replay = await transport.submit(command);
        expect(replay.toJson(), first.toJson());
      }
      expect(
        (await store.get('$root/counters/changeSequence'))!.data['value'],
        head,
      );
    },
    skip: !enabled,
  );

  test(
    'snapshot and incremental reads keep one server readTime while another device edits',
    () async {
      final command = frame();
      expect((await transport.submit(command)).isApproved, isTrue);
      final boundary = await reader.readHead();
      final write =
          jsonDecode(jsonEncode((command.payload['writes'] as List).single))
              as Map<String, dynamic>;
      write['operation'] = 'update';
      write['expectedVersion'] = 1;
      (write['payload'] as Map)['supplier'] = 'Changed after snapshot boundary';
      final update = CommandEnvelope.create(
        organizationId: org,
        commandType: CommandTypes.domainCommit,
        entityId: const Uuid().v4(),
        expectedVersion: 0,
        payload: {
          'writes': [write],
        },
        deviceId: 'writer',
      );
      expect((await transport.submit(update)).isApproved, isTrue);
      final page = await reader.readSnapshotPage('sample', boundary);
      final before = page.records.singleWhere(
        (r) => r.entityId == write['entityId'],
      );
      expect(before.version, 1);
      expect(before.data['supplier'], isNot('Changed after snapshot boundary'));
      final changes = await reader.readChanges(
        boundary.sequence,
        await reader.readHead(),
      );
      final after = changes.records.singleWhere(
        (r) => r.entityId == write['entityId'],
      );
      expect(after.version, 2);
      expect(after.data['supplier'], 'Changed after snapshot boundary');
    },
    skip: !enabled,
  );

  test(
    'expired trials and maintenance reject reads and writes on the server',
    () async {
      final original = (await store.get(root))!.data;
      try {
        await seed(root, {
          ...original,
          'status': 'trial',
          'trialEndsAt': DateTime.now().toUtc().subtract(
            const Duration(days: 1),
          ),
        });
        await expectLater(reader.readHead(), throwsA(isA<DirectStoreError>()));
        expect((await transport.submit(frame())).isApproved, isFalse);
        await seed(root, {
          ...original,
          'commandProtocol': {
            ...original['commandProtocol'] as Map,
            'maintenance': true,
          },
        });
        await expectLater(reader.readHead(), throwsA(isA<DirectStoreError>()));
        expect((await transport.submit(frame())).isApproved, isFalse);
      } finally {
        await seed(root, original);
      }
    },
    skip: !enabled,
  );
  test(
    'viewer reads allowed changes and cannot create receipts or modify business data',
    () async {
      final viewerSession = AppSession(
        uid: viewerUid,
        organizationId: org,
        deviceId: 'viewer',
        role: 'viewer',
        status: 'active',
        readOnlyDevice: true,
      );
      final viewerReader = FirestoreDirectSyncReader(
        store: viewerStore,
        source: SessionSource(() => viewerSession),
        manifest: () async => manifest,
      );
      final head = await viewerReader.call({
        'mode': 'beginSnapshot',
        'organizationId': org,
        'deviceId': 'viewer',
      });
      expect(head['throughSequence'], greaterThan(0));
      final tx = await viewerStore.begin();
      await expectLater(
        viewerStore.commit([
          viewerStore.write('$root/counters/changeSequence', {'value': 999}),
        ], tx),
        throwsA(isA<DirectStoreError>()),
      );
      try {
        await viewerStore.rollback(tx);
      } on Object {
        /*failed transaction*/
      }
    },
    skip: !enabled,
  );
  test(
    'business write without its atomic event and receipt is denied',
    () async {
      final command = frame();
      final w = (command.payload['writes'] as List).single;
      final tx = await store.begin();
      await expectLater(
        store.commit([
          store.write(
            '$root/samples/${w['entityId']}',
            {
              ...Map<String, dynamic>.from(w['payload'] as Map),
              'organizationId': org,
              'version': 1,
              'createdBy': uid,
              'updatedBy': uid,
              'deviceId': 'writer',
            },
            timestamps: ['createdAt', 'updatedAt'],
          ),
        ], tx),
        throwsA(isA<DirectStoreError>()),
      );
      try {
        await store.rollback(tx);
      } on Object {
        /*failed transaction*/
      }
    },
    skip: !enabled,
  );
  test(
    'fresh trial owner registers first device, opens empty archive and saves first material',
    () async {
      final account = await user('fresh-first-device');
      final freshUid = account['localId'] as String;
      final freshOrg = '${org}_fresh';
      final freshRoot = 'organizations/$freshOrg';
      await seed('users/$freshUid', {
        'organizationId': freshOrg,
        'role': 'trial_owner',
        'roles': ['trial_owner'],
        'status': 'active',
      });
      await seed(freshRoot, {
        'ownerUid': freshUid,
        'status': 'trial',
        'trialEndsAt': DateTime.now().toUtc().add(const Duration(days: 30)),
        'commandProtocol': freshOrganizationProtocol(freshOrg),
      });
      await seed('$freshRoot/counters/changeSequence', {
        'organizationId': freshOrg,
        'value': 0,
      });
      final freshSession = AppSession(
        uid: freshUid,
        organizationId: freshOrg,
        deviceId: 'first-device',
        role: 'trial_owner',
        status: 'active',
        organizationStatus: 'trial',
      );
      final source = SessionSource(() => freshSession);
      final freshStore = FirestoreDirectStore(
        projectId: project,
        tokenProvider: () async => account['idToken'] as String,
        endpoint: Uri.parse('http://$host'),
      );
      final local = await openSyncFixture();
      try {
        final devicePath = '$freshRoot/devices/first-device';
        expect(await freshStore.get(devicePath), isNull);
        final deviceTransaction = await freshStore.begin();
        await freshStore.commit([
          freshStore.write(
            devicePath,
            {
              'uid': freshUid,
              'role': 'trial_owner',
              'readOnly': false,
              'status': 'active',
              'version': 1,
            },
            current: null,
            timestamps: [],
          ),
        ], deviceTransaction);
        final freshReader = FirestoreDirectSyncReader(
          store: freshStore,
          source: source,
          manifest: () async => manifest,
        );
        final driver = CentralSyncDriver(
          databaseHelper: local.helper,
          source: source,
          projection: CentralProjection(
            databaseHelper: local.helper,
            source: source,
          ),
          transport: freshReader,
          outbox: CommandOutbox(local.helper),
          metadata: SyncMetadata(local.helper),
        );
        expect(await driver.syncNow(), 0);
        expect(await driver.currentSequence(), 0);
        expect(await local.db.query('inspections'), isEmpty);
        expect(await local.db.query('reference_materials'), isEmpty);
        final command = CommandEnvelope.create(
          organizationId: freshOrg,
          commandType: CommandTypes.domainCommit,
          entityId: const Uuid().v4(),
          expectedVersion: 0,
          deviceId: 'first-device',
          payload: {
            'writes': [
              {
                'entityType': 'referenceMaterial',
                'entityId': const Uuid().v4(),
                'operation': 'create',
                'expectedVersion': 0,
                'relations': <String, dynamic>{},
                'payload': {
                  'localId': 1,
                  'materialName': 'First material',
                  'materialCode': 'FIRST-1',
                  'physicalReferenceJson': '{}',
                  'chemicalReferenceJson': '{}',
                  'importedAt': '',
                  'active': 1,
                },
              },
            ],
          },
        );
        final result = await FirestoreDirectCommandTransport(
          store: freshStore,
          source: source,
          manifest: () async => manifest,
        ).submit(command);
        expect(
          result.status,
          CommandResult.statusApproved,
          reason: '${result.failure}',
        );
        await driver.syncNow();
        expect(
          (await local.db.query('reference_materials')).single['material_name'],
          'First material',
        );
      } finally {
        freshStore.close();
        await local.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'deleted local organization cache downloads the archive without uploading local rows',
    () async {
      final result = await transport.submit(frame());
      expect(result.status, CommandResult.statusApproved);
      final cold = await openSyncFixture();
      final source = SessionSource(() => session);
      try {
        expect(await cold.db.query('central_sync_state'), isEmpty);
        final driver = CentralSyncDriver(
          databaseHelper: cold.helper,
          source: source,
          projection: CentralProjection(
            databaseHelper: cold.helper,
            source: source,
          ),
          transport: reader,
          outbox: CommandOutbox(cold.helper),
          metadata: SyncMetadata(cold.helper),
        );
        final writesBefore = store.usage.documentsWritten;
        final head = await driver.syncNow();
        expect(await driver.currentSequence(), head);
        expect(await cold.db.query('inspections'), isNotEmpty);
        expect(await cold.db.query('reference_materials'), isNotEmpty);
        expect(await cold.db.query('command_outbox'), isEmpty);
        expect(store.usage.documentsWritten, writesBefore);
        final reads = store.usage.documentsRead;
        await driver.syncNow();
        expect(store.usage.documentsRead - reads, 1);
      } finally {
        await cold.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'material Save button commits to Firestore and returns to the list',
    (tester) async {
      AppText.useLanguage('en');
      addTearDown(() => AppText.useLanguage('ar'));
      final source = SessionSource(() => session);
      late SyncFixture writer;
      late ServerConfirmedReferenceRepository repo;
      late ServerConfirmedLabRepository lab;
      late FirestoreDirectStore uiStore;
      await tester.runAsync(() async {
        writer = await openSyncFixture();
        addTearDown(writer.dispose);
        uiStore = FirestoreDirectStore(
          projectId: project,
          tokenProvider: () async => token,
          endpoint: Uri.parse('http://$host'),
        );
        final outbox = CommandOutbox(writer.helper)
          ..scopeProvider = () => CommandScope(org, uid, 'writer');
        outbox.deviceProvider = () => 'writer';
        final driver = CentralSyncDriver(
          databaseHelper: writer.helper,
          source: source,
          projection: CentralProjection(
            databaseHelper: writer.helper,
            source: source,
          ),
          transport: FirestoreDirectSyncReader(
            store: uiStore,
            source: source,
            manifest: () async => manifest,
          ),
          outbox: outbox,
          metadata: SyncMetadata(writer.helper),
        );
        final writes = DirectWriteService(
          outbox: outbox,
          transport: FirestoreDirectCommandTransport(
            store: uiStore,
            source: source,
            manifest: () async => manifest,
          ),
          isOnline: () => true,
          synchronize: (seq) => driver.syncNow(throughSequence: seq),
        );
        await driver.syncNow();
        writer.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: writer.helper,
          source: source,
          outbox: outbox,
          isOnline: () => true,
          complete: writes.submitAndWait,
        );
        final guard = SessionWriteGuard(source: source, isOnline: () => true);
        final queue = SyncQueue(writer.helper);
        final audit = AuditLogger(queue: queue, session: () => session);
        repo = ServerConfirmedReferenceRepository(
          dbHelper: writer.helper,
          guard: guard,
          queue: queue,
          audit: audit,
        );
        lab = ServerConfirmedLabRepository(
          dbHelper: writer.helper,
          guard: guard,
          queue: queue,
          audit: audit,
        );
      });

      const size = Size(400, 860);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      bool? saved;
      await tester.pumpWidget(
        ScreenUtilInit(
          designSize: size,
          builder: (_, _) => MaterialApp(
            home: Builder(
              builder: (context) {
                return Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      saved = await Navigator.of(context).push<bool>(
                        MaterialPageRoute(
                          builder: (_) => MobileMaterialEditor(
                            refRepo: repo,
                            labConfig: lab,
                          ),
                        ),
                      );
                    },
                    child: const Text('Open material editor'),
                  ),
                );
              },
            ),
          ),
        ),
      );

      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 160 && finder.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(finder, findsOneWidget);
      }

      await tester.tap(find.text('Open material editor'));
      final save = find.text('Save');
      await waitFor(save);
      await tester.pumpAndSettle();
      Finder input(String label) => find.descendant(
        of: find.ancestor(
          of: find.text(label),
          matching: find.byType(AppField),
        ),
        matching: find.byType(EditableText),
      );
      final code = 'BTN-${const Uuid().v4().substring(0, 8)}';
      await tester.enterText(input('Material Name'), 'Button smoke $code');
      await tester.enterText(input('Material Code'), code);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await waitFor(find.text('Open material editor'));
      expect(saved, isTrue);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final row = (await writer.db.query(
          'reference_materials',
          where: 'material_code = ?',
          whereArgs: [code],
        )).single;
        final remote = await viewerStore.get(
          '$root/referenceMaterials/${row['remote_id']}',
        );
        expect(remote?.data['materialCode'], code);
      });
      uiStore.close();
    },
    skip: !enabled,
  );

  test(
    'direct online CRUD and manual offline drafts converge on two caches without auto upload',
    () async {
      final writer = await openSyncFixture(),
          observer = await openSyncFixture();
      final source = SessionSource(() => session);
      final outbox = CommandOutbox(writer.helper)
        ..scopeProvider = (() => CommandScope(org, uid, 'writer'))
        ..deviceProvider = (() => 'writer');
      final observerSession = AppSession(
        uid: viewerUid,
        organizationId: org,
        deviceId: 'viewer',
        role: 'viewer',
        status: 'active',
        readOnlyDevice: true,
      );
      final observerSource = SessionSource(() => observerSession);
      final observerOutbox = CommandOutbox(observer.helper)
        ..scopeProvider = (() => CommandScope(org, viewerUid, 'viewer'));
      final driver = CentralSyncDriver(
        databaseHelper: writer.helper,
        source: source,
        projection: CentralProjection(
          databaseHelper: writer.helper,
          source: source,
        ),
        transport: reader,
        outbox: outbox,
        metadata: SyncMetadata(writer.helper),
      );
      final observerDriver = CentralSyncDriver(
        databaseHelper: observer.helper,
        source: observerSource,
        projection: CentralProjection(
          databaseHelper: observer.helper,
          source: observerSource,
        ),
        transport: FirestoreDirectSyncReader(
          store: viewerStore,
          source: observerSource,
          manifest: () async => manifest,
        ),
        outbox: observerOutbox,
        metadata: SyncMetadata(observer.helper),
      );
      var online = true, retainDraft = true;
      final lossClient = _DropCommitReplyClient();
      final directStore = FirestoreDirectStore(
        projectId: project,
        tokenProvider: () async => token,
        endpoint: Uri.parse('http://$host'),
        client: lossClient,
      );
      final writes = DirectWriteService(
        outbox: outbox,
        transport: FirestoreDirectCommandTransport(
          store: directStore,
          source: source,
          manifest: () async => manifest,
        ),
        isOnline: () => online,
        synchronize: (seq) => driver.syncNow(throughSequence: seq),
        waitBudget: const Duration(seconds: 2),
      );
      final queue = SyncQueue(writer.helper);
      final repo = ServerConfirmedReferenceRepository(
        dbHelper: writer.helper,
        guard: SessionWriteGuard(source: source, isOnline: () => online),
        queue: queue,
        audit: AuditLogger(queue: queue, session: () => session),
      );
      try {
        await driver.syncNow();
        await observerDriver.syncNow();
        writer.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: writer.helper,
          source: source,
          outbox: outbox,
          isOnline: () => online,
          chooseOfflineDraft: () async => retainDraft,
          complete: writes.submitAndWait,
        );
        final suffix = DateTime.now().microsecondsSinceEpoch;
        final referenceMarker = 'Delivery parameter $suffix';
        final addedOnEdit = 'Delivery edit parameter $suffix';
        final referenceFields = <String, dynamic>{referenceMarker: '1'};
        final referenceUnits = <String, dynamic>{referenceMarker: '%'};
        final ids = <int>[];
        for (var i = 0; i < 3; i++) {
          ids.add(
            await repo.saveMaterialDefinition(
              materialName: 'Direct CRUD $suffix-$i',
              materialCode: 'D$suffix$i',
              chemicalReference: i == 0 ? referenceFields : const {},
              units: i == 0 ? referenceUnits : const {},
              bounds: [],
            ),
          );
        }
        for (var i = 0; i < ids.length; i++) {
          await repo.saveMaterialDefinition(
            id: ids[i],
            materialName: 'Updated CRUD $suffix-$i',
            materialCode: 'D$suffix$i',
            chemicalReference: i == 0
                ? {...referenceFields, addedOnEdit: '2'}
                : const {},
            units: i == 0 ? {...referenceUnits, addedOnEdit: '%'} : const {},
            bounds: [],
          );
        }
        await observerDriver.syncNow();
        final parameters = await observer.db.query(
          'parameters',
          where: 'parameter_name IN (?, ?)',
          whereArgs: [referenceMarker, addedOnEdit],
        );
        expect(
          {for (final row in parameters) row['parameter_name']: row['unit']},
          {referenceMarker: '%', addedOnEdit: '%'},
        );
        expect(
          await observer.db.query(
            'reference_materials',
            where: 'material_name LIKE ?',
            whereArgs: ['Updated CRUD $suffix-%'],
          ),
          hasLength(3),
        );
        online = false;
        final before = await outbox.list();
        await expectLater(
          repo.saveMaterialDefinition(
            materialName: 'Offline CRUD $suffix',
            materialCode: 'OFF$suffix',
            bounds: [],
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        expect((await outbox.list()).length, before.length);
        expect(
          await writer.db.query(
            'reference_materials',
            where: 'material_code = ?',
            whereArgs: ['OFF$suffix'],
          ),
          isEmpty,
        );
        retainDraft = false;
        await expectLater(
          repo.saveMaterialDefinition(
            materialName: 'Cancelled CRUD $suffix',
            materialCode: 'CAN$suffix',
            bounds: [],
          ),
          throwsA(isA<BusinessActionCancelled>()),
        );
        online = true;
        await writes.recover();
        await driver.syncNow();
        await observerDriver.syncNow();
        expect(
          await observer.db.query(
            'reference_materials',
            where: 'material_code = ?',
            whereArgs: ['OFF$suffix'],
          ),
          isEmpty,
          reason: 'Reconnect never submits a draft',
        );
        final drafts = DraftsStore(writer.helper);
        final draft = (await drafts.listOpen()).singleWhere(
          (d) => d.state == DraftState.localDraft,
        );
        final staged = await DomainDraftService(
          drafts: drafts,
          outbox: outbox,
          source: source,
          isOnline: () => online,
        ).submit(draft.id);
        expect(await writes.submitAndWait(staged), isTrue);
        await observerDriver.syncNow();
        expect(
          await observer.db.query(
            'reference_materials',
            where: 'material_code = ?',
            whereArgs: ['OFF$suffix'],
          ),
          hasLength(1),
        );
        lossClient.dropNextCommit = true;
        await expectLater(
          repo.saveMaterialDefinition(
            materialName: 'Lost reply CRUD $suffix',
            materialCode: 'LOST$suffix',
            bounds: [],
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        final commits = directStore.usage.documentsWritten;
        await writes.recover();
        expect(
          directStore.usage.documentsWritten,
          commits,
          reason: 'Recovery reads receipt only',
        );
        await observerDriver.syncNow();
        expect(
          await observer.db.query(
            'reference_materials',
            where: 'material_code = ?',
            whereArgs: ['LOST$suffix'],
          ),
          hasLength(1),
        );
        lossClient.denyReceiptAfterCommit = true;
        await expectLater(
          repo.saveMaterialDefinition(
            materialName: 'Committed receipt temporarily denied $suffix',
            materialCode: 'RCPT$suffix',
            bounds: [],
          ),
          throwsA(isA<CentralDraftPending>()),
        );
        final uncertain = (await outbox.list()).singleWhere(
          (entry) => entry.state == OutboxState.pending && entry.attempts > 0,
        );
        expect(uncertain.lastErrorCode, CommandErrorCodes.unavailable);
        expect(await writer.db.query('central_command_entities'), isNotEmpty);
        final writtenBeforeRecovery = directStore.usage.documentsWritten;
        await writes.recover();
        expect(directStore.usage.documentsWritten, writtenBeforeRecovery);
        expect(
          (await outbox.getByOperationId(uncertain.operationId))!.state,
          OutboxState.approved,
        );
        await observerDriver.syncNow();
        expect(
          await observer.db.query(
            'reference_materials',
            where: 'material_code = ?',
            whereArgs: ['RCPT$suffix'],
          ),
          hasLength(1),
        );
        for (final id in ids) {
          await repo.deleteMaterial(id);
        }
        await observerDriver.syncNow();
        final deleted = await observer.db.query(
          'reference_materials',
          where: 'material_name LIKE ?',
          whereArgs: ['Updated CRUD $suffix-%'],
        );
        expect(deleted, hasLength(3));
        expect(deleted.every((row) => row['active'] == 0), isTrue);
        expect(await writer.db.query('sync_queue'), isEmpty);
        expect(await writer.db.query('central_command_entities'), isEmpty);
      } finally {
        directStore.close();
        await writer.dispose();
        await observer.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'real outbox survives lost commit response and projects a formula on two devices',
    () async {
      final writer = await openSyncFixture();
      final viewer = await openSyncFixture();
      final writerSource = SessionSource(() => session);
      final viewerSession = AppSession(
        uid: viewerUid,
        organizationId: org,
        deviceId: 'viewer',
        role: 'viewer',
        status: 'active',
        readOnlyDevice: true,
      );
      final viewerSource = SessionSource(() => viewerSession);
      final lostClient = _DropCommitReplyClient();
      final lossStore = FirestoreDirectStore(
        projectId: project,
        tokenProvider: () async => token,
        endpoint: Uri.parse('http://$host'),
        client: lostClient,
      );
      try {
        final writerOutbox = CommandOutbox(writer.helper);
        writerOutbox.scopeProvider = () => CommandScope(org, uid, 'writer');
        writerOutbox.deviceProvider = () => 'writer';
        final viewerOutbox = CommandOutbox(viewer.helper);
        viewerOutbox.scopeProvider = () =>
            CommandScope(org, viewerUid, 'viewer');
        viewerOutbox.deviceProvider = () => 'viewer';
        final writerDriver = CentralSyncDriver(
          databaseHelper: writer.helper,
          source: writerSource,
          projection: CentralProjection(
            databaseHelper: writer.helper,
            source: writerSource,
          ),
          transport: reader,
          outbox: writerOutbox,
          metadata: SyncMetadata(writer.helper),
        );
        final viewerReader = FirestoreDirectSyncReader(
          store: viewerStore,
          source: viewerSource,
          manifest: () async => manifest,
        );
        final viewerDriver = CentralSyncDriver(
          databaseHelper: viewer.helper,
          source: viewerSource,
          projection: CentralProjection(
            databaseHelper: viewer.helper,
            source: viewerSource,
          ),
          transport: viewerReader,
          outbox: viewerOutbox,
          metadata: SyncMetadata(viewer.helper),
        );
        await writerDriver.syncNow();
        await viewerDriver.syncNow();
        final idleReads = store.usage.documentsRead;
        final idleRequests = store.usage.requests;
        await writerDriver.syncNow();
        expect(store.usage.documentsRead - idleReads, 1);
        expect(store.usage.requests - idleRequests, 1);
        writer.helper.businessGateway = CentralAuthoringGateway(
          databaseHelper: writer.helper,
          source: writerSource,
          outbox: writerOutbox,
        );
        final queue = SyncQueue(writer.helper);
        final repo = SqliteFormulationRepository(
          dbHelper: writer.helper,
          guard: SessionWriteGuard(source: writerSource, isOnline: () => false),
          queue: queue,
          audit: AuditLogger(queue: queue, session: () => session),
        );
        final material = (await writer.db.query(
          'reference_materials',
          where: 'remote_id = ?',
          whereArgs: ['server-material-1'],
        )).single;
        await expectLater(
          repo.save({
            'name': 'Direct offline formula',
            'items': [
              {
                'material_id': material['id'],
                'quantity_kg': 100,
                'price_per_kg': 2,
              },
            ],
          }),
          throwsA(isA<CentralDraftPending>()),
        );
        expect(await writer.db.query('nutrition_formulations'), isEmpty);
        var online = false;
        final worker = CommandWorker(
          outbox: writerOutbox,
          transport: FirestoreDirectCommandTransport(
            store: lossStore,
            source: writerSource,
            manifest: () async => manifest,
          ),
        )..canSend = () => online;
        expect((await worker.runOnce()).skippedOffline, 1);
        final previous =
            (await store.get('$root/counters/changeSequence'))!.data['value']
                as int;
        online = true;
        lostClient.dropNextCommit = true;
        // The deterministic retry ladder parks the entry for a few seconds
        // after the offline skip; pull the retry due instead of waiting it.
        await writer.db.update('command_outbox', {'next_attempt_at': null});
        expect((await worker.runOnce()).retried, 1);
        expect(
          (await store.get('$root/counters/changeSequence'))!.data['value'],
          previous + 1,
        );
        await writer.db.update('command_outbox', {'next_attempt_at': null});
        expect((await worker.runOnce()).approved, 1);
        expect(
          (await store.get('$root/counters/changeSequence'))!.data['value'],
          previous + 1,
        );
        await writerDriver.syncNow();
        await viewerDriver.syncNow();
        expect((await repo.list()).single['name'], 'Direct offline formula');
        final viewerQueue = SyncQueue(viewer.helper);
        final viewerRepo = SqliteFormulationRepository(
          dbHelper: viewer.helper,
          guard: SessionWriteGuard(source: viewerSource, isOnline: () => true),
          queue: viewerQueue,
          audit: AuditLogger(queue: viewerQueue, session: () => viewerSession),
        );
        final formula = (await viewerRepo.list()).single;
        expect(formula['name'], 'Direct offline formula');
        final items = jsonDecode(formula['items_json'] as String) as List;
        expect((items.single as Map)['quantity_kg'], 100);
        expect((items.single as Map)['material_id'], greaterThan(0));
        expect((await writerOutbox.counts()).awaitingProjection, 0);
      } finally {
        lossStore.close();
        await writer.dispose();
        await viewer.dispose();
      }
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'NIR scoped resets bind global parents, replay once and reject missing or foreign links',
    () async {
      CommandEnvelope reset({
        String scope = 'raw_material',
        bool link = true,
        String parentId = 'server-material-1',
        String type = 'referenceMaterial',
      }) {
        final id = const Uuid().v4();
        return CommandEnvelope.create(
          organizationId: org,
          commandType: CommandTypes.domainCommit,
          entityId: id,
          expectedVersion: 0,
          deviceId: 'writer',
          payload: {
            'writes': [
              {
                'entityType': 'nirValidationSettings',
                'entityId': id,
                'operation': 'create',
                'expectedVersion': 0,
                'payload': {
                  'configType': 'nir_validation_settings',
                  'localId': ++n,
                  'scope': scope,
                  'entityId': 913,
                  'entityName': 'Cement',
                  'parameter': 'Protein',
                  'materialId': scope == 'raw_material' ? 913 : null,
                  'productId': scope == 'product' ? 913 : null,
                  'referenceVersion': 1,
                  'calibrationSnapshotJson':
                      '{"version":1,"capturedAt":"2026-11-01","summaries":[]}',
                  'startDate': '2026-11-01',
                  'resetNote': '',
                  'resetBy': uid,
                  'resetByName': 'Admin',
                },
                'relations': {
                  if (link && scope.isNotEmpty)
                    scope == 'raw_material' ? 'materialId' : 'productId': {
                      'entityType': type,
                      'entityId': parentId,
                      'expectedVersion': 1,
                    },
                },
              },
            ],
          },
        );
      }

      final command = reset();
      final result = await transport.submit(command);
      expect(result.isApproved, isTrue, reason: '${result.failure}');
      expect((await transport.submit(command)).toJson(), result.toJson());
      final saved = (await store.get(
        '$root/labConfig/${command.entityId}',
      ))!.data;
      expect(
        saved['parentRefs']['materialId']['entityId'],
        'server-material-1',
      );
      await seed('$root/referenceMaterials/foreign-material', {
        'organizationId': 'another-organization',
        'version': 1,
        'deletedAt': null,
      });
      final product = CommandEnvelope.create(
        organizationId: org,
        commandType: CommandTypes.domainCommit,
        entityId: const Uuid().v4(),
        expectedVersion: 0,
        deviceId: 'writer',
        payload: {
          'writes': [
            {
              'entityType': 'labProduct',
              'entityId': 'reset-product',
              'operation': 'create',
              'expectedVersion': 0,
              'payload': {
                'configType': 'lab_products',
                'name': 'Reset product',
                'active': 1,
                'localId': ++n,
              },
            },
          ],
        },
      );
      expect((await transport.submit(product)).isApproved, isTrue);
      try {
        for (final invalid in [
          reset(link: false),
          reset(parentId: 'missing-material'),
          reset(parentId: 'foreign-material'),
          reset(scope: 'product'),
          reset(scope: 'unsupported'),
        ]) {
          expect((await transport.submit(invalid)).isApproved, isFalse);
          expect(
            await store.get('$root/labConfig/${invalid.entityId}'),
            isNull,
          );
        }
      } finally {
        final removed = await http.delete(
          Uri.parse(
            'http://$host/v1/projects/$project/databases/(default)/documents/$root/referenceMaterials/foreign-material',
          ),
          headers: {'Authorization': 'Bearer owner'},
        );
        expect(removed.statusCode, 200);
      }
      expect(
        (await transport.submit(reset(scope: '', link: false))).isApproved,
        isTrue,
      );
      expect(
        (await transport.submit(
          reset(
            scope: 'product',
            parentId: 'reset-product',
            type: 'labProduct',
          ),
        )).isApproved,
        isTrue,
      );
      // Bypass only the client's append-only admission, to prove that the
      // server itself refuses rewriting an already approved calibration record.
      final forgedManifest =
          jsonDecode(jsonEncode(manifest)) as Map<String, dynamic>;
      forgedManifest['entities']['nirValidationSettings']['appendOnly'] = false;
      final forged = FirestoreDirectCommandTransport(
        store: store,
        source: SessionSource(() => session),
        manifest: () async => forgedManifest,
      );
      final write = Map<String, dynamic>.from(
        (command.payload['writes'] as List).single as Map,
      );
      write['operation'] = 'update';
      write['expectedVersion'] = 1;
      write['payload'] = {
        ...Map<String, dynamic>.from(write['payload'] as Map),
        'resetNote': 'rewrite history',
      };
      final edit = CommandEnvelope.create(
        organizationId: org,
        commandType: CommandTypes.domainCommit,
        entityId: command.entityId,
        expectedVersion: 0,
        deviceId: 'writer',
        payload: {
          'writes': [write],
        },
      );
      expect((await forged.submit(edit)).isApproved, isFalse);
      expect(
        (await store.get('$root/labConfig/${command.entityId}'))!.data,
        saved,
      );
    },
    skip: !enabled,
  );
}

class _MutateCommitClient extends http.BaseClient {
  _MutateCommitClient(this.mutate);
  final void Function(List<dynamic>) mutate;
  final http.Client inner = http.Client();
  bool mutated = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request && request.url.path.endsWith(':commit')) {
      final data = jsonDecode(request.body) as Map<String, dynamic>;
      mutate(data['writes'] as List);
      request.body = jsonEncode(data);
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

class _DropCommitReplyClient extends http.BaseClient {
  final http.Client inner = http.Client();
  bool dropNextCommit = false;
  bool denyReceiptAfterCommit = false;
  bool _denyNextReceipt = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_denyNextReceipt &&
        request.method == 'GET' &&
        request.url.path.contains('/commandReceipts/')) {
      _denyNextReceipt = false;
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'error': {
                'status': 'PERMISSION_DENIED',
                'message': 'Simulated receipt access failure',
              },
            }),
          ),
        ),
        403,
      );
    }
    final response = await inner.send(request);
    if (denyReceiptAfterCommit &&
        request.url.path.endsWith('/documents:commit') &&
        response.statusCode == 200) {
      denyReceiptAfterCommit = false;
      _denyNextReceipt = true;
    }
    if (dropNextCommit &&
        request.url.path.endsWith('/documents:commit') &&
        response.statusCode == 200) {
      dropNextCommit = false;
      await response.stream.drain<void>();
      throw const SocketException('simulated lost reply after server commit');
    }
    return response;
  }

  @override
  void close() => inner.close();
}
