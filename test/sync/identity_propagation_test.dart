import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/conflict_resolver.dart';
import 'package:material_lab/core/sync/pull_worker.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/remote/remote_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reference/data/offline_first_reference_repository.dart';

import 'sync_test_fixture.dart';

/// Cross-device identity regression suite (comprehensive sync §1):
/// `remote_id` is the ONLY identity for uuid-identity tables, and deletions
/// must reach the other device. Before the `findLocalRef` fix these flows
/// silently diverged: tombstones no-op'd and edits duplicated or skipped.
class _Device {
  _Device(this.fixture, this.label, this.session);

  final SyncFixture fixture;
  final String label;
  AppSession session;

  late final SyncQueue queue = SyncQueue(fixture.helper);
  late final SyncMetadata metadata = SyncMetadata(fixture.helper);
  late final AuditLogger audit = AuditLogger(
    queue: queue,
    session: () => session,
  );
  late bool online = true;

  SessionSource get source => SessionSource.empty(() => session);

  PushWorker pusher(InMemoryDataSource remote) => PushWorker(
    queue: queue,
    metadata: metadata,
    remote: remote,
    audit: audit,
    source: source,
  );

  PullWorker puller(InMemoryDataSource remote, {int pageSize = 300}) =>
      PullWorker(
        queue: queue,
        metadata: metadata,
        remote: remote,
        conflicts: ConflictResolver(queue: queue, remote: remote),
        source: source,
        pageSize: pageSize,
      );

  OfflineFirstReferenceRepository repo() => OfflineFirstReferenceRepository(
    dbHelper: fixture.helper,
    guard: _LiveGuard(this),
    queue: queue,
    audit: audit,
  );

  Future<List<Map<String, Object?>>> rows() =>
      fixture.db.query('reference_materials');
}

class _LiveGuard implements WriteGuard {
  _LiveGuard(this.device);

  final _Device device;

  @override
  bool get online => device.online;
  @override
  String get uid => device.session.uid;
  @override
  String get organizationId => device.session.organizationId;
  @override
  String get memberId => device.session.memberId;
  @override
  String get deviceId => device.session.deviceId;
  @override
  String get email => device.session.email;

