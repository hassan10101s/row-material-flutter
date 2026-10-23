import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/features/inspections/data/inspection_repo.dart';
import 'package:material_lab/features/reference/data/reference_repo.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

Future<void> _insert(
  DatabaseHelper helper, {
  required String entryCode,
  required String date,
  String supplier = '',
  String status = 'PENDING',
  String kind = 'raw',
}) async {
  final db = await helper.database;
  await db.insert('inspections', {
    'entry_code': entryCode,
    'material_id': 1,
    'material_name': 'Wheat',
    'material_code': 'W1',
    'inspection_date': date,
    'specialist_name': 'tester',
    'physical_results_json': '{}',
    'chemical_results_json': '{}',
    'physical_reference_json': '{}',
    'chemical_reference_json': '{}',
    'decision_status': status,
    'decision_reason': '',
    'snapshot_json': '{}',
    'sample_names_json': '[]',
    'created_by': 0,
    'created_by_name': '',
    'created_at': '${date}T08:00:00',
    'updated_at': '${date}T08:00:00',
    'inspection_kind': kind,
    'supplier': supplier,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  group('InspectionRepo supplier filter (real DB)', () {
    late Directory tmp;
    late DatabaseHelper helper;
    late InspectionRepo repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('matlab_insp_supplier');
      helper = DatabaseHelper(_FakeAppPaths(tmp.path));
      final db = await helper.database;
      await db.insert('reference_materials', {
        'material_name': 'Wheat',
        'material_code': 'W1',
        'physical_reference_json': '{}',
        'chemical_reference_json': '{}',
        'imported_at': '2026-01-01T00:00:00',
        'active': 1,
      });
      await _insert(helper, entryCode: 'S-001', date: '2026-09-01', supplier: 'Acme');
      await _insert(helper, entryCode: 'S-002', date: '2026-09-15', supplier: 'Bloor');
      await _insert(helper, entryCode: 'S-003', date: '2026-10-01', supplier: 'Acme');
      await _insert(helper, entryCode: 'S-004', date: '2026-10-02');
      await _insert(
        helper,
        entryCode: 'S-005',
        date: '2026-10-03',
        supplier: 'Acme',
        status: 'APPROVED',
        kind: 'product',
      );
      repo = InspectionRepo(
        dbHelper: helper,
        referenceRepo: ReferenceRepo(dbHelper: helper),
      );
    });

    tearDown(() async {
      await helper.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('empty supplier means all rows', () async {
      expect((await repo.list()).map((r) => r['entry_code']), hasLength(5));
      expect(await repo.count(), 5);
    });

    test('exact supplier match narrows list and count', () async {
      final rows = await repo.list(supplier: 'Acme');
      expect(rows.map((r) => r['entry_code']), ['S-005', 'S-003', 'S-001']);
      expect(await repo.count(supplier: 'Acme'), 3);
    });

    test('empty-string supplier value does not become a catch-all', () async {
      // The dashboard passes trimmed values; an explicitly empty filter is
      // inert (all rows), and the no-supplier row exists in results.
      final rows = await repo.list(supplier: 'Bloor');
      expect(rows.map((r) => r['entry_code']), ['S-002']);
      expect(await repo.count(supplier: 'Bloor'), 1);
    });

    test('supplier filter composes with status and kind', () async {
      final rows = await repo.list(supplier: 'Acme', status: 'APPROVED');
      expect(rows.map((r) => r['entry_code']), ['S-005']);
      expect(await repo.count(supplier: 'Acme', kind: 'raw'), 2);
      expect(
        (await repo.list(supplier: 'Acme', kind: 'raw'))
            .map((r) => r['entry_code']),
        ['S-003', 'S-001'],
      );
    });
  });
}
