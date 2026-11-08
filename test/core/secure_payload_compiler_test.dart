import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/security/secure_migration_scope.dart';
import 'package:material_lab/core/security/secure_payload_compiler.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import '../sync/sync_test_fixture.dart';

const specialist = AppSession(
  uid: 'u',
  organizationId: 'o',
  deviceId: 'd',
  role: AppRoles.lab,
  status: MemberStatus.active,
);
const manager = AppSession(
  uid: 'q',
  organizationId: 'o',
  deviceId: 'd',
  role: AppRoles.qualityManager,
  status: MemberStatus.active,
);

Map<String, Object?> sample({int version = 0}) => {
  'entityType': 'sample',
  'entityId': 'source-id',
  'expectedVersion': version,
  'operation': version == 0 ? 'create' : 'update',
  'payload': <String, dynamic>{
    'localId': 1,
    'physicalReferenceJson': jsonEncode({'Color': 'Normal'}),
    'chemicalReferenceJson': jsonEncode({
      'Moisture': {'value': '10-12', 'required': true, 'secure': true},
      'Fat': '2-5',
    }),
    'physicalResultsJson': jsonEncode({
      'Color': ['Normal'],
    }),
    'chemicalResultsJson': jsonEncode({
      'Moisture': [17],
      'Fat': [3],
    }),
    'snapshotJson': jsonEncode({
      'chemical_results': {
        'Moisture': [17],
        'Fat': [3],
      },
    }),
  },
  'relations': <String, dynamic>{},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture fixture;
  setUp(() async => fixture = await openSyncFixture());
  tearDown(() => fixture.dispose());

  test(
    'list records using parameter_name retain the protected reading privately',
    () async {
      final write = sample();
      (write['payload'] as Map)['chemicalResultsJson'] = jsonEncode([
        {'parameter_name': 'Moisture', 'value': 17},
        {'parameter_name': 'Fat', 'value': 3},
      ]);
      final writes = [write];
      await compileSecurePayloads(
        db: fixture.db,
        session: specialist,
        writes: writes,
      );
      final public = write['payload'] as Map;
      expect(jsonDecode(public['chemicalResultsJson'] as String), [
        {'parameter_name': 'Fat', 'value': 3},
      ]);
      final fields =
          jsonDecode((writes.last['payload'] as Map)['fieldsJson'] as String)
              as Map;
      expect(jsonDecode(fields['chemical_results_json'] as String), [
        {'parameter_name': 'Moisture', 'value': 17},
      ]);
    },
  );
  test(
    'blind first save atomically partitions values, references and duplicate snapshots',
    () async {
      final writes = [sample()];
      await compileSecurePayloads(
        db: fixture.db,
        session: specialist,
        writes: writes,
      );
      expect(writes.length, 2);
      final public = writes.first['payload'] as Map;
      expect(jsonDecode(public['chemicalResultsJson'] as String), {
        'Fat': [3],
      });
      expect(jsonDecode(public['chemicalReferenceJson'] as String), {
        'Fat': '2-5',
      });
      expect(jsonDecode(public['snapshotJson'] as String), {
        'chemical_results': {
          'Fat': [3],
        },
      });
      final secret = writes.last['payload'] as Map;
      final fields = jsonDecode(secret['fieldsJson'] as String) as Map;
      expect(jsonDecode(fields['chemical_results_json'] as String), {
        'Moisture': [17],
      });
      expect(secret['sourceVersion'], 1);
      expect(secret['sourceKind'], 'sample');
      expect(public['secureEntryId'], writes.last['entityId']);
      expect((writes.last['relations'] as Map)['inspectionId'], {
        'entityType': 'sample',
        'entityId': 'source-id',
        'expectedVersion': 0,
      });
    },
  );
  test(
    'approved success DTO does not echo a protected field to its inputter',
    () async {
      final writes = [sample()];
      await compileSecurePayloads(
        db: fixture.db,
        session: specialist,
        writes: writes,
      );
      final dto =
          publicAuthoringValue({
                'id': 1,
                'chemical_results': {
                  'Moisture': [17],
                  'Fat': [3],
                },
              }, writes)
              as Map;
      expect(dto['chemical_results'], {
        'Fat': [3],
      });
    },
  );
  test(
    'ordinary edits retain the immutable private pointer without rewriting its content',
    () async {
      final write = sample(version: 4);
      final payload = write['payload'] as Map;
      payload['secureEntryId'] = 'previous-private';
      final writes = [write];
      await compileSecurePayloads(
        db: fixture.db,
        session: specialist,
        writes: writes,
      );
      expect(writes.length, 1);
      expect(payload['secureEntryId'], 'previous-private');
      expect(jsonDecode(payload['chemicalResultsJson'] as String), {
        'Fat': [3],
      });
    },
  );
  test(
    'historical migration uses the new source version and preserves measured numbers',
    () async {
      final write = sample(version: 7);
      final payload = write['payload'] as Map;
      payload['chemicalReferenceJson'] = jsonEncode({
        'Moisture': '10-12',
        'Fat': '2-5',
      });
      final writes = [write];
      await const SecureMigrationScope('job-id', {'moisture'}).run(
        () => compileSecurePayloads(
          db: fixture.db,
          session: manager,
          writes: writes,
        ),
      );
      expect((writes.last['payload'] as Map)['sourceVersion'], 8);
      expect(write['privacyMigrationJob'], 'job-id');
      expect(
        (writes.last['relations'] as Map)['inspectionId']['expectedVersion'],
        7,
      );
      expect(jsonDecode(payload['chemicalResultsJson'] as String), {
        'Fat': [3],
      });
      final fields =
          jsonDecode((writes.last['payload'] as Map)['fieldsJson'] as String)
              as Map;
      expect(jsonDecode(fields['chemical_results_json'] as String), {
        'Moisture': [17],
      });
    },
  );
  test('turning Secure off applies to historical rows as well', () async {
    final write = sample(version: 8);
    final payload = write['payload'] as Map;
    payload['secureEntryId'] = 'previous-private';
    final writes = [write];
    await const SecureMigrationScope('off-job', {}).run(
      () => compileSecurePayloads(
        db: fixture.db,
        session: manager,
        writes: writes,
      ),
    );
    expect(writes.length, 1);
    expect(payload['secureEntryId'], null);
    expect(jsonDecode(payload['chemicalResultsJson'] as String), {
      'Moisture': [17],
      'Fat': [3],
    });
  });
  test(
    'specialists cannot use a migration scope to rewrite approved private data',
    () async {
      await expectLater(
        const SecureMigrationScope('forged', {'moisture'}).run(
          () => compileSecurePayloads(
            db: fixture.db,
            session: specialist,
            writes: [sample(version: 1)],
          ),
        ),
        throwsA(isA<AuthorizationError>()),
      );
    },
  );
  test(
    'NIR public history loses protected names and coefficients; immutable original is retained',
    () async {
      final original = jsonEncode({
        'version': 1,
        'appliedCorrection': {'slope': 1.2},
        'summaries': [
          {
            'scope': 'raw_material',
            'entityRemoteId': 'corn',
            'parameter': 'Moisture',
            'meanLab': 17,
          },
          {
            'scope': 'raw_material',
            'entityRemoteId': 'soy',
            'parameter': 'Moisture',
            'meanLab': 11,
          },
        ],
      });
      final write = <String, Object?>{
        'entityType': 'nirValidationSettings',
        'entityId': 'reset',
        'operation': 'update',
        'expectedVersion': 1,
        'payload': <String, dynamic>{
          'calibrationSnapshotJson': original,
          'parameter': 'Moisture',
          'resetNote': 'original note',
          'scope': 'raw_material',
        },
        'relations': {
          'materialId': {'entityId': 'corn'},
        },
      };
      final writes = [write];
      await const SecureMigrationScope(
        'job',
        {'moisture'},
        secureTargets: {
          'raw_material|corn': {'moisture'},
        },
      ).run(
        () => compileSecurePayloads(
          db: fixture.db,
          session: manager,
          writes: writes,
        ),
      );
      final public = writes.first['payload'] as Map;
      final snapshot =
          jsonDecode(public['calibrationSnapshotJson'] as String) as Map;
      expect(snapshot['summaries'], [
        {
          'scope': 'raw_material',
          'entityRemoteId': 'soy',
          'parameter': 'Moisture',
          'meanLab': 11,
        },
      ]);
      expect(snapshot.containsKey('appliedCorrection'), false);
      expect(public['parameter'], '__secure__');
      expect(public['secureResult'], 1);
      expect((writes.last['payload'] as Map)['originalSnapshotJson'], original);
      expect((writes.last['payload'] as Map)['originalParameter'], 'Moisture');
    },
  );
}
