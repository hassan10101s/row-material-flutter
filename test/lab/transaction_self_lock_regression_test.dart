import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/lab/data/offline_first_lab_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import '../sync/sync_test_fixture.dart';

/// Regression for the startup stall seen during `registerOrganizationBinder`:
/// the offline-first wrappers opened a `db.transaction` and then ran their
/// inner `LabRepo` queries against the **database** instead of the transaction.
/// On sqflite's serialized connection that inner query queues behind the very
/// lock the transaction holds -> "database locked" warnings that blocked the
/// Google sign-in (the binder awaited these writes).
class _AllowAllGuard implements WriteGuard {
  @override
  String get uid => 'uid_admin';
  @override
  String get email => 'admin@material-lab.test';
  @override
  String get organizationId => 'org_1';
  @override
  String get memberId => 'admin@material-lab.test';
  @override
  String get deviceId => 'dev_1';
  @override
  bool get online => true;
  @override
  bool allows(String permissionId) => true;
}

void main() {
  late SyncFixture fixture;
  late OfflineFirstLabRepository repo;

  setUp(() async {
    fixture = await openSyncFixture();
    final queue = SyncQueue(fixture.helper);
    final audit = AuditLogger(queue: queue);
    audit.organizationId = 'org_1';
    audit.uid = 'uid_admin';
    audit.userName = 'Ahmed Ali';
    audit.deviceId = 'dev_1';
    repo = OfflineFirstLabRepository(
      dbHelper: fixture.helper,
      guard: _AllowAllGuard(),
      queue: queue,
      audit: audit,
    );
  });

  tearDown(() async => fixture.dispose());

  // The whole point: these must finish well inside the timeout. With the old
  // null-executor queries they deadlocked against their own transaction and
  // only escaped when sqflite's lock resolution gave up.
  test('addInventoryItem inside the audit transaction does not self-lock',
      () async {
    final item = await repo
        .addInventoryItem(
          name: 'Salt A',
          category: 'powder',
          unit: 'kg',
          qty: 25.0,
          minQty: 5.0,
          user: const {'uid': 'uid_admin', 'name': 'Ahmed Ali'},
        )
        .timeout(const Duration(seconds: 15));

    expect(item['id'], isNotNull);
    expect(item['name'], 'Salt A');

    final rows =
        await fixture.db.query('lab_inventory', where: 'id = ?', whereArgs: [item['id']]);
    expect(rows, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('createAnalysis inside the audit transaction does not self-lock',
      () async {
    final analysis = await repo
        .createAnalysis(
          name: 'Purity',
          unit: '%',
          description: 'Assay by titration',
          dynamicFields: const ['Sample Name'],
        )
        .timeout(const Duration(seconds: 15));

    expect(analysis['id'], isNotNull);
    expect(analysis['name'], 'Purity');
    expect(analysis['dynamic_fields'], contains('Sample Name'));

    final rows =
        await fixture.db.query('lab_analyses', where: 'id = ?', whereArgs: [analysis['id']]);
    expect(rows, hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('product writes inside the audit transaction do not self-lock',
      () async {
    final product = await repo
        .createProduct(name: 'Cement', category: 'raw', description: 'Portland')
        .timeout(const Duration(seconds: 15));
    expect(product['id'], isNotNull);
    expect(product['name'], 'Cement');

    final updated = await repo
        .updateProduct(product['id'] as int, {'name': 'Cement 45'})
        .timeout(const Duration(seconds: 15));
    expect(updated['name'], 'Cement 45');

    final deleted = await repo
        .deleteProduct(product['id'] as int)
        .timeout(const Duration(seconds: 15));
    expect(deleted, {'archived': true});
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('stock adjustment and material bounds do not self-lock', () async {
    final item = await repo.addInventoryItem(
      name: 'Salt B',
      category: 'powder',
      unit: 'kg',
      qty: 10.0,
      minQty: 2.0,
      user: const {'uid': 'uid_admin', 'name': 'Ahmed Ali'},
    );
    final itemId = item['id'] as int;

    final adjusted = await repo
        .adjustStock(itemId: itemId, newQty: 12.0)
        .timeout(const Duration(seconds: 15));
    expect(adjusted['current_qty'], 12.0);

    await fixture.seedOrganization();
    final saved = await repo
        .saveMaterialBounds(1, [
          {
            'parameter_name': 'Moisture',
            'parameter_type': 'physical',
            'unit': '%',
            'min_value': 5,
            'max_value': 10,
          },
        ])
        .timeout(const Duration(seconds: 15));
    expect(saved['saved'], 1);
    expect(saved['material_id'], 1);

    final analyses = await repo.getMaterialAnalyses(1);
    expect(analyses['physical']['fields'], hasLength(1));
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('global constant writes do not self-lock', () async {
    final constant = await repo
        .upsertGlobalConstant({
          'name': 'Gravity',
          'symbol': 'g',
          'value_text': '9.81',
          'unit': 'm/s2',
        })
        .timeout(const Duration(seconds: 15));
    final id = constant['id'] as int;

    final deleted = await repo
        .deleteGlobalConstant(id)
        .timeout(const Duration(seconds: 15));
    expect(deleted, {'deleted': true});
  }, timeout: const Timeout(Duration(seconds: 25)));
}