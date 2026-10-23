import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/auth/session_source.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/lab/data/offline_first_lab_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import '../sync/sync_test_fixture.dart';

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

/// End-to-end through the offline-first facade: receiving enqueues a lot,
/// running a test draws FEFO and queues the lot updates, and deleting the
/// test restores the pool EXACTLY (regression: the old facade restored the
/// pool twice — once itself, once via the base call).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncFixture fx;
  late OfflineFirstLabRepository repo;
  late int invId;
  late int analysisId;

  Future<double> pool() async {
    final rows = await fx.db.query(
      'lab_inventory',
      columns: ['current_qty'],
      where: 'id = ?',
      whereArgs: [invId],
    );
    return ((rows.single['current_qty'] as num?)?.toDouble() ?? 0.0);
  }

  Future<int> queueCount(String type) async {
    final rows = await fx.db.query(
      'sync_queue',
      where: 'entity_type = ?',
      whereArgs: [type],
    );
    return rows.length;
  }

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();
    final session = AppSession(
      uid: 'uid_admin',
      email: 'admin@material-lab.test',
      organizationId: 'org_test',
      memberId: 'member_admin',
      role: AppRoles.admin,
      status: 'active',
      deviceId: 'dev_AAAAAA',
    );
    final queue = SyncQueue(fx.helper);
    final audit = AuditLogger(queue: queue, session: () => session);
    SessionSource.empty(() => session);
    repo = OfflineFirstLabRepository(
      dbHelper: fx.helper,
      guard: _LiveGuard(session, true),
      queue: queue,
      audit: audit,
    );

    final item = await repo.addInventoryItem(
      name: 'Acid',
      category: 'liquid',
      unit: 'mL',
      qty: 0,
      minQty: 0,
    );
    invId = (item['id'] as num).toInt();
    await repo.receiveLot(
      inventoryId: invId,
      qty: 100,
      expiryDate: '2027-01-01',
      supplier: 'S1',
    );
    final created = await repo.createAnalysis(
      name: 'Acidity',
      unit: '%',
      dynamicFields: ['Sample Name'],
      items: [
        {'inventory_id': invId, 'qty_per_sample': 15, 'unit': 'mL'},
      ],
    );
    analysisId = (created['id'] as num).toInt();
  });

  tearDown(() async {
    await fx.dispose();
  });

  test('receive queues a lot; run draws FEFO; delete restores exactly',
      () async {
    expect(await pool(), 100.0);
    expect(await queueCount('inventoryLot'), 1);

    final result = await repo.runSampleTest(
      analysisId: analysisId,
      sourceType: 'raw_material',
      sourceName: 'Wheat',
      sampleName: 'Sample A',
    );
    expect(await pool(), 85.0);
    final testId = (result['test'] as Map)['id'] as int;
    // Lot update queued (remaining 85), consumption line queued with lot ref.
    expect(await queueCount('inventoryLot'), greaterThanOrEqualTo(1));
    expect(await queueCount('consumption'), 1);
    final lines = await fx.db.query(
      'lab_consumption_log',
      where: 'sample_test_id = ?',
      whereArgs: [testId],
    );
    expect(lines, hasLength(1));
    expect(lines.single['lot_id'], isNotNull);
    expect('${lines.single['lot_no']}', isNotEmpty);

    await repo.deleteSampleTest(testId);
    // Exactly restored — not 115 (the old double-restore).
    expect(await pool(), 100.0);
    final lots = await repo.listInventoryLots(invId);
    expect(lots.single['qty_remaining'], 100.0);
    final reversals = await fx.db.query(
      'lab_consumption_log',
      where: 'sample_test_id = ? AND event_type = ?',
      whereArgs: [testId, 'REVERSAL'],
    );
    expect(reversals, hasLength(1));
    expect(reversals.single['lot_id'], lines.single['lot_id']);
  });

  test('increase without expiry is refused', () async {
    expect(
      () => repo.adjustStock(itemId: invId, newQty: 150),
      throwsA(isA<Exception>()),
    );
    expect(await pool(), 100.0);
    final item = await repo.adjustStock(
      itemId: invId,
      newQty: 150,
      expiryDate: '2028-01-01',
      reason: 'top-up',
    );
    expect(item['current_qty'], 150.0);
    expect(await pool(), 150.0);
  });
}
