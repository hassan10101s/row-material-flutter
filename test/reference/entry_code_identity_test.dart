import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/commands/drafts_store.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import '../sync/sync_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncFixture fixture;
  late ReferenceRepo reference;
  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    reference = ReferenceRepo(
      dbHelper: fixture.helper,
      deviceTagProvider: () async =>
          'device_windows_aaaaaaaa-bbbb-cccc-dddd-eeeeff123456',
    );
  });
  tearDown(() async => fixture.dispose());

  test(
    'readable entry code uses the device identity suffix and never DEVICE',
    () async {
      final code = await reference.generateEntryCode('RB', '2026-11-02');
      expect(code, 'RB-20261102-123456-001');
      final other = ReferenceRepo(
        dbHelper: fixture.helper,
        deviceTagProvider: () async =>
            'device_android_aaaaaaaa-bbbb-cccc-dddd-eeeeff654321',
      );
      expect(
        await other.generateEntryCode('RB', '2026-11-02'),
        'RB-20261102-654321-001',
      );
    },
  );

  test('prepared unsent inspections reserve their readable sequence', () async {
    await DraftsStore(fixture.helper).save(
      CommandDraft(
        id: 'draft-one',
        organizationId: 'org',
        uid: 'uid',
        entityType: 'domainTransaction',
        operation: 'create',
        entityId: 'transaction-one',
        parentEntityType: '',
        parentEntityId: '',
        baseVersion: 0,
        state: DraftState.localDraft,
        createdAt: '2026-11-02',
        updatedAt: '2026-11-02',
        payload: {
          'writes': [
            {
              'entityType': 'sample',
              'operation': 'create',
              'payload': {'entryCode': 'RB-20261102-123456-001'},
            },
          ],
        },
      ),
    );
    expect(
      await reference.generateEntryCode('RB', '2026-11-02'),
      'RB-20261102-123456-002',
    );
    // Another day and another device keep their independent sequences.
    expect(
      await reference.generateEntryCode('RB', '2026-11-03'),
      'RB-20261103-123456-001',
    );
  });

  test(
    'an existing entry code cannot be changed through the repository',
    () async {
      final repo = InspectionRepo(
        dbHelper: fixture.helper,
        referenceRepo: reference,
      );
      final created = await repo.create({
        'material_id': 1,
        'inspection_date': '2026-11-02',
        'supplier': 'Supplier',
        'sample_taken_by': 'Technician',
        'quantity': '20',
        'sample_names': ['S1'],
        'physical_results': <String, dynamic>{},
        'chemical_results': <String, dynamic>{},
        'decision_status': 'APPROVED',
      }, const UserContext(id: 1, fullName: 'Technician', role: 'admin'));
      final id = created['id'] as int;
      final code = created['entry_code'];
      expect(code, contains('-123456-'));
      await expectLater(
        repo.update(id, {
          'entry_code': 'MANUAL',
          'supplier': 'Modified',
        }, const UserContext(id: 1, fullName: 'Technician', role: 'admin')),
        throwsA(isA<ValidationError>()),
      );
      expect((await repo.getById(id))['entry_code'], code);
      expect((await repo.getById(id))['supplier'], 'Supplier');
      await repo.update(id, {
        'supplier': 'Updated supplier',
      }, const UserContext(id: 1, fullName: 'Technician', role: 'admin'));
      expect((await repo.getById(id))['entry_code'], code);
    },
  );
}
