import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/core/sync/audit_logger.dart';
import 'package:material_lab/core/sync/sync_queue.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/features/lab/data/offline_first_lab_repository.dart';
import 'package:material_lab/features/organizations/data/member_write_guard.dart';

import '../sync/sync_test_fixture.dart';

/// Reference-driven material analyses: every physical/chemical field in a
/// material's reference JSON becomes a canonical parameter (the origin of the
/// NAME), the material inherits that name and keeps its OWN acceptance/rejection
/// limits in `material_parameter_bounds`, and each name is linked to a
/// `lab_analyses` recipe. Reads resolve everything in a single query (no N+1).
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

  Future<void> seedCement() async {
    await fixture.db.insert('reference_materials', <String, dynamic>{
      'id': 10,
      'material_name': 'Cement',
      'material_code': 'CEM',
      'physical_reference_json':
          '{"Fineness":"3-8","Color":"Normal"}',
      'chemical_reference_json':
          '{"SiO2":"20-24","LOI":{"value":"min 2","unit":"%"}}',
      'imported_at': nowIso(),
      'active': 1,
    });
  }

  Future<void> seedSugar() async {
    await fixture.db.insert('reference_materials', <String, dynamic>{
      'id': 20,
      'material_name': 'Sugar',
      'material_code': 'SUG',
      'physical_reference_json':
          '{"Granulation":"fine","Moisture":"5-7"}',
      'chemical_reference_json':
          '{"Purity":"min 98","Moisture":"max 0.5"}',
      'imported_at': nowIso(),
      'active': 1,
    });
  }

  group('syncReferenceAnalyses', () {
    test('derives canonical parameters, bounds and linked analyses', () async {
      await seedCement();
      await seedSugar();
      // Pre-seeded recipe (like the defaultAnalyses "Moisture"): it must be
      // LINKED to the canonical parameter, not duplicated.
      await fixture.db.insert('lab_analyses', <String, dynamic>{
        'name': 'Moisture',
        'unit': '%',
        'created_at': nowIso(),
      });

      final result = await repo.syncReferenceAnalyses();

      // Unique canonical names: Fineness, Color, SiO2, LOI, Granulation,
      // Moisture, Purity.
      expect(result['parameters'], 7);
      // Bounds rows: 4 for Cement + 3 for Sugar (Moisture is one canonical
      // parameter → one bounds row per material).
      expect(result['bounds'], 7);
      // Moisture already existed; every other name gets a recipe.
      expect(result['analyses'], 6);
      expect(result['linked'], 1);

      final params = await fixture.db
          .query('parameters', orderBy: 'parameter_name COLLATE NOCASE');
      final byName = {for (final p in params) '${p['parameter_name']}': p};
      expect(byName.containsKey('Fineness'), isTrue);
      expect(byName['Fineness']!['parameter_type'], 'physical');
      expect(byName.containsKey('SiO2'), isTrue);
      expect(byName['SiO2']!['parameter_type'], 'chemical');

      final bounds =
          await fixture.db.query('material_parameter_bounds', orderBy: 'id');
      Map<String, Map<String, dynamic>> forMat10 = {};
      for (final b in bounds) {
        if ('${b['material_id']}' == '10') {
          final pid = '${b['parameter_id']}';
          forMat10[pid] = Map<String, dynamic>.from(b);
        }
      }
      // Cement: Fineness 3-8, Color (qualitative), SiO2 20-24, LOI min 2.
      final finenessPid =
          byName['Fineness']?['id']?.toString();
      expect(forMat10[finenessPid]?['min_value'], 3);
      expect(forMat10[finenessPid]?['max_value'], 8);
      final loiPid = byName['LOI']?['id']?.toString();
      expect(forMat10[loiPid]?['min_value'], 2);
      expect(forMat10[loiPid]?['max_value'], isNull);

      // Recipes: created names carry their parameter link; "Moisture" was
      // linked to the canonical parameter without taking a new row.
      final analyses =
          await fixture.db.query('lab_analyses', orderBy: 'name COLLATE NOCASE');
      final analysisByName = {
        for (final a in analyses) '${a['name']}': Map<String, dynamic>.from(a),
      };
      expect(analysisByName, hasLength(7));
      expect(analysisByName['Fineness']!['parameter_id'], byName['Fineness']?['id']);
      expect(analysisByName['Moisture']!['parameter_id'], byName['Moisture']?['id']);
    });

    test('is idempotent and never overwrites user-edited limits', () async {
      await seedCement();
      await seedSugar();
      await repo.syncReferenceAnalyses();

      // User tightens a limit through the documented write path.
      await repo.saveMaterialBounds(10, [
        {
          'parameter_name': 'SiO2',
          'parameter_type': 'chemical',
          'unit': '%',
          'min_value': 21,
          'max_value': 23,
        },
      ]);

      final second = await repo.syncReferenceAnalyses();
      expect(second['parameters'], 0);
      expect(second['bounds'], 0);
      expect(second['analyses'], 0);
      expect(second['linked'], 0);

      final params =
          await fixture.db.query('parameters', where: 'parameter_name = ?', whereArgs: ['SiO2']);
      final bounds = await fixture.db.query('material_parameter_bounds',
          where: 'material_id = ? AND parameter_id = ?',
          whereArgs: [10, params.single['id']]);
      expect(bounds.single['min_value'], 21);
      expect(bounds.single['max_value'], 23);
    });
  });

  group('resolver (single-query, no N+1)', () {
    test('getMaterialAnalyses groups physical/chemical with limits', () async {
      await seedCement();
      await seedSugar();
      await repo.syncReferenceAnalyses();

      final cement = await repo.getMaterialAnalyses(10);
      final physical =
          (cement['physical']?['fields'] as List).cast<Map<String, dynamic>>();
      final chemical =
          (cement['chemical']?['fields'] as List).cast<Map<String, dynamic>>();

      expect(cement['material_id'], 10);
      expect(cement['material_name'], 'Cement');
      expect(physical.map((f) => f['parameter_name']), containsAll(['Fineness', 'Color']));
      expect(chemical.map((f) => f['parameter_name']), containsAll(['SiO2', 'LOI']));

      final fineness = physical.firstWhere((f) => f['parameter_name'] == 'Fineness');
      expect(fineness['min'], 3);
      expect(fineness['max'], 8);
      expect(fineness['unit'], '');
      final sio2 = chemical.firstWhere((f) => f['parameter_name'] == 'SiO2');
      expect(sio2['min'], 20);
      expect(sio2['max'], 24);
      final color = physical.firstWhere((f) => f['parameter_name'] == 'Color');
      expect(color['min'], isNull);
      expect(color['max'], isNull);

      final missing = await repo.getMaterialAnalyses(999);
      expect(missing['material_id'], 999);
      expect(missing['physical']?['fields'], isEmpty);
      expect(missing['chemical']?['fields'], isEmpty);
    });

    test('listMaterialsAnalyses returns every material at once', () async {
      await seedCement();
      await seedSugar();
      await repo.syncReferenceAnalyses();

      final all = await repo.listMaterialsAnalyses();
      expect(all.keys, containsAll([10, 20]));
      final sugar = all[20]!;
      expect((sugar['physical']?['fields'] as List).length, 2);
      expect((sugar['chemical']?['fields'] as List).length, 1);
    });
  });

  group('saveMaterialBounds', () {
    test('creates the parameter origin, the bounds row and the linked recipe',
        () async {
      await seedCement();
      final saved = await repo.saveMaterialBounds(10, [
        {
          'parameter_name': 'Sulfates',
          'parameter_type': 'chemical',
          'unit': '%',
          'min_value': '0',
          'max_value': '5',
          'precision': '2',
        },
      ]);
      expect(saved['saved'], 1);

      final params = await fixture.db.query('parameters',
          where: 'parameter_name = ?', whereArgs: ['Sulfates']);
      expect(params, hasLength(1));
      final pid = params.single['id'];

      final bounds = await fixture.db.query('material_parameter_bounds',
          where: 'material_id = ? AND parameter_id = ?',
          whereArgs: [10, pid]);
      expect(bounds, hasLength(1));
      expect(bounds.single['min_value'], 0);
      expect(bounds.single['max_value'], 5);
      expect(bounds.single['precision'], 2);
      expect(bounds.single['parameter_type'], 'chemical');

      final analyses = await fixture.db.query('lab_analyses',
          where: 'name = ?', whereArgs: ['Sulfates']);
      expect(analyses, hasLength(1));
      expect(analyses.single['parameter_id'], pid);

      // User edits the limit afterwards: the same spec shape updates in place.
      await repo.saveMaterialBounds(10, [
        {
          'parameter_name': 'Sulfates',
          'parameter_type': 'chemical',
          'unit': '%',
          'min_value': '1',
          'max_value': '4',
        },
      ]);
      final updated = await fixture.db.query('material_parameter_bounds',
          where: 'material_id = ? AND parameter_id = ?',
          whereArgs: [10, pid]);
      expect(updated.single['min_value'], 1);
      expect(updated.single['max_value'], 4);
    });
  });
}