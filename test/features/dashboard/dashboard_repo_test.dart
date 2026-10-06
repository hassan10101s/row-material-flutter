import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart' show Database;

import 'package:material_lab/core/app_paths.dart';
import 'package:material_lab/core/database/database_helper.dart';
import 'package:material_lab/core/utils/app_dates.dart';
import 'package:material_lab/features/dashboard/data/dashboard_repo.dart';

class _FakeAppPaths extends AppPaths {
  _FakeAppPaths(this.base);
  final String base;

  @override
  Future<Directory> appSupportRoot() async => Directory('$base/MaterialLab');
}

/// Dashboard analytics are built in Dart on top of raw `inspections` rows, and
/// every number on the landing screen comes out of this one class. The bug class
/// pinned here is the **silent wrong aggregate**: no read in this repo ever
/// throws on an unexpected row, so a legacy/unknown decision code, an
/// unparseable filter value or an empty table all have to be pinned *as
/// observed behaviour* — otherwise a refactor that "helpfully" changes the
/// denominator ships a plausible-looking but wrong approval rate to a QA
/// department.
///
/// Rules pinned, in order of blast radius:
///   * every canonical `decisionCodes` bucket is filled and nothing is
///     double-counted;
///   * the legacy codes `CONDITIONAL`/`PARTIAL` are folded onto
///     `CONDITIONAL_APPROVAL`/`PARTIAL_REJECTION` on the way *in* — but the
///     status **filter** normalises the query value while leaving stored legacy
///     rows alone, so `status=CONDITIONAL` silently returns nothing;
///   * an empty table yields `'0.0'` rates (never `NaN`, never a divide-by-zero);
///   * an unparseable `materialId` coerces to `-1` and matches nothing rather
///     than raising, so a bad filter looks like "no data".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  DatabaseHelper.ensureDesktopFactory();

  late Directory tmp;
  late DatabaseHelper helper;
  late Database db;
  late DashboardRepo repo;

  /// `yyyy-mm` for the month [months] away from the current one.
  String monthOffset(int months) {
    final now = DateTime.now();
    final d = DateTime(now.year, now.month + months, 1);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}';
  }

  /// A date guaranteed to fall inside the *current* calendar month, whatever
  /// day of the month the suite happens to run on. Used wherever a test asserts
  /// on `monthlyTrend[last]`.
  String thisMonth() => '${monthOffset(0)}-01';

  String dayOffset(int days) {
    final d = DateTime.now().subtract(Duration(days: days));
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  Future<int> addMaterial(String name, {String? code, int active = 1}) async {
    return db.insert('reference_materials', <String, dynamic>{
      'material_name': name,
      'material_code': code ?? 'M-$name',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'imported_at': nowIso(),
      'active': active,
    });
  }

  /// Inserts one inspection. `created_by: 0` is the reserved "Unknown user" row
  /// `_ensureUnknownUserRow` creates — the same value a row pulled from another
  /// device carries — so no roster fixture is needed.
  Future<void> addInspection({
    required String entryCode,
    required int materialId,
    required String materialName,
    required String date,
    required String status,
    String? supplier = 'Acme',
  }) async {
    await db.insert('inspections', <String, dynamic>{
      'entry_code': entryCode,
      'material_id': materialId,
      'material_name': materialName,
      'material_code': 'M-$materialName',
      'inspection_date': date,
      'supplier': supplier,
      'truck_number': 'T-1',
      'quantity': '10',
      'specialist_name': 'Tester',
      'physical_results_json': '{}',
      'chemical_results_json': '{}',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'decision_status': status,
      'snapshot_json': '{}',
      'sample_names_json': '[]',
      'decision_version': 1,
      'created_by': 0,
      'created_by_name': 'Unknown user',
      'created_at': '$date 08:00:00',
      'updated_at': '$date 08:00:00',
    });
  }

  /// A raw insert that bypasses [addInspection], for the malformed-row cases
  /// that must be written exactly as a legacy/importer would leave them.
  Future<void> addRawInspection(Map<String, dynamic> row) async {
    await db.insert('inspections', <String, dynamic>{
      'material_code': 'M-RAW',
      'specialist_name': 'Tester',
      'physical_results_json': '{}',
      'chemical_results_json': '{}',
      'physical_reference_json': '{}',
      'chemical_reference_json': '{}',
      'decision_status': 'APPROVED',
      'snapshot_json': '{}',
      'sample_names_json': '[]',
      'decision_version': 1,
      'created_by': 0,
      'created_by_name': 'Unknown user',
      'created_at': nowIso(),
      'updated_at': nowIso(),
      ...row,
    });
  }

  /// Two materials with a known 5-row status mix: Cement = 2 approved,
  /// 1 conditional, 1 partial rejection; Sugar = 1 full rejection.
  Future<void> seedCementSugar() async {
    final cement = await addMaterial('Cement');
    final sugar = await addMaterial('Sugar');
    await addInspection(
        entryCode: 'C-1',
        materialId: cement,
        materialName: 'Cement',
        date: dayOffset(1),
        status: 'APPROVED');
    await addInspection(
        entryCode: 'C-2',
        materialId: cement,
        materialName: 'Cement',
        date: dayOffset(2),
        status: 'APPROVED');
    await addInspection(
        entryCode: 'C-3',
        materialId: cement,
        materialName: 'Cement',
        date: dayOffset(3),
        status: 'CONDITIONAL_APPROVAL');
    await addInspection(
        entryCode: 'C-4',
        materialId: cement,
        materialName: 'Cement',
        date: dayOffset(4),
        status: 'PARTIAL_REJECTION');
    await addInspection(
        entryCode: 'S-1',
        materialId: sugar,
        materialName: 'Sugar',
        date: dayOffset(5),
        status: 'FULL_REJECTION',
        supplier: 'Globex');
  }

  Map<String, dynamic> totalsOf(Map<String, dynamic> summary) =>
      summary['totals'] as Map<String, dynamic>;

  int trendTotal(List<dynamic> trend) =>
      trend.fold<int>(0, (sum, b) => sum + (b['total'] as int));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('matlab_dashboard');
    helper = DatabaseHelper(_FakeAppPaths(tmp.path));
    db = await helper.database;
    repo = DashboardRepo(dbHelper: helper);
  });

  tearDown(() async {
    await helper.close();
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('summary() — decision-count aggregation', () {
    test('an empty table yields 0.0 rates, never NaN and never a divide-by-zero',
        () async {
      // The dashboard is the landing route and renders before any inspection
      // exists. `approved / total` with total == 0 is the classic crash and
      // `(0/0*100).toStringAsFixed(1)` is the classic silent "NaN%" tile.
      final s = await repo.summary(period: 'all');
      final totals = totalsOf(s);

      expect(totals['total'], 0);
      expect(totals['approvalRate'], '0.0');
      expect(totals['rejectionRate'], '0.0');
      expect('${totals['approvalRate']}', isNot(contains('NaN')));
      expect('${totals['rejectionRate']}', isNot(contains('NaN')));
      expect(s['filtered_count'], 0);
      expect(s['latest'], {'label': 'لا يوجد', 'date': ''});
      expect(s['insightCards'], isEmpty);
      expect(s['recommendations'], isEmpty,
          reason: 'no rows means no advice, not a generic congratulation');
    });

    test('every canonical decision code lands in its own bucket', () async {
      await seedCementSugar();
      final totals = totalsOf(await repo.summary(period: 'all'));

      expect(totals['total'], 5);
      expect(totals['approved'], 2);
      expect(totals['conditional'], 1);
      expect(totals['partial'], 1);
      expect(totals['rejected'], 1);
      // The buckets must partition the rows: nothing counted twice, nothing lost.
      expect(
        (totals['approved'] as int) +
            (totals['conditional'] as int) +
            (totals['partial'] as int) +
            (totals['rejected'] as int),
        totals['total'],
      );
    });

    test('approvalRate counts APPROVED only — conditional is NOT approved',
        () async {
      await seedCementSugar();
      final totals = totalsOf(await repo.summary(period: 'all'));

      // 2 approved of 5 = 40.0%. Folding conditional in (the way todayKpis does)
      // would read 60.0%.
      expect(totals['approvalRate'], '40.0');
    });

    test('rejectionRate folds PARTIAL and FULL rejections together', () async {
      await seedCementSugar();
      final totals = totalsOf(await repo.summary(period: 'all'));

      // (1 partial + 1 full) / 5 = 40.0%
      expect(totals['rejectionRate'], '40.0');
    });

    test('legacy CONDITIONAL/PARTIAL codes are normalised onto canonical ones',
        () async {
      // Rows written by the Python build keep `CONDITIONAL` / `PARTIAL`, which
      // are NOT in `decisionCodes`. Without `_normalizeStatus` they would land in
      // no bucket at all and the whole card would read zero.
      final m = await addMaterial('Wheat');
      await addInspection(
          entryCode: 'L-1',
          materialId: m,
          materialName: 'Wheat',
          date: dayOffset(1),
          status: 'CONDITIONAL');
      await addInspection(
          entryCode: 'L-2',
          materialId: m,
          materialName: 'Wheat',
          date: dayOffset(1),
          status: 'PARTIAL');

      final totals = totalsOf(await repo.summary(period: 'all'));
      expect(totals['conditional'], 1);
      expect(totals['partial'], 1);
      expect(totals['approved'], 0);
      expect(totals['rejectionRate'], '50.0',
          reason: 'a legacy PARTIAL must still surface as a rejection');
    });

    test('an unknown decision code stays in the denominator but in no bucket',
        () async {
      // `pull_worker.dart:345` writes `decision_status: 'PENDING'` when the
      // remote row carries no decision, and 'PENDING' is not in `decisionCodes`.
      // The row is counted in `total` and in no bucket, so it silently drags the
      // approval rate down: 1 approved of 2 rows = 50.0%, not 100.0%.
      final m = await addMaterial('Rice');
      await addInspection(
          entryCode: 'U-1',
          materialId: m,
          materialName: 'Rice',
          date: dayOffset(1),
          status: 'APPROVED');
      await addInspection(
          entryCode: 'U-2',
          materialId: m,
          materialName: 'Rice',
          date: dayOffset(1),
          status: 'PENDING');

      final totals = totalsOf(await repo.summary(period: 'all'));
      expect(totals['total'], 2);
      expect(totals['approved'], 1);
      expect(totals['conditional'], 0);
      expect(totals['partial'], 0);
      expect(totals['rejected'], 0);
      expect(totals['approvalRate'], '50.0');
    });
  });

  group('summary() — filters', () {
    test('materialId restricts the aggregation to that material only', () async {
      await seedCementSugar();
      final cement = await db
          .query('reference_materials',
              where: 'material_name = ?', whereArgs: ['Cement']);

      final s = await repo.summary(
          period: 'all', materialId: '${cement.first['id']}');
      expect(s['filtered_count'], 4, reason: 'Cement has 4 rows, Sugar 1');
      final totals = totalsOf(s);
      expect(totals['approved'], 2);
      expect(totals['rejected'], 0, reason: 'Sugar owns the only full rejection');
      expect((s['topMaterials'] as List).map((m) => m['name']), ['Cement']);
    });

    test('materialId ALL or empty is a no-op, not a filter', () async {
      await seedCementSugar();
      expect(
          (await repo.summary(period: 'all', materialId: 'ALL'))['filtered_count'],
          5);
      expect((await repo.summary(period: 'all', materialId: ''))['filtered_count'],
          5);
      expect((await repo.summary(period: 'all'))['filtered_count'], 5);
    });

    test('an unparseable materialId coerces to -1 and silently matches nothing',
        () async {
      // `int.tryParse(materialId) ?? -1`. A corrupt dropdown value therefore
      // renders as an empty dashboard instead of surfacing the bad filter.
      await seedCementSugar();
      final s = await repo.summary(period: 'all', materialId: 'not-a-number');
      expect(s['filtered_count'], 0);
      expect(totalsOf(s)['approvalRate'], '0.0');
    });

    test('supplier restricts the aggregation to that supplier only', () async {
      await seedCementSugar();
      final s = await repo.summary(period: 'all', supplier: 'Globex');
      expect(s['filtered_count'], 1);
      expect(totalsOf(s)['rejected'], 1);
    });

    test('a NULL supplier is bucketed under the Arabic placeholder', () async {
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'N-1',
          materialId: m,
          materialName: 'Salt',
          date: dayOffset(1),
          status: 'APPROVED',
          supplier: null);

      final sups = (await repo.summary(period: 'all'))['topSuppliers'] as List;
      expect(sups.single['name'], 'بدون مورد');
    });

    test('the placeholder supplier bucket cannot be filtered back out', () async {
      // `supplier = 'بدون مورد'` is compared against a column whose value is
      // NULL; SQL `NULL = 'x'` is never true, so picking the "no supplier" row
      // from the dropdown yields an empty dashboard.
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'N-1',
          materialId: m,
          materialName: 'Salt',
          date: dayOffset(1),
          status: 'APPROVED',
          supplier: null);

      final s = await repo.summary(period: 'all', supplier: 'بدون مورد');
      expect(s['filtered_count'], 0);
    });

    test('status matches the canonical code exactly', () async {
      await seedCementSugar();
      final s = await repo.summary(period: 'all', status: 'PARTIAL_REJECTION');
      expect(s['filtered_count'], 1);
    });

    test('status ALL or empty means "no status filter"', () async {
      await seedCementSugar();
      expect((await repo.summary(period: 'all', status: 'ALL'))['filtered_count'],
          5);
      expect((await repo.summary(period: 'all', status: ''))['filtered_count'], 5);
    });

    test('a legacy status filter is normalised but then matches nothing',
        () async {
      // `_normalizeStatus('CONDITIONAL')` -> 'CONDITIONAL_APPROVAL', so the
      // WHERE clause asks for the canonical code. A row that actually still
      // holds the legacy 'CONDITIONAL' is counted by the unfiltered aggregation
      // but is invisible to this filter: the two disagree about the same row.
      final m = await addMaterial('Wheat');
      await addInspection(
          entryCode: 'L-1',
          materialId: m,
          materialName: 'Wheat',
          date: dayOffset(1),
          status: 'CONDITIONAL');
      await addInspection(
          entryCode: 'L-2',
          materialId: m,
          materialName: 'Wheat',
          date: dayOffset(1),
          status: 'CONDITIONAL_APPROVAL');

      expect((await repo.summary(period: 'all'))['filtered_count'], 2);
      expect(
          (await repo.summary(period: 'all', status: 'CONDITIONAL'))
              ['filtered_count'],
          1,
          reason: 'the legacy row is silently dropped by its own legacy filter');
    });

    test('period 7d keeps the last week and drops everything older', () async {
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'P-1',
          materialId: m,
          materialName: 'Salt',
          date: dayOffset(2),
          status: 'APPROVED');
      await addInspection(
          entryCode: 'P-2',
          materialId: m,
          materialName: 'Salt',
          date: dayOffset(20),
          status: 'APPROVED');

      expect((await repo.summary(period: '7d'))['filtered_count'], 1);
      expect((await repo.summary(period: '30d'))['filtered_count'], 2);
      expect((await repo.summary(period: '365d'))['filtered_count'], 2);
    });

    test('an unrecognised period silently means "all time"', () async {
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'P-1',
          materialId: m,
          materialName: 'Salt',
          date: '2001-01-01',
          status: 'APPROVED');

      // A typo'd or newer period code falls through the switch with no condition
      // added, so the user silently sees a lifetime total while the UI still
      // claims they asked for a short window.
      final s = await repo.summary(period: '7days');
      expect(s['filtered_count'], 1);
      expect(s['period'], '7days');
    });

    test('every filter composes as AND', () async {
      await seedCementSugar();
      final cement = await db
          .query('reference_materials',
              where: 'material_name = ?', whereArgs: ['Cement']);
      final s = await repo.summary(
        period: 'all',
        materialId: '${cement.first['id']}',
        supplier: 'Acme',
        status: 'APPROVED',
      );
      expect(s['filtered_count'], 2);
    });
  });

  group('summary() — breakdowns', () {
    test('per-material rate is approved/total and rows sort by volume', () async {
      final cement = await addMaterial('Cement');
      final sugar = await addMaterial('Sugar');
      for (var i = 0; i < 3; i++) {
        await addInspection(
            entryCode: 'C-$i',
            materialId: cement,
            materialName: 'Cement',
            date: dayOffset(1),
            status: 'APPROVED');
      }
      await addInspection(
          entryCode: 'S-1',
          materialId: sugar,
          materialName: 'Sugar',
          date: dayOffset(1),
          status: 'APPROVED');

      final top = (await repo.summary(period: 'all'))['topMaterials'] as List;
      expect(top.first['name'], 'Cement');
      expect(top.first['total'], 3);
      expect(top.first['rate'], '100.0');
      expect(top.last['name'], 'Sugar');
    });

    test('per-material buckets keep conditional separate from rejected', () async {
      final m = await addMaterial('Wheat');
      await addInspection(
          entryCode: 'W-1',
          materialId: m,
          materialName: 'Wheat',
          date: dayOffset(1),
          status: 'APPROVED');
      await addInspection(
          entryCode: 'W-2',
          materialId: m,
          materialName: 'Wheat',
          date: dayOffset(1),
          status: 'CONDITIONAL_APPROVAL');
      await addInspection(
          entryCode: 'W-3',
          materialId: m,
          materialName: 'Wheat',
          date: dayOffset(1),
          status: 'PARTIAL_REJECTION');

      final mat =
          (await repo.summary(period: 'all'))['topMaterials'].single as Map;
      expect(mat['total'], 3);
      expect(mat['approved'], 1);
      expect(mat['conditional'], 1);
      expect(mat['rejected'], 1,
          reason: 'PARTIAL_REJECTION shares the `rejected` key with FULL');
      expect(mat['rate'], '33.3');
    });

    test('topMaterials and topSuppliers are both capped at six entries',
        () async {
      for (var i = 0; i < 8; i++) {
        final id = await addMaterial('Mat$i');
        await addInspection(
            entryCode: 'M-$i',
            materialId: id,
            materialName: 'Mat$i',
            date: dayOffset(1),
            status: 'APPROVED',
            supplier: 'Sup$i');
      }

      final s = await repo.summary(period: 'all');
      expect((s['topMaterials'] as List), hasLength(6));
      expect((s['topSuppliers'] as List), hasLength(6));
      expect(s['filtered_count'], 8,
          reason: 'the cap only shortens the breakdown, never the headline total');
    });

    test('latest is the newest inspection_date, ties resolved by query order',
        () async {
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'OLD',
          materialId: m,
          materialName: 'Salt',
          date: dayOffset(10),
          status: 'APPROVED');
      final newA = await db.insert('inspections', <String, dynamic>{
        'entry_code': 'NEW-A',
        'material_id': m,
        'material_name': 'Salt',
        'material_code': 'M-Salt',
        'inspection_date': dayOffset(1),
        'specialist_name': 'Tester',
        'physical_results_json': '{}',
        'chemical_results_json': '{}',
        'physical_reference_json': '{}',
        'chemical_reference_json': '{}',
        'decision_status': 'APPROVED',
        'snapshot_json': '{}',
        'sample_names_json': '[]',
        'decision_version': 1,
        'created_by': 0,
        'created_by_name': 'Unknown user',
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      await addRawInspection(<String, dynamic>{
        'id': newA + 1,
        'entry_code': 'NEW-B',
        'material_id': m,
        'material_name': 'Salt',
        'inspection_date': dayOffset(1),
      });

      final latest =
          (await repo.summary(period: 'all'))['latest'] as Map<String, dynamic>;
      expect(latest['date'], dayOffset(1));
      // Rows arrive ordered `inspection_date DESC, id DESC` and the scan uses a
      // strict `>`, so on a tie the first row wins: the newest-created of the
      // two same-day rows, not an arbitrary one.
      expect(latest['label'], 'Salt');
    });

    test('latest falls back to entry_code only when material_name is NULL',
        () async {
      // `latest['material_name'] ?? latest['entry_code']` uses `??`, so an
      // EMPTY material_name (legal on the column) yields a blank label instead
      // of the entry code the user can search by.
      final m = await addMaterial('Salt');
      await addRawInspection(<String, dynamic>{
        'entry_code': 'QC-ONLY-CODE',
        'material_id': m,
        'material_name': '',
        'inspection_date': dayOffset(1),
      });

      final latest =
          (await repo.summary(period: 'all'))['latest'] as Map<String, dynamic>;
      expect(latest['label'], '');
    });
  });

  group('summary() — monthly trend', () {
    test('the trend is padded to six zeroed months even with no rows at all',
        () async {
      // `_monthlyTrend` always emits at least six keys, so the chart keeps its
      // x-axis instead of rendering an empty column — but every bucket is zero.
      final trend = (await repo.summary(period: 'all'))['monthlyTrend'] as List;
      expect(trend, hasLength(6));
      expect(trendTotal(trend), 0);
      for (final b in trend) {
        expect(b['total'], 0);
        expect(b['approvalRate'], '0.0');
      }
    });

    test('a missing month is padded with zero rates and bare "0" widths',
        () async {
      // `_buildMonthlyBucket` guards `total > 0`, but the widths use the
      // literal '0' while the rates use '0.0' — two different zero formats on
      // the same bucket, so a consumer that parses both must know that.
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'T-1',
          materialId: m,
          materialName: 'Salt',
          date: thisMonth(),
          status: 'APPROVED');

      final trend = (await repo.summary(period: 'all'))['monthlyTrend'] as List;
      expect(trend.last['total'], 1);
      final empty = trend.first as Map<String, dynamic>;
      expect(empty['total'], 0);
      expect(empty['approvalRate'], '0.0');
      expect(empty['rejectionRate'], '0.0');
      expect(empty['approvedWidth'], '0');
      expect(empty['conditionalWidth'], '0');
      expect(empty['rejectedWidth'], '0');
    });

    test('monthly buckets split approvals/conditionals/rejections', () async {
      // FIXED (was BUG PINNED): `summary()` now increments the per-status
      // bucket counters alongside `total`, so the trend chart agrees with the
      // headline numbers. PARTIAL counts as rejected in the monthly buckets.
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'T-1',
          materialId: m,
          materialName: 'Salt',
          date: thisMonth(),
          status: 'APPROVED');
      await addInspection(
          entryCode: 'T-2',
          materialId: m,
          materialName: 'Salt',
          date: thisMonth(),
          status: 'CONDITIONAL_APPROVAL');
      await addInspection(
          entryCode: 'T-3',
          materialId: m,
          materialName: 'Salt',
          date: thisMonth(),
          status: 'PARTIAL_REJECTION');

      final s = await repo.summary(period: 'all');
      final bucket = (s['monthlyTrend'] as List).last;
      expect(bucket['total'], 3, reason: 'the row count itself is correct');
      expect(bucket['approved'], 1);
      expect(bucket['conditional'], 1);
      expect(bucket['rejected'], 1);
      expect(bucket['approvalRate'], '33.3');
      expect(bucket['rejectionRate'], '66.7');
      expect(bucket['approvedWidth'], '33.33');
      expect(bucket['conditionalWidth'], '33.33');
      expect(bucket['rejectedWidth'], '33.33');

      // The headline numbers, computed by the same loop, are right — proving the
      // defect is isolated to the monthly buckets.
      expect(totalsOf(s)['approved'], 1);
      expect(totalsOf(s)['approvalRate'], '33.3');
      expect(
          ((s['topMaterials'] as List).single as Map)['approved'],
          1,
          reason: 'the per-material breakdown does count approvals');
    });

    test('buckets key off inspection_date, not created_at', () async {
      final m = await addMaterial('Salt');
      // Inspected this month, but "created" two months ago.
      await addRawInspection(<String, dynamic>{
        'entry_code': 'B-1',
        'material_id': m,
        'material_name': 'Salt',
        'inspection_date': thisMonth(),
        'created_at': '${monthOffset(-2)}-15 08:00:00',
        'updated_at': '${monthOffset(-2)}-15 08:00:00',
      });

      final trend = (await repo.summary(period: 'all'))['monthlyTrend'] as List;
      expect(trend.last['total'], 1, reason: 'the inspection month is the key');
      expect(trend.first['total'], 0);
    });

    test('a month older than the window is counted in totals but dropped from the trend',
        () async {
      // `_monthlyTrend` sizes the window from the *number of buckets* but always
      // anchors it on the current month, so a bucket outside that window is
      // silently discarded and the trend's own total stops matching
      // `filtered_count`.
      final m = await addMaterial('Salt');
      for (var i = 0; i < 6; i++) {
        await addInspection(
            entryCode: 'W-$i',
            materialId: m,
            materialName: 'Salt',
            date: '${monthOffset(-i)}-15',
            status: 'APPROVED');
      }
      await addInspection(
          entryCode: 'ANCIENT',
          materialId: m,
          materialName: 'Salt',
          date: '2019-03-04',
          status: 'APPROVED');

      final s = await repo.summary(period: 'all');
      expect(s['filtered_count'], 7);
      expect(trendTotal(s['monthlyTrend'] as List), 6,
          reason: 'the 2019 bucket is dropped: the window is anchored on "now"');
    });

    test('an unparseable inspection_date counts in totals but not in the trend',
        () async {
      final m = await addMaterial('Salt');
      await addRawInspection(<String, dynamic>{
        'entry_code': 'BAD-DATE',
        'material_id': m,
        'material_name': 'Salt',
        'inspection_date': 'not-a-date',
        'created_at': 'not-a-date 08:00:00',
        'updated_at': 'not-a-date 08:00:00',
      });

      final s = await repo.summary(period: 'all');
      expect(s['filtered_count'], 1);
      expect(totalsOf(s)['approved'], 1,
          reason: 'the decision still counts even though the month is unknown');
      expect(trendTotal(s['monthlyTrend'] as List), 0);
    });
  });

  group('summary() — comparison, recommendations and insight cards', () {
    test('comparison reports "no trend" when no month has data', () async {
      final comparison =
          (await repo.summary(period: 'all'))['comparison'] as Map;
      expect(comparison['approvalDelta'], '0.0');
      expect(comparison['label'], 'لا يوجد اتجاه بعد');
    });

    test('a single month reports that month\'s rate', () async {
      // FIXED (was BUG PINNED): `_comparison` reads the now-live bucket
      // `approvalRate`, so the "this month" figure matches the data.
      final m = await addMaterial('Salt');
      for (var i = 0; i < 2; i++) {
        await addInspection(
            entryCode: 'X-$i',
            materialId: m,
            materialName: 'Salt',
            date: thisMonth(),
            status: 'APPROVED');
      }

      final s = await repo.summary(period: 'all');
      expect(totalsOf(s)['approvalRate'], '100.0',
          reason: 'the headline rate is correct');
      final comparison = s['comparison'] as Map;
      expect(comparison['label'], 'نسبة القبول هذا الشهر');
      expect(comparison['approvalDelta'], '100.0');
    });

    test('two months of data report the real approval delta', () async {
      // FIXED (was BUG PINNED): both sides of the delta are live, so a
      // collapse from 100% to 0% reports a decline of 100 points.
      final m = await addMaterial('Salt');
      for (var i = 0; i < 2; i++) {
        await addInspection(
            entryCode: 'OLD-$i',
            materialId: m,
            materialName: 'Salt',
            date: '${monthOffset(-1)}-10',
            status: 'APPROVED');
      }
      for (var i = 0; i < 2; i++) {
        await addInspection(
            entryCode: 'NOW-$i',
            materialId: m,
            materialName: 'Salt',
            date: thisMonth(),
            status: 'FULL_REJECTION');
      }

      final comparison =
          (await repo.summary(period: 'all'))['comparison'] as Map;
      expect(comparison['approvalDeltaSign'], '');
      expect(comparison['approvalDelta'], '100.0');
      expect(comparison['label'], 'انخفاض عن الشهر السابق (-100.0%)');
    });

    test('the month-over-month insight card fires on real movement', () async {
      // FIXED (was BUG PINNED): `_insightCards` computes its trend from the
      // live bucket `approvalRate`, so a 0% -> 100% jump emits improvement.
      final m = await addMaterial('Salt');
      for (var i = 0; i < 2; i++) {
        await addInspection(
            entryCode: 'OLD-$i',
            materialId: m,
            materialName: 'Salt',
            date: '${monthOffset(-1)}-10',
            status: 'FULL_REJECTION');
      }
      for (var i = 0; i < 4; i++) {
        await addInspection(
            entryCode: 'NOW-$i',
            materialId: m,
            materialName: 'Salt',
            date: thisMonth(),
            status: 'APPROVED');
      }

      final cards = (await repo.summary(period: 'all'))['insightCards'] as List;
      expect(cards.map((c) => '${c['title']}'), contains('اتجاه تحسن'));
      expect(cards.map((c) => '${c['title']}'),
          isNot(contains('اتجاه انخفاض')));
    });

    test('recommendations fire on the documented thresholds', () async {
      // Five rows: Salt has 1 approved of 4 = 25.0% (material threshold < 80%),
      // Nice has 1 approved of 1 = 100%. Rejections are 1 partial + 1 full out
      // of five rows = 40.0% (threshold is > 15%). One conditional decision must
      // always raise a follow-up line.
      final salt = await addMaterial('Salt');
      final nice = await addMaterial('Nice');
      await addInspection(
          entryCode: 'S-1',
          materialId: salt,
          materialName: 'Salt',
          date: dayOffset(1),
          status: 'APPROVED');
      for (final status in [
        'CONDITIONAL_APPROVAL',
        'PARTIAL_REJECTION',
        'FULL_REJECTION'
      ]) {
        await addInspection(
            entryCode: 'S-$status',
            materialId: salt,
            materialName: 'Salt',
            date: dayOffset(1),
            status: status);
      }
      await addInspection(
          entryCode: 'N-1',
          materialId: nice,
          materialName: 'Nice',
          date: dayOffset(1),
          status: 'APPROVED');

      final recs = (await repo.summary(period: 'all'))['recommendations'] as List;
      expect(recs.any((r) => '$r'.contains('"Salt"')), isTrue,
          reason: 'a material under 80% acceptance must be called out by name');
      expect(recs.any((r) => '$r'.contains('"Nice"')), isFalse,
          reason: 'a material at 100% must not be named');
      expect(recs.any((r) => '$r'.contains('40.0')), isTrue,
          reason: 'the overall rejection rate is quoted, not rounded away');
      expect(recs.any((r) => '$r'.contains('1 فحص')), isTrue,
          reason: 'a conditional decision always raises a follow-up line');
    });

    test('a supplier under 70% acceptance is recommended for review', () async {
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'R-1',
          materialId: m,
          materialName: 'Salt',
          date: dayOffset(1),
          status: 'APPROVED');
      for (var i = 0; i < 3; i++) {
        await addInspection(
            entryCode: 'R-${i + 2}',
            materialId: m,
            materialName: 'Salt',
            date: dayOffset(1),
            status: 'FULL_REJECTION',
            supplier: 'BadSupplier');
      }
      await addInspection(
          entryCode: 'R-6',
          materialId: m,
          materialName: 'Salt',
          date: dayOffset(1),
          status: 'APPROVED',
          supplier: 'GoodSupplier');

      final recs = (await repo.summary(period: 'all'))['recommendations'] as List;
      expect(recs.any((r) => '$r'.contains('BadSupplier')), isTrue,
          reason: 'BadSupplier is 0/3 = 0.0%, well under the 70% supplier line');
      expect(recs.any((r) => '$r'.contains('GoodSupplier')), isFalse,
          reason: 'GoodSupplier is 1/1 = 100% and must not be flagged');
    });

    test('a clean sheet produces only the generic "keep going" recommendation',
        () async {
      final m = await addMaterial('Salt');
      for (var i = 0; i < 10; i++) {
        await addInspection(
            entryCode: 'G-$i',
            materialId: m,
            materialName: 'Salt',
            date: dayOffset(1),
            status: 'APPROVED');
      }

      final recs = (await repo.summary(period: 'all'))['recommendations'] as List;
      expect(recs, hasLength(1));
      expect('${recs.single}', contains('الأداء العام جيد'));
    });

    test('the approval tone is success at >=90% and danger below 70%', () async {
      final m = await addMaterial('Tone');
      Future<String?> toneWith(String status, int approved, int other) async {
        await db.delete('inspections');
        for (var i = 0; i < approved; i++) {
          await addInspection(
              entryCode: 'A-$i',
              materialId: m,
              materialName: 'Tone',
              date: dayOffset(1),
              status: 'APPROVED');
        }
        for (var i = 0; i < other; i++) {
          await addInspection(
              entryCode: 'O-$i',
              materialId: m,
              materialName: 'Tone',
              date: dayOffset(1),
              status: status);
        }
        final cards =
            (await repo.summary(period: 'all'))['insightCards'] as List;
        return cards.isEmpty ? null : '${cards.first['tone']}';
      }

      // 10/10 = 100% -> success.  7/10 = 70% -> warning (inclusive bound).
      expect(await toneWith('APPROVED', 10, 0), 'success');
      expect(await toneWith('FULL_REJECTION', 7, 3), 'warning');
      // 6/10 = 60% -> danger. The conditional here must NOT lift it into the
      // warning band, because the threshold is read off approvalRate alone.
      expect(await toneWith('CONDITIONAL_APPROVAL', 6, 4), 'danger');
    });

    test('a rejection rate above 20% adds its own danger card', () async {
      final m = await addMaterial('Bad');
      for (var i = 0; i < 3; i++) {
        await addInspection(
            entryCode: 'B-$i',
            materialId: m,
            materialName: 'Bad',
            date: dayOffset(1),
            status: 'FULL_REJECTION');
      }
      await addInspection(
          entryCode: 'B-3',
          materialId: m,
          materialName: 'Bad',
          date: dayOffset(1),
          status: 'APPROVED');

      final cards = (await repo.summary(period: 'all'))['insightCards'] as List;
      final high = cards.firstWhere((c) => c['title'] == 'نسبة رفض مرتفعة');
      expect(high['tone'], 'danger');
      expect('${high['description']}', contains('75.0'),
          reason: 'the card quotes the real rate: 3 rejections of 4 rows');
    });
  });

  group('todayKpis()', () {
    test('an empty database yields four zeros, never NaN', () async {
      final kpis = await repo.todayKpis();
      expect(kpis['today_count'], 0);
      expect(kpis['today_approved'], 0);
      expect(kpis['today_rejected'], 0);
      expect(kpis['total_count'], 0);
    });

    test('today_count is date-scoped while total_count is all-time', () async {
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'K-1',
          materialId: m,
          materialName: 'Salt',
          date: todayIso(),
          status: 'APPROVED');
      await addInspection(
          entryCode: 'K-2',
          materialId: m,
          materialName: 'Salt',
          date: dayOffset(3),
          status: 'FULL_REJECTION');
      await addInspection(
          entryCode: 'K-3',
          materialId: m,
          materialName: 'Salt',
          date: '2020-01-01',
          status: 'FULL_REJECTION');

      final kpis = await repo.todayKpis();
      expect(kpis['today_count'], 1);
      expect(kpis['today_approved'], 1);
      expect(kpis['today_rejected'], 0);
      expect(kpis['total_count'], 3);
    });

    test('today_approved folds CONDITIONAL_APPROVAL in, unlike summary()',
        () async {
      // Two surfaces on the *same screen* answer "how many passed?": this card
      // says 2, summary().totals.approved says 0. Pinned because the two must
      // not drift further apart unnoticed.
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'K-1',
          materialId: m,
          materialName: 'Salt',
          date: todayIso(),
          status: 'CONDITIONAL_APPROVAL');
      await addInspection(
          entryCode: 'K-2',
          materialId: m,
          materialName: 'Salt',
          date: todayIso(),
          status: 'CONDITIONAL');

      final kpis = await repo.todayKpis();
      expect(kpis['today_count'], 2);
      expect(kpis['today_approved'], 2);

      final totals = totalsOf(await repo.summary(period: 'all'));
      expect(totals['approved'], 0);
      expect(totals['conditional'], 2);
    });

    test('both rejection codes count as today_rejected', () async {
      final m = await addMaterial('Salt');
      for (final entry in ['K-1', 'K-2', 'K-3']) {
        await addInspection(
            entryCode: entry,
            materialId: m,
            materialName: 'Salt',
            date: todayIso(),
            status: entry == 'K-2' ? 'PARTIAL' : 'FULL_REJECTION');
      }

      final kpis = await repo.todayKpis();
      expect(kpis['today_count'], 3);
      expect(kpis['today_rejected'], 3);
      expect(kpis['today_approved'], 0);
    });

    test('an unknown status is counted in today_count and nowhere else', () async {
      final m = await addMaterial('Salt');
      await addInspection(
          entryCode: 'K-1',
          materialId: m,
          materialName: 'Salt',
          date: todayIso(),
          status: 'PENDING');

      final kpis = await repo.todayKpis();
      expect(kpis['today_count'], 1);
      expect(kpis['today_approved'], 0);
      expect(kpis['today_rejected'], 0);
    });

    test('today_count uses an exact string match, so a timestamped date is missed',
        () async {
      // `inspection_date = ?` compares the whole TEXT value against
      // `yyyy-MM-dd`; a legacy row holding "2026-01-01 08:00:00" is invisible to
      // today's card even though `total_count` still sees it.
      final m = await addMaterial('Salt');
      await addRawInspection(<String, dynamic>{
        'entry_code': 'TS-1',
        'material_id': m,
        'material_name': 'Salt',
        'inspection_date': '${todayIso()} 08:00:00',
      });

      final kpis = await repo.todayKpis();
      expect(kpis['today_count'], 0);
      expect(kpis['total_count'], 1);
    });
  });

  group('filterOptions()', () {
    test('materials and suppliers are always prefixed with the ALL sentinel',
        () async {
      final options = await repo.filterOptions();
      expect(options.materials.first, {'id': 'ALL', 'name': 'جميع الخامات'});
      expect(options.suppliers.first,
          {'id': 'ALL', 'name': 'جميع الموردين'});
      expect(options.materials, hasLength(1),
          reason: 'an empty database must still yield a usable dropdown');
      expect(options.suppliers, hasLength(1));
    });

    test('only active materials are offered', () async {
      await addMaterial('Live', code: 'M-LIVE');
      await addMaterial('Archived', code: 'M-ARC', active: 0);

      final names = (await repo.filterOptions())
          .materials
          .map((m) => '${m['name']}')
          .toList();
      expect(names, ['جميع الخامات', 'Live (M-LIVE)']);
    });

    test('suppliers are de-duplicated, sorted, and exclude NULL and empty',
        () async {
      final m = await addMaterial('Salt');
      final suppliers = <String?>['Zeta', 'Alpha', 'Zeta', null, ''];
      for (var i = 0; i < suppliers.length; i++) {
        await addInspection(
          entryCode: 'F-$i',
          materialId: m,
          materialName: 'Salt',
          date: dayOffset(1),
          status: 'APPROVED',
          supplier: suppliers[i],
        );
      }

      final names = (await repo.filterOptions())
          .suppliers
          .map((s) => '${s['name']}')
          .toList();
      expect(names, ['جميع الموردين', 'Alpha', 'Zeta']);
    });

    test('the status list is exactly ALL plus the four canonical codes', () async {
      // Legacy CONDITIONAL / PARTIAL are never selectable, which is why the
      // status filter can never reach the rows it is supposed to normalise.
      expect((await repo.filterOptions()).statuses, [
        'ALL',
        'APPROVED',
        'CONDITIONAL_APPROVAL',
        'PARTIAL_REJECTION',
        'FULL_REJECTION',
      ]);
    });

    test('material options carry the id the filter expects', () async {
      final id = await addMaterial('Salt', code: 'M-SALT-01');
      final options = await repo.filterOptions();
      final salt =
          options.materials.firstWhere((m) => m['name'] == 'Salt (M-SALT-01)');
      expect(salt['id'], '$id');
    });
  });

  group('dashboardBundle() — cross-module analyst KPIs', () {
    test('empty database yields a zeroed bundle, never a throw', () async {
      final b = await repo.dashboardBundle(period: 'all');
      expect(b.volume.total, 0);
      expect(b.quality.total, 0);
      expect(b.quality.acceptanceRate, 0.0);
      expect(b.lab.totalTests, 0);
      expect(b.qc.total, 0);
      expect(b.ncr.total, 0);
      expect(b.ncr.onTimePct, isNull);
      expect(b.sopGoals.sopTotal, 0);
      expect(b.inventory.skus, 0);
      expect(b.trend, hasLength(6));
    });

    test('inspection sections honour filters; acceptance folds conditional',
        () async {
      await seedCementSugar();
      final b = await repo.dashboardBundle(period: 'all');
      // 5 rows: 2 approved + 1 conditional + 1 partial + 1 full.
      expect(b.quality.total, 5);
      expect(b.quality.approved, 2);
      expect(b.quality.conditional, 1);
      expect(b.quality.acceptanceRate, 60.0);
      expect(b.quality.strictRate, 40.0);
      expect(b.quality.rejectionRate, 40.0);
      expect(b.volume.total, 5);
      // Quantities: addInspection writes quantity '10' each; partial has no
      // rejected_quantity, so rejected-qty ratio is 10 (one FULL) / 50.
      expect(b.quality.totalQty, 50.0);
      expect(b.quality.rejectedQtyRatio, 20.0);
    });

    test('inventory section counts low/empty stock', () async {
      await db.insert('lab_inventory', <String, dynamic>{
        'name': 'Acid',
        'category': 'liquid',
        'unit': 'L',
        'current_qty': 2,
        'min_qty': 5,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      await db.insert('lab_inventory', <String, dynamic>{
        'name': 'Salt-lab',
        'category': 'powder',
        'unit': 'kg',
        'current_qty': 0,
        'min_qty': 1,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      await db.insert('lab_inventory', <String, dynamic>{
        'name': 'Water',
        'category': 'liquid',
        'unit': 'L',
        'current_qty': 50,
        'min_qty': 5,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      final b = await repo.dashboardBundle(period: 'all');
      expect(b.inventory.skus, 3);
      expect(b.inventory.low, 1);
      expect(b.inventory.empty, 1);
      expect(b.inventory.ok, 1);
      expect(b.inventory.lowItems.map((e) => '${e['name']}'),
          contains('Acid'));
      expect(b.lab.lowStockCount, 2,
          reason: 'lab counts every row with qty < min (low + empty)');
    });

    test('NCR section aggregates open/overdue/severity', () async {
      final insp = await db.insert('qc_inspections', <String, dynamic>{
        'template_id': 1,
        'inspection_date': dayOffset(10),
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      final overdueDay = dayOffset(40);
      final futureDay = dayOffset(-40);
      await db.insert('qc_findings_nc', <String, dynamic>{
        'inspection_id': insp,
        'severity': 'Critical',
        'description': 'crit open overdue',
        'status': 'Open',
        'due_date': overdueDay,
        'created_at': '${dayOffset(40)} 08:00:00',
        'updated_at': nowIso(),
      });
      await db.insert('qc_findings_nc', <String, dynamic>{
        'inspection_id': insp,
        'severity': 'Major',
        'description': 'major open',
        'status': 'InProgress',
        'due_date': futureDay,
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      final b = await repo.dashboardBundle(period: 'all');
      expect(b.ncr.total, 2);
      expect(b.ncr.open, 2);
      expect(b.ncr.overdue, 1);
      expect(b.ncr.overduePct, 50.0);
      expect(b.ncr.critical, 1);
      expect(b.ncr.major, 1);
      expect(b.ncr.onTimePct, isNull,
          reason: 'nothing closed, so the rate is unknown, not 0%');
      expect(b.ncr.aging.fold<int>(0, (a, v) => a + v), 2);
    });

    test('SOP section counts published/expired/expiring/pending', () async {
      final today = todayIso();
      await db.insert('qc_sops', <String, dynamic>{
        'code': 'SOP-OLD',
        'title': 'Old',
        'status': 'Published',
        'expiry_date': dayOffset(10),
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      await db.insert('qc_sops', <String, dynamic>{
        'code': 'SOP-SOON',
        'title': 'Soon',
        'status': 'Published',
        'expiry_date': dayOffset(-10),
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      await db.insert('qc_sops', <String, dynamic>{
        'code': 'SOP-PEND',
        'title': 'Pending',
        'status': 'Pending',
        'created_at': nowIso(),
        'updated_at': nowIso(),
      });
      final b = await repo.dashboardBundle(period: 'all');
      expect(b.sopGoals.sopTotal, 3);
      expect(b.sopGoals.sopPublished, 2);
      expect(b.sopGoals.sopExpired, 1);
      expect(b.sopGoals.sopExpiring, 1);
      expect(b.sopGoals.sopPending, 1);
      expect(today, isNotEmpty, reason: 'todayIso helper is linked');
    });
  });
}