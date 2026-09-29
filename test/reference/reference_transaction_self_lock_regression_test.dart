import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';
import 'package:material_lab/features/reference/data/offline_first_reference_repository.dart';

import '../sync/sync_test_fixture.dart';

/// Same regression as `transaction_self_lock_regression_test.dart`, for the
/// reference facade: its `super.*` calls used to run against the *database*
/// while the offline-first wrapper held the transaction lock -> the writes
/// queued behind their own lock ("database locked").
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
  late OfflineFirstReferenceRepository repo;

  setUp(() async {
    fixture = await openSyncFixture();
    await fixture.seedOrganization();
    final queue = SyncQueue(fixture.helper);
    final audit = AuditLogger(queue: queue);
    audit.organizationId = 'org_1';
    audit.uid = 'uid_admin';
    audit.userName = 'Ahmed Ali';
    audit.deviceId = 'dev_1';
    repo = OfflineFirstReferenceRepository(
      dbHelper: fixture.helper,
      guard: _AllowAllGuard(),
      queue: queue,
      audit: audit,
    );
  });

  tearDown(() async => fixture.dispose());

  test('material writes inside the audit transaction do not self-lock',
      () async {
    final id = await repo
        .createMaterial(
          materialName: 'Silica Sand',
          materialCode: 'M-SIL-01',
          chemicalReference: {'SiO2': '%'},
        )
        .timeout(const Duration(seconds: 15));
    expect(id, greaterThan(0));

    await repo
        .updateMaterial(
          id,
          materialName: 'Silica Sand 99',
          materialCode: 'M-SIL-01',
        )
        .timeout(const Duration(seconds: 15));
    final rows = await fixture.db
        .query('reference_materials', where: 'id = ?', whereArgs: [id]);
    expect(rows.first['material_name'], 'Silica Sand 99');

    await repo.deleteMaterial(id).timeout(const Duration(seconds: 15));
    final after = await fixture.db
        .query('reference_materials', where: 'id = ?', whereArgs: [id]);
    expect(after.first['active'], 0);
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('parameter and unit writes inside the audit transaction do not self-lock',
      () async {
    await repo
        .upsertParameter('pH', 'pH units')
        .timeout(const Duration(seconds: 15));
    await repo
        .upsertUnit('kHz', name: 'kilohertz', dimension: 'frequency')
        .timeout(const Duration(seconds: 15));

    await repo.deleteParameter('pH').timeout(const Duration(seconds: 15));
    await repo.deleteUnit('kHz').timeout(const Duration(seconds: 15));

    expect(await fixture.db.query('parameters'), isEmpty);
    expect(await fixture.db.query('lab_units'), isEmpty);
  }, timeout: const Timeout(Duration(seconds: 25)));
}