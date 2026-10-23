import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/push_worker.dart';
import 'package:material_lab/core/sync/remote/in_memory_data_source.dart';
import 'package:material_lab/core/sync/sync_metadata.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/lab/data/offline_first_lab_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import 'sync_test_fixture.dart';

class _LiveGuard implements WriteGuard {
  _LiveGuard(this.session, this.isOnline);

  final AppSession session;
  final bool isOnline;

  @override
  bool get online => isOnline;
  @override
  String get uid => session.uid;
  @override
  String get organizationId => session.organizationId;
  @override
  String get memberId => session.memberId;
  @override
  String get deviceId => session.deviceId;
  @override
  String get email => session.email;

  @override
  bool allows(String permissionId) {
    final permission = Permission.byId(permissionId);
    if (permission == null) return false;
    return session.canDo(permission, online: online);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fx;
  late SyncQueue queue;
  late AuditLogger audit;
  late AppSession session;
  late OfflineFirstLabRepository repo;
  late InMemoryDataSource remote;
  late SyncMetadata metadata;
  late PushWorker pushWorker;
  late int productId;
  late int batchId;

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();

    session = AppSession(
      uid: 'uid_admin',
      email: 'admin@material-lab.test',
      organizationId: orgId,
      memberId: 'member_admin',
      role: AppRoles.admin,
      status: 'active',
      deviceId: 'dev_AAAAAA',
    );

    queue = SyncQueue(fx.helper);
    metadata = SyncMetadata(fx.helper);
    audit = AuditLogger(queue: queue, session: () => session);
    remote = InMemoryDataSource(
      rolesByUid: const {'uid_admin': 'admin'},
    );

    final source = SessionSource.empty(() => session);
    pushWorker = PushWorker(
      queue: queue,
      metadata: metadata,
      remote: remote,
      audit: audit,
      source: source,
    );

    repo = OfflineFirstLabRepository(
      dbHelper: fx.helper,
      guard: _LiveGuard(session, true),
      queue: queue,
      audit: audit,
    );

    productId = await fx.db.rawInsert(
      "INSERT INTO lab_products (name, category, description, created_at) "
      "VALUES ('Flour 50T', 'Food', '', 'x')",
    );
    batchId = await fx.db.rawInsert(
      'INSERT INTO inspections (entry_code, material_id, material_name, '
      'material_code, inspection_date, specialist_name, '
      'physical_results_json, chemical_results_json, '
      'physical_reference_json, chemical_reference_json, decision_status, '
      'snapshot_json, sample_names_json, decision_version, created_by, '
      'created_by_name, created_at, updated_at, inspection_kind, '
      'product_id, batch_number, quantity) '
      "VALUES ('BATCH-50T', 1, 'Flour 50T', 'PFLO', '2026-01-01', 'QC', "
      "'{}', '{}', '{}', '{}', '', '{}', '[]', 1, 1, 'Ahmed Ali', 'x', 'x', "
      "'product', ?, 'LOT-7', '50 tons')",
      [productId],
    );
  });

  tearDown(() async {
    await fx.dispose();
  });

  test('addBatchSample pushes consecutive samples to remote', () async {
    const user = {'id': 1, 'uid': 'uid_admin', 'fullName': 'Ahmed Ali'};

    await repo.addBatchSample(batchId: batchId, user: user);
    await repo.addBatchSample(batchId: batchId, user: user);

    await pushWorker.runOnce();

    final remoteDocs = remote.documents;
    final sampleDocs = remoteDocs.keys
        .where((k) => k.contains('productBatchSamples'))
        .toList();

    expect(sampleDocs, hasLength(2),
        reason: 'Both consecutive samples should be pushed to remote');
  });
}
