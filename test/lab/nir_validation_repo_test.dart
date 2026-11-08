import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/auth/app_session.dart';
import 'package:material_lab/core/auth/permissions.dart';
import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/sync/entity_registry.dart';
import 'package:material_lab/core/utils/app_exceptions.dart';
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

  Future<void> admitPointSources() async {
    for (final table in [
      'inspections',
      'product_batch_samples',
      'lab_sample_tests',
    ]) {
      for (final row in await fx.db.query(table)) {
        await fx.db.update(
          table,
          {
            'remote_id': 'global-$table-${row['id']}',
            'version': 1,
            'remote_version': 1,
            'sync_state': 'synced',
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    }
  }

  test(
    'No persists without changing measurements; Yes restores the pair and stale writes fail',
    () async {
      await seedRawInspection();
      await seedRawLabTest();
      await admitPointSources();
      final original = (await fx.db.query('lab_sample_tests')).single;
      final point = (await repo.compute()).stats.single.points.single;
      await repo.setPointIncluded(point, false);
      final excluded = (await repo.compute()).stats.single;
      expect(excluded.count, 0);
      expect(excluded.allPoints, hasLength(1));
      expect(excluded.allPoints.single.included, isFalse);
      expect(excluded.excludedCount, 1);
      final row = (await fx.db.query('lab_sample_tests')).single;
      for (final field in [
        'result_text',
        'dynamic_values_json',
        'tested_at',
        'analysis_id',
        'entry_code',
      ]) {
        expect(row[field], original[field], reason: field);
      }
      final writes = await fx.db.query(
        'sync_queue',
        where: 'entity_type = ?',
        whereArgs: ['labResult'],
      );
      expect(writes, hasLength(1));
      expect(jsonDecode('${row['nir_exclusions_json']}'), [point.selectionKey]);
      await expectLater(
        repo.setPointIncluded(point, false),
        throwsA(isA<ValidationError>()),
      );
      await repo.setPointIncluded(excluded.allPoints.single, true);
      expect((await repo.compute()).stats.single.count, 1);
      expect(
        (await fx.db.query('lab_sample_tests')).single['nir_exclusions_json'],
        '[]',
      );
      expect(await fx.db.query('inventory_transactions'), isEmpty);
      expect(await fx.db.query('lab_consumption_log'), isEmpty);
    },
  );

  test(
    'No for one product pair never excludes other samples sharing a lab reference',
    () async {
      await seedBatch();
      final sample = (await fx.db.query('product_batch_samples')).single;
      await fx.db.insert('product_batch_samples', {
        ...Map<String, Object?>.from(sample)..remove('id'),
        'sample_no': 2,
        'sample_name': 'Sample 2',
      });
      await fx.db.update('lab_sample_tests', {'sample_name': ''});
      await admitPointSources();
      final before = (await repo.compute()).stats.single;
      expect(before.count, 2);
      await repo.setPointIncluded(before.points.first, false);
      final after = (await repo.compute()).stats.single;
      expect(after.count, 1);
      expect(after.points.single.sampleName, 'Sample 2');
      expect(after.allPoints, hasLength(2));
    },
  );

  test(
    'reset captures excluded reading identities without using them in calibration',
    () async {
      await seedRawInspection();
      await seedRawLabTest();
      await admitPointSources();
      final point = (await repo.compute()).stats.single.points.single;
      await repo.setPointIncluded(point, false);
      final reset = await repo.resetValidation('2026-02-01');
      final summary = reset.calibrationSnapshot!.summaries.single;
      expect(summary['count'], 0);
      expect(summary['excludedCount'], 1);
      expect(
        (summary['excludedReadings'] as List).single['selectionKey'],
        point.selectionKey,
      );
      expect(summary['slope'], isNull);
    },
  );

  test('read-only users cannot change the calibration selection', () async {
    await seedRawInspection();
    await seedRawLabTest();
    await admitPointSources();
    final point = (await repo.compute()).stats.single.points.single;
    final viewer = NirValidationRepo(
      dbHelper: fx.helper,
      guard: _LiveGuard(
        AppSession(
          uid: session.uid,
          organizationId: session.organizationId,
          role: AppRoles.viewer,
          status: 'active',
          deviceId: session.deviceId,
        ),
      ),
      queue: queue,
      audit: audit,
    );
    await expectLater(
      viewer.setPointIncluded(point, false),
      throwsA(isA<AuthorizationError>()),
    );
    expect((await repo.compute()).stats.single.count, 1);
    expect(await fx.db.query('sync_queue'), isEmpty);
  });

  test(
    'shared exclusion survives wire decoding and different inspection/result ids on another device',
    () async {
      await seedRawInspection();
      await seedRawLabTest();
      await admitPointSources();
      final original = (await repo.compute()).stats.single.points.single;
      await repo.setPointIncluded(original, false);
      final result = Map<String, dynamic>.from(
        (await fx.db.query('lab_sample_tests')).single,
      );
      final entity = SyncEntity.byType('labResult')!;
      final wire = buildRemotePayload(
        entity,
        result,
        SyncPayloadContext(
          organizationId: orgId,
          uid: session.uid,
          deviceId: session.deviceId,
          version: result['version'] as int,
          versionField: 'version',
        ),
        asCreate: false,
      );
      final decoded = remoteToLocalRow(entity, wire, organizationId: orgId);
      final other = await openSyncFixture();
      try {
        await other.seedOrganization();
        for (final table in ['parameters', 'lab_analyses']) {
          for (final row in await fx.db.query(table)) {
            await other.db.insert(table, row);
          }
        }
        final inspection = (await fx.db.query('inspections')).single;
        await other.db.insert('inspections', {...inspection, 'id': 401});
        await other.db.insert('lab_sample_tests', {
          ...result,
          'id': 902,
          'nir_exclusions_json': decoded['nir_exclusions_json'],
        });
        final otherQueue = SyncQueue(other.helper);
        final otherRepo = NirValidationRepo(
          dbHelper: other.helper,
          guard: _LiveGuard(session),
          queue: otherQueue,
          audit: AuditLogger(queue: otherQueue, session: () => session),
        );
        final stat = (await otherRepo.compute()).stats.single;
        expect(stat.count, 0);
        expect(stat.allPoints.single.inspectionId, 401);
        expect(stat.allPoints.single.referenceId, 902);
        expect(stat.allPoints.single.selectionKey, original.selectionKey);
        await otherRepo.setPointIncluded(stat.allPoints.single, true);
        expect((await otherRepo.compute()).stats.single.count, 1);
      } finally {
        await other.dispose();
      }
    },
  );

  test(
    'NIR keeps receipt codes distinct instead of normalizing them like parameters',
    () async {
      final id = await seedRawInspection();
      await seedRawLabTest();
      final original = Map<String, Object?>.from(
        (await fx.db.query(
          'inspections',
          where: 'id = ?',
          whereArgs: [id],
        )).single,
      )..remove('id');
      original['entry_code'] = 'raw-001';
      await fx.db.insert('inspections', original);
      final test = Map<String, Object?>.from(
        (await fx.db.query('lab_sample_tests')).single,
      )..remove('id');
      test['entry_code'] = 'raw-001';
      test['result_text'] = '25';
      test['tested_at'] = '2026-01-03';
      await fx.db.insert('lab_sample_tests', test);
      final points = (await repo.compute()).stats.single.points;
      expect(points, hasLength(2));
      expect(
        {for (final point in points) point.entryCode: point.labValue},
        {'RAW-001': 12.9, 'raw-001': 25},
      );
    },
  );

  for (final code in ['RAW -001', 'RAW%-001', ' RAW-001', 'RAW-001 ']) {
    test(
      'NIR cannot borrow a lab result from distinct receipt code $code',
      () async {
        await seedRawInspection();
        await seedRawLabTest();
        await fx.db.update('lab_sample_tests', {'entry_code': code});
        expect((await repo.compute()).stats, isEmpty);
      },
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

    final product = report.stats.firstWhere((s) => s.scope == NirScope.product);
    expect(product.entityName, 'Flour 50T');
    expect(product.count, 1);
    expect(product.points.single.nirValue, 13.1);
    expect(product.points.single.labValue, 13.5);
  });

  test(
    'failed lab attempts are excluded from raw and product NIR statistics',
    () async {
      await seedRawInspection();
      await seedRawLabTest();
      await seedBatch();
      await fx.db.update(
        'lab_sample_tests',
        {'result_text': 'FAILURE'},
        where: 'source_type = ?',
        whereArgs: ['raw_material'],
      );
      final mixed = await repo.compute();
      expect(mixed.stats, hasLength(1));
      expect(mixed.stats.single.scope, NirScope.product);
      expect(mixed.stats.single.count, 1);
      await fx.db.update('lab_sample_tests', {'result_text': 'FAILURE'});
      expect((await repo.compute()).stats, isEmpty);
    },
  );

  test('deleted lab results and batch samples are excluded from NIR', () async {
    await seedRawInspection();
    await seedRawLabTest();
    await seedBatch();
    await fx.db.update(
      'lab_sample_tests',
      {'deleted_at': '2026-11-03'},
      where: 'source_type = ?',
      whereArgs: ['raw_material'],
    );
    expect((await repo.compute()).stats.single.scope, NirScope.product);
    await fx.db.update('product_batch_samples', {'deleted_at': '2026-11-03'});
    expect((await repo.compute()).stats, isEmpty);
  });

  test('the horizon excludes المحاضر before the reset date', () async {
    await seedRawInspection();
    await seedRawLabTest();
    await seedBatch();

    final settings = await repo.resetValidation(
      '2026-01-02',
      note: 'بعد تحسين الجهاز',
    );
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
    expect(() => repo.resetValidation('not-a-date'), throwsA(isA<Object>()));
    final rows = await fx.db.query('nir_validation_settings');
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

  test(
    'reset freezes the previous cycle and the separately reported applied correction',
    () async {
      await seedRawInspection();
      await seedRawLabTest();
      final reset = await repo.resetValidation(
        '2026-02-01',
        note: 'Device adjustment checked',
        scope: NirScope.rawMaterial,
        entityId: 1,
        parameter: 'Protein',
        appliedCorrection: const NirAppliedCorrection(
          slope: 1.03,
          intercept: -0.2,
        ),
      );
      final summary = reset.calibrationSnapshot!.summaries.single;
      expect(summary['count'], 1);
      expect(summary['bias'], closeTo(-0.4, 1e-9));
      expect(
        summary['slope'],
        isNull,
        reason: 'one pair cannot estimate a full fitted line',
      );
      expect(reset.calibrationSnapshot!.appliedCorrection!.slope, 1.03);
      expect((await repo.compute()).stats, isEmpty);
      await fx.db.update('lab_sample_tests', {'result_text': '99'});
      final history = await repo.listResetHistory();
      expect(
        history.single.calibrationSnapshot!.summaries.single['bias'],
        summary['bias'],
      );
      expect(
        history.single.calibrationSnapshot!.appliedCorrection!.intercept,
        -0.2,
      );
      expect(history.single.resetNote, 'Device adjustment checked');
      await fx.db.delete('lab_sample_tests');
      expect(
        (await repo.listResetHistory())
            .single
            .calibrationSnapshot!
            .summaries
            .single['count'],
        1,
      );
    },
  );

  test(
    'empty and legacy cycles never invent historical metrics or applied adjustments',
    () async {
      final reset = await repo.resetValidation('2026-02-01');
      expect(reset.calibrationSnapshot!.summaries, isEmpty);
      expect(reset.calibrationSnapshot!.appliedCorrection, isNull);
      expect(
        NirValidationSettings.fromMap({
          'id': 999,
          'start_date': '2026-01-01',
        }).calibrationSnapshot,
        isNull,
      );
    },
  );

  test('calibration accepts complete decimal measurements only', () {
    for (final value in [
      '12,5',
      '12٫5',
      '١٢٫٥',
      '۱۲٫۵',
      '12.5 %',
      '12.5٪',
      '12.5 ppm',
      '1.25e1',
    ]) {
      expect(parseNumeric(value), 12.5, reason: value);
    }
    for (final value in [
      '<0.1',
      '>1',
      '≤2',
      '≥3',
      'invalid 42 text',
      '12kg5',
      '12.5.6',
      '1,234,5',
      '1e999',
      'NaN',
      'Infinity',
      'FAILURE',
      '',
    ]) {
      expect(parseNumeric(value), isNull, reason: value);
    }
    expect(parseNumeric(double.infinity), isNull);
    expect(parseNumeric(-0.5), -0.5);
    expect(parseNumeric('-.5'), -0.5);
  });

  test(
    'raw and product retests contribute one latest valid reference each',
    () async {
      await seedRawInspection();
      await seedRawLabTest();
      await seedBatch();
      final originals = await fx.db.query('lab_sample_tests');
      for (final original in originals) {
        for (final update in [
          ('2026-02-01', '14.5'),
          ('2026-02-02', 'FAILURE'),
          ('2026-02-03', '<0.1'),
          ('2026-02-04', '99'),
        ]) {
          final row = Map<String, Object?>.from(original)..remove('id');
          row.addAll({
            'tested_at': update.$1,
            'result_text': update.$2,
            'deleted_at': update.$2 == '99' ? '2026-02-05' : null,
          });
          await fx.db.insert('lab_sample_tests', row);
        }
      }
      final report = await repo.compute();
      expect(report.stats, hasLength(2));
      for (final stat in report.stats) {
        expect(stat.count, 1);
        expect(stat.points.single.labValue, 14.5);
      }
    },
  );

  test('distinct samples keep separate references after retesting', () async {
    await seedRawInspection();
    await seedRawLabTest();
    final original = (await fx.db.query('lab_sample_tests')).single;
    final other = Map<String, Object?>.from(original)..remove('id');
    other.addAll({
      'sample_name': 'Sample B',
      'result_text': '15',
      'tested_at': '2026-02-01',
    });
    await fx.db.insert('lab_sample_tests', other);
    expect((await repo.compute()).stats.single.count, 2);
  });

  test('foreign legacy numeric ids never reset a different material', () async {
    await seedRawInspection();
    await seedRawLabTest();
    await fx.db.insert('nir_validation_settings', {
      'scope': 'raw_material',
      'entity_id': 1,
      'entity_name': 'Soybeans',
      'parameter': 'Protein',
      'start_date': '2026-02-01',
      'created_at': '2026-02-01',
      'updated_at': '2026-02-01',
    });
    final stat = (await repo.compute()).stats.single;
    expect(stat.count, 1);
    expect(stat.scopedHorizon, isFalse);
  });

  test(
    'legacy names work only for a unique current catalogue target',
    () async {
      await seedRawInspection();
      await seedRawLabTest();
      await fx.db.insert('nir_validation_settings', {
        'scope': 'raw_material',
        'entity_id': 999,
        'entity_name': 'Cement',
        'parameter': 'Protein',
        'start_date': '2026-02-01',
        'created_at': '2026-02-01',
        'updated_at': '2026-02-01',
      });
      expect((await repo.compute()).stats, isEmpty);
    },
  );

  test(
    'new reset uses typed identity across renames and ignores origin id',
    () async {
      await seedRawInspection();
      await seedRawLabTest();
      final reset = await repo.resetValidation(
        '2026-02-01',
        scope: NirScope.rawMaterial,
        entityId: 1,
        entityName: 'wrong display name',
        parameter: 'Protein',
      );
      expect(reset.materialId, 1);
      expect(reset.productId, isNull);
      expect(reset.referenceVersion, 1);
      expect(reset.entityName, 'Cement');
      await fx.db.update('nir_validation_settings', {
        'entity_id': 999,
        'entity_name': 'Old name',
      });
      await fx.db.update('reference_materials', {
        'material_name': 'Renamed Cement',
      }, where: 'id = 1');
      expect((await repo.compute()).stats, isEmpty);
    },
  );

  test('reset chronology survives reversed local ids and tombstones', () async {
    for (final row in [
      {'id': 10, 'created_at': '2026-01-01', 'start_date': '2026-01-01'},
      {'id': 2, 'created_at': '2026-02-01', 'start_date': '2026-02-01'},
      {
        'id': 20,
        'created_at': '2026-03-01',
        'start_date': '2026-03-01',
        'deleted_at': '2026-03-02',
      },
    ]) {
      await fx.db.insert('nir_validation_settings', {
        ...row,
        'updated_at': row['created_at'],
      });
    }
    expect((await repo.getSettings())!.startDate, '2026-02-01');
    expect((await repo.listResetHistory()).map((r) => r.id), [2, 10]);
  });

  test(
    'scoped reset rejects missing and deleted targets without side effects',
    () async {
      for (final id in [null, -1, 999]) {
        await expectLater(
          repo.resetValidation(
            '2026-02-01',
            scope: NirScope.rawMaterial,
            entityId: id,
            parameter: 'Protein',
          ),
          throwsA(isA<Object>()),
        );
      }
      await fx.db.update('reference_materials', {
        'deleted_at': '2026-01-01',
      }, where: 'id = 1');
      await expectLater(
        repo.resetValidation(
          '2026-02-01',
          scope: NirScope.rawMaterial,
          entityId: 1,
          parameter: 'Protein',
        ),
        throwsA(isA<Object>()),
      );
      expect(await fx.db.query('nir_validation_settings'), isEmpty);
      expect(await fx.db.query('sync_queue'), isEmpty);
    },
  );
}