  @override
  bool allows(String permissionId) {
    final permission = Permission.byId(permissionId);
    if (permission == null) return false;
    return device.session.canDo(permission, online: device.online);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late _Device laptop;
  late _Device phone;
  late InMemoryDataSource remote;

  AppSession sessionFor(String deviceId) => AppSession(
    uid: 'uid_$deviceId',
    email: '$deviceId@material-lab.test',
    organizationId: orgId,
    memberId: 'member_$deviceId',
    role: AppRoles.admin,
    status: 'active',
    deviceId: deviceId,
  );

  setUp(() async {
    final a = await openSyncFixture();
    final b = await openSyncFixture();
    laptop = _Device(a, 'laptop', sessionFor('dev_1'));
    phone = _Device(b, 'phone', sessionFor('dev_2'));
    remote = InMemoryDataSource(
      rolesByUid: const {'uid_dev_1': 'admin', 'uid_dev_2': 'admin'},
    );
  });

  tearDown(() async {
    await laptop.fixture.dispose();
    await phone.fixture.dispose();
  });

  /// Creates a material on the laptop and replicates it to the phone.
  Future<int> createAndReplicate(String code, String name) async {
    final id = await laptop.repo().createMaterial(
      materialName: name,
      materialCode: code,
    );
    expect(await laptop.pusher(remote).runOnce().then((r) => r.conflicts), 0);
    expect(await phone.puller(remote).runOnce().then((r) => r.failed), 0);
    final rows = await phone.rows();
    expect(rows, hasLength(1), reason: 'precondition: replicated cleanly');
    expect('${rows.single['remote_id']}', isNotEmpty);
    return id;
  }

  test(
    'deleting a uuid-identity record on device 1 hides it on device 2',
    () async {
      final id = await createAndReplicate('RA-1', 'Reagent A');

      // Delete on device 1 (tombstone), then push.
      await laptop.repo().deleteMaterial(id);
      final pushed = await laptop.pusher(remote).runOnce();
      expect(pushed.conflicts, 0);

      // The tombstone document exists remotely with a bumped version.
      final rowRemoteId =
          '${(await laptop.rows()).single['remote_id']}';
      final doc = await remote.getDocument(
        organizationId: orgId,
        collection: SyncCollection.referenceMaterials,
        documentId: rowRemoteId,
      );
      expect(doc.exists, isTrue);
      expect(doc.data['deletedAt'], isNotNull);

      // Device 2 pulls the tombstone: its copy must be soft-deleted, not
      // silently skipped (the old behavior), not hard-deleted, not duplicated.
      final pulled = await phone.puller(remote).runOnce();
      expect(pulled.failed, 0);
      final rows = await phone.rows();
      expect(rows, hasLength(1));
      expect(rows.single['deleted_at'], isNotNull);
      expect(rows.single['sync_state'], 'synced');
      expect('${rows.single['remote_id']}', rowRemoteId);
    },
  );

  test(
    'an edit that changes the natural key still lands on the same row',
    () async {
      final id = await createAndReplicate('RA-1', 'Reagent A');

      // Rename + re-code (both are the natural key of reference_materials —
      // without the remote_id identity this edit used to duplicate or fail).
      await laptop.repo().updateMaterial(
        id,
        materialName: 'Reagent A renamed',
        materialCode: 'RA-9',
      );
      final pushed = await laptop.pusher(remote).runOnce();
      expect(pushed.conflicts, 0);

      final pulled = await phone.puller(remote).runOnce();
      expect(pulled.failed, 0);
      final rows = await phone.rows();
      expect(rows, hasLength(1), reason: 'same logical record, one local row');
      expect(rows.single['material_code'], 'RA-9');
      expect(rows.single['material_name'], 'Reagent A renamed');
      expect(rows.single['remote_version'], 2);
      expect(rows.single['sync_state'], 'synced');
      expect(await phone.queue.countPending(), 0);
    },
  );

  test(
    'a foreign document never overwrites an unrelated row via localId',
    () async {
      // Phone-side row with pk id=1 that owns a DIFFERENT identity.
      await phone.fixture.db.rawInsert(
        'INSERT INTO reference_materials (material_name, material_code, '
        'physical_reference_json, chemical_reference_json, imported_at, '
        'active, remote_id, device_id, version, remote_version, sync_state, '
        'updated_at) '
        "VALUES ('Mine', 'MINE-1', '{}', '{}', '2026-09-01', 1, 'uuid-mine', "
        "'dev_2', 1, 1, 'synced', '2026-09-01T08:00:00.000Z')",
      );
      // A foreign document whose origin-device localId is 1 (autoincrement
      // collision) and whose payload carries no natural key of the local row.
      remote.seed(
        orgId,
        SyncCollection.referenceMaterials,
        'uuid-foreign',
        <String, dynamic>{
          'localId': 1,
          'deviceId': 'dev_1',
          'remoteId': 'uuid-foreign',
          'organizationId': orgId,
          'materialName': 'Foreign',
          'materialCode': 'FOREIGN-1',
          'physicalReferenceJson': '{}',
          'chemicalReferenceJson': '{}',
          'importedAt': '2026-09-01',
          'active': 1,
          'createdBy': 'uid_dev_1',
          'deletedAt': null,
          'updatedAt': '2026-09-02T00:00:00.000Z',
        },
        version: 2,
      );

      final pulled = await phone.puller(remote).runOnce();
      expect(pulled.failed, 0);
      final rows = await phone.rows();
      expect(
        rows.where((r) => '${r['material_code']}' == 'MINE-1'),
        hasLength(1),
        reason: 'the unrelated local row is untouched',
      );
      expect(rows, hasLength(2), reason: 'the foreign doc lands as its own row');
      final foreign = rows.singleWhere(
        (r) => '${r['remote_id']}' == 'uuid-foreign',
      );
      // The inserted row adopts the document identity, so any later edit or
      // delete of that document converges on THIS row (never a duplicate).
      expect('${foreign['material_code']}', 'FOREIGN-1');
    },
  );
}
