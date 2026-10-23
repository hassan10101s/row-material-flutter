import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/features/lab/data/nir_validation_repo.dart';
import 'package:material_lab/features/lab/domain/nir_validation_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import '../sync/sync_test_fixture.dart';

class _LiveGuard implements WriteGuard {
  _LiveGuard(this.session);

  final AppSession session;

  @override
  bool get online => true;
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

/// NIR فلديشن repository:
/// - raw-material محضر result (NIR) pairs with the lab test sharing the entry
///   code and parameter,
/// - product batch samples pair with product-scoped lab tests,
/// - the horizon (reset start date) excludes older المحاضر,
/// - each reset appends a synced `nir_validation_settings` row (queue entry).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orgId = 'org_test';

  late SyncFixture fx;
  late SyncQueue queue;
  late AuditLogger audit;
  late AppSession session;
  late NirValidationRepo repo;
  late int analysisId;

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
    audit = AuditLogger(queue: queue, session: () => session);
    repo = NirValidationRepo(
      dbHelper: fx.helper,
      guard: _LiveGuard(session),
      queue: queue,
      audit: audit,
    );

    final parameterId = await fx.db.rawInsert(
      "INSERT INTO parameters (parameter_name, unit, imported_at) "
      "VALUES ('Protein', '%', '2026-01-01 00:00:00')",
    );
    analysisId = await fx.db.rawInsert(
      "INSERT INTO lab_analyses (name, unit, parameter_id, created_at) "
      "VALUES ('Protein', '%', ?, 'x')",
      [parameterId],
    );
  });

  tearDown(() async {
    await fx.dispose();
  });

  Future<int> seedRawInspection() => fx.db.rawInsert(
        'INSERT INTO inspections (entry_code, material_id, material_name, '
        'material_code, inspection_date, specialist_name, '
        'physical_results_json, chemical_results_json, '
        'physical_reference_json, chemical_reference_json, decision_status, '
        'snapshot_json, sample_names_json, decision_version, created_by, '
        'created_by_name, created_at, updated_at, inspection_kind, quantity) '
        "VALUES ('RAW-001', 1, 'Cement', 'M-CEM-01', '2026-01-01', 'QC', "
        "'{}', '{\"Protein\": \"12.5\"}', '{}', '{}', 'APPROVED', '{}', '[]', "
        "1, 1, 'Ahmed Ali', 'x', 'x', 'raw', '10 tons')",
      );

  Future<void> seedRawLabTest() => fx.db.rawInsert(
        'INSERT INTO lab_sample_tests (analysis_id, source_type, source_ref_id, '
        'source_name, sample_name, result_text, dynamic_values_json, '
        'entry_code, tested_by, tested_at) '
        "VALUES (?, 'raw_material', 1, 'Cement', '', '12.9', '{}', "
        "'RAW-001', 1, '2026-01-02 09:00:00')",
        [analysisId],
      );

  Future<void> seedBatch() async {
    final productId = await fx.db.rawInsert(
      "INSERT INTO lab_products (name, category, description, created_at) "
      "VALUES ('Flour 50T', 'Food', '', 'x')",
    );
    final batchId = await fx.db.rawInsert(
      'INSERT INTO inspections (entry_code, material_id, material_name, '
      'material_code, inspection_date, specialist_name, '
      'physical_results_json, chemical_results_json, '
      'physical_reference_json, chemical_reference_json, decision_status, '
      'snapshot_json, sample_names_json, decision_version, created_by, '
      'created_by_name, created_at, updated_at, inspection_kind, '
      'product_id, batch_number, quantity) '
      "VALUES ('BATCH-50T', 1, 'Flour 50T', 'PFLO', '2026-01-03', 'QC', "
      "'{}', '{}', '{}', '{}', '', '{}', '[]', 1, 1, 'Ahmed Ali', 'x', 'x', "
      "'product', ?, 'LOT-7', '50 tons')",
      [productId],
    );
    await fx.db.rawInsert(
      'INSERT INTO product_batch_samples (batch_id, sample_no, sample_name, '
      'physical_results_json, tested_at, created_at) '
      "VALUES (?, 1, 'Sample 1', '{\"Protein\": \"13.1\"}', "
      "'2026-01-03 09:00:00', 'x')",
      [batchId],
    );
    await fx.db.rawInsert(
      'INSERT INTO lab_sample_tests (analysis_id, source_type, source_ref_id, '
      'source_name, sample_name, result_text, dynamic_values_json, '
      'entry_code, tested_by, tested_at) '
      "VALUES (?, 'product', ?, 'Flour 50T', 'Sample 1', '13.5', '{}', "
      "'BATCH-50T', 1, '2026-01-03 10:00:00')",
      [analysisId, batchId],
    );
  }

  test('raw + product pairing produce per-parameter stats', () async {
    await seedRawInspection();
    await seedRawLabTest();
    await seedBatch();

    final report = await repo.compute();
    expect(report.stats, hasLength(2));

    final raw = report.stats.firstWhere((s) => s.scope == NirScope.rawMaterial);
    expect(raw.entityName, 'Cement');
    expect(raw.parameter, 'Protein');
    expect(raw.unit, '%');
    expect(raw.count, 1);
    expect(raw.points.single.nirValue, 12.5);
    expect(raw.points.single.labValue, 12.9);
    expect(raw.bias, closeTo(-0.4, 1e-9));
    expect(raw.reliability, NirReliability.insufficientData);

    final product =
        report.stats.firstWhere((s) => s.scope == NirScope.product);
    expect(product.entityName, 'Flour 50T');
    expect(product.count, 1);
    expect(product.points.single.nirValue, 13.1);
    expect(product.points.single.labValue, 13.5);
  });

  test('the horizon excludes المحاضر before the reset date', () async {
    await seedRawInspection();
    await seedRawLabTest();
    await seedBatch();

    final settings =
        await repo.resetValidation('2026-01-02', note: 'بعد تحسين الجهاز');
    expect(settings.startDate, '2026-01-02');

    final report = await repo.compute();
    // raw 2026-01-01 excluded, product 2026-01-03 included.
    expect(report.stats.where((s) => s.scope == NirScope.rawMaterial), isEmpty);
    expect(
      report.stats.where((s) => s.scope == NirScope.product),
      hasLength(1),
    );
    expect(report.settings?.startDate, '2026-01-02');

    final history = await repo.listResetHistory();
    expect(history.map((r) => r.startDate), ['2026-01-02']);
    final resetNote = history.single.resetNote;
    expect(resetNote, 'بعد تحسين الجهاز');
  });

  test('each reset is queued as a synced labConfig document', () async {
    await repo.resetValidation('2026-01-01');
    await repo.resetValidation('2026-01-15');
    final queued = await fx.db.query(
      'sync_queue',
      where: 'entity_type = ?',
      whereArgs: ['nirValidationSettings'],
    );
    expect(queued, hasLength(2));
    for (final q in queued) {
      expect('${q['entity_id']}', startsWith('lc_nir_validation_settings_'));
      expect('${q['operation']}', 'create');
    }
    expect(await repo.getSettings(), isNotNull);
    final next = await repo.getSettings();
    expect(next!.startDate, '2026-01-15');
  });

  test('an invalid reset date is rejected without writing', () async {
    await seedRawInspection();
    await seedRawLabTest();
    expect(
      () => repo.resetValidation('not-a-date'),
      throwsA(isA<Object>()),
    );
    final rows = await fx.db.query(
      'nir_validation_settings',
    );
    expect(rows, isEmpty);
    final report = await repo.compute();
    // No horizon → every recorded pair participates.
    expect(report.stats, hasLength(1));
  });

  // ── Per-item horizon (تصفير بند واحد) ────────────────────────────────

  Future<int> addParameterAndAnalysis(String name, String unit) async {
    final parameterId = await fx.db.rawInsert(
      "INSERT INTO parameters (parameter_name, unit, imported_at) "
      "VALUES (?, ?, '2026-01-01 00:00:00')",
      [name, unit],
    );
    return fx.db.rawInsert(
      "INSERT INTO lab_analyses (name, unit, parameter_id, created_at) "
      "VALUES (?, ?, ?, 'x')",
      [name, unit, parameterId],
    );
  }

  Future<void> seedRawEntry({
    required String entryCode,
    required String date,
    required Map<String, String> values,
  }) async {
    await fx.db.rawInsert(
      'INSERT INTO inspections (entry_code, material_id, material_name, '
      'material_code, inspection_date, specialist_name, '
      'physical_results_json, chemical_results_json, '
      'physical_reference_json, chemical_reference_json, decision_status, '
      'snapshot_json, sample_names_json, decision_version, created_by, '
      'created_by_name, created_at, updated_at, inspection_kind, quantity) '
      "VALUES (?, 1, 'Cement', 'M-CEM-01', ?, 'QC', '{}', ?, '{}', '{}', "
      "'APPROVED', '{}', '[]', 1, 1, 'Ahmed Ali', 'x', 'x', 'raw', '10 tons')",
      [entryCode, date, jsonEncode(values)],
    );
  }

  Future<void> seedRawTest({
    required int analysis,
    required String entryCode,
    required String date,
    required String value,
  }) async {
    await fx.db.rawInsert(
      'INSERT INTO lab_sample_tests (analysis_id, source_type, source_ref_id, '
      'source_name, sample_name, result_text, dynamic_values_json, '
      'entry_code, tested_by, tested_at) '
      "VALUES (?, 'raw_material', 1, 'Cement', '', ?, '{}', ?, 1, ?)",
      [analysis, value, entryCode, '$date 09:00:00'],
    );
  }

  Future<void> seedTwoItemsTwoDates() async {
    final moistureId = await addParameterAndAnalysis('Moisture', '%');
    await seedRawEntry(
      entryCode: 'RAW-001',
      date: '2026-01-01',
      values: {'Protein': '12.5', 'Moisture': '8.0'},
    );
    await seedRawEntry(
      entryCode: 'RAW-002',
      date: '2026-01-10',
      values: {'Protein': '13.0', 'Moisture': '8.5'},
    );
    await seedRawTest(
      analysis: analysisId,
      entryCode: 'RAW-001',
      date: '2026-01-01',
      value: '12.9',
    );
    await seedRawTest(
      analysis: moistureId,
      entryCode: 'RAW-001',
      date: '2026-01-01',
      value: '8.2',
    );
    await seedRawTest(
      analysis: analysisId,
      entryCode: 'RAW-002',
      date: '2026-01-10',
      value: '13.2',
    );
    await seedRawTest(
      analysis: moistureId,
      entryCode: 'RAW-002',
      date: '2026-01-10',
      value: '8.6',
    );
  }

  test('a per-item reset restarts only that خامة × parameter', () async {
    await seedTwoItemsTwoDates();

    final reset = await repo.resetValidation(
      '2026-01-10',
      note: 'انتهى البروتين',
      scope: NirScope.rawMaterial,
      entityId: 1,
      entityName: 'Cement',
      parameter: 'Protein',
    );
    expect(reset.scope, 'raw_material');
    expect(reset.parameter, 'Protein');
    expect(reset.isGlobal, isFalse);
    // A scoped reset is not a global zero point.
    expect(await repo.getSettings(), isNull);

    final report = await repo.compute();
    final protein = report.stats.firstWhere((s) => s.parameter == 'Protein');
    final moisture = report.stats.firstWhere((s) => s.parameter == 'Moisture');

    expect(protein.count, 1);
    expect(protein.points.single.inspectionDate, '2026-01-10');
    expect(protein.scopedHorizon, isTrue);
    expect(protein.horizonStart, '2026-01-10');

    // The untouched item keeps all its history.
    expect(moisture.count, 2);
    expect(moisture.scopedHorizon, isFalse);
    expect(moisture.horizonStart, '');

    final history = await repo.listResetHistory();
    expect(history.single.parameter, 'Protein');
    expect(history.single.isGlobal, isFalse);
  });

  test('a global reset never overrides a newer per-item horizon', () async {
    await seedTwoItemsTwoDates();

    await repo.resetValidation(
      '2026-01-10',
      scope: NirScope.rawMaterial,
      entityId: 1,
      entityName: 'Cement',
      parameter: 'Protein',
    );
    final global = await repo.resetValidation('2026-01-05');
    expect(global.isGlobal, isTrue);

    final report = await repo.compute();
    final protein = report.stats.firstWhere((s) => s.parameter == 'Protein');
    final moisture = report.stats.firstWhere((s) => s.parameter == 'Moisture');

    // Protein still uses its own (newer) horizon…
    expect(protein.horizonStart, '2026-01-10');
    expect(protein.count, 1);
    // …while every other item falls back to the global one.
    expect(moisture.horizonStart, '2026-01-05');
    expect(moisture.count, 1);
    expect(moisture.points.single.inspectionDate, '2026-01-10');
    expect(report.settings?.startDate, '2026-01-05');
  });

  test('a scoped reset without a parameter is rejected', () async {
    expect(
      () => repo.resetValidation(
        '2026-01-10',
        scope: NirScope.rawMaterial,
        entityId: 1,
        entityName: 'Cement',
      ),
      throwsA(isA<Object>()),
    );
    expect(await fx.db.query('nir_validation_settings'), isEmpty);
  });
}
