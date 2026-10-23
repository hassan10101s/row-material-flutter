import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/features/lab/data/lab_repo.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// `dashboardSummary` runs on a projected lightweight query (no users /
/// inspections joins) whose tested_at cutoff is pushed down into SQL.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper dbHelper;
  late LabRepo repo;
  late Database db;

  String monthsAgoIso(int monthsBack) {
    final now = DateTime.now().toUtc();
    final d = DateTime.utc(now.year, now.month - monthsBack, 12);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-12T10:00:00Z';
  }

  Future<void> seedTest(
    int analysisId, {
    required String result,
    required String testedAt,
  }) async {
    await db.insert('lab_sample_tests', {
      'analysis_id': analysisId,
      'source_type': 'raw_material',
      'source_ref_id': 1,
      'source_name': 'Wheat',
      'sample_name': 'S1',
      'result_text': result,
      'tested_at': testedAt,
      'created_at': testedAt,
    });
  }

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_dashboard');
    dbHelper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await dbHelper.database;
    repo = LabRepo(dbHelper: dbHelper);

    await db.insert('reference_materials', {
      'material_name': 'Wheat',
      'material_code': 'WH-1',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': nowIso(),
    });
    final paramId = await db.insert('parameters', {
      'parameter_name': 'Purity-DBS',
      'unit': '%',
      'parameter_type': 'chemical',
      'imported_at': nowIso(),
    });
    final analysisId = await db.insert('lab_analyses', {
      'name': 'Purity-DBS',
      'unit': '%',
      'description': 'Assay',
      'reference': '',
      'parameter_id': paramId,
      'created_at': nowIso(),
      'active': 1,
    });
    await db.insert('material_parameter_bounds', {
      'material_id': 1,
      'parameter_id': paramId,
      'parameter_type': 'chemical',
      'unit': '%',
      'min_value': 0.0,
      'max_value': 100.0,
      'active': 1,
    });

    await seedTest(analysisId, result: '50', testedAt: nowIso());
    await seedTest(analysisId, result: '150', testedAt: nowIso());
    await seedTest(
      analysisId,
      result: '120',
      testedAt: monthsAgoIso(2),
    );
    await seedTest(
      analysisId,
      result: '90',
      testedAt: monthsAgoIso(2),
    );
    // No bounds for this analysis -> range_state 'none', never judged.
    final unbounded = await db.insert('lab_analyses', {
      'name': 'Unbounded-DBS',
      'unit': '%',
      'description': 'No bounds',
      'reference': '',
      'created_at': nowIso(),
      'active': 1,
    });
    await seedTest(unbounded, result: '3', testedAt: nowIso());
  });

  tearDownAll(() async {
    await dbHelper.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('period all counts judged vs none and fills monthly buckets', () async {
    final summary = await repo.dashboardSummary(period: 'all');
    final kpis = summary['kpis'] as Map;

    expect(kpis['total_tests'], 5);
    expect(kpis['in_range'], 2); // '50' and '90'
    expect(kpis['out_of_range'], 2); // '150', '120'
    expect(kpis['tests_evaluated'], 4);
    expect(kpis['pass_rate'], 50.0);
    expect(kpis['low_stock_count'], 0);

    final trend = summary['monthly_trend'] as List;
    final current = trend.last as Map;
    expect(current['total'], 3);
    expect(current['in_range'], 1);
    expect(current['out_of_range'], 1);
    expect(current['in_range_pct'], 50.0);
  });

  test('period window excludes tests older than the cutoff', () async {
    final summary = await repo.dashboardSummary(period: '30d');
    final kpis = summary['kpis'] as Map;

    expect(kpis['total_tests'], 3);
    expect(kpis['tests_evaluated'], 2);
    expect(kpis['in_range'], 1);
    expect(kpis['out_of_range'], 1);
    expect(kpis['pass_rate'], 50.0);

    final summaryAll = await repo.dashboardSummary();
    expect((summaryAll['kpis'] as Map)['total_tests'], 5);
  });
}
