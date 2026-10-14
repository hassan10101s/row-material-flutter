import 'package:flutter_test/flutter_test.dart';

import 'package:material_lab/features/lab/data/lab_repo.dart';

import '../sync/sync_test_fixture.dart';

/// `_decorateAnalysesBatch` must be byte-identical to mapping
/// `_decorateAnalysis` per row, at 2 queries instead of 2N.
void main() {
  late SyncFixture fx;
  late LabRepo repo;

  setUp(() async {
    fx = await openSyncFixture();
    await fx.seedOrganization();
    repo = LabRepo(dbHelper: fx.helper);

    for (final name in ['Alpha', 'Beta']) {
      final aid = await fx.db.rawInsert(
        "INSERT INTO lab_analyses (name, unit, dynamic_fields_json, "
        "formula_json, created_at) VALUES (?, '%', '[\"F\"]', '{}', 'x')",
        [name],
      );
      final inv = await fx.db.rawInsert(
        "INSERT INTO lab_inventory (name, category, unit, current_qty, "
        "min_qty, created_at, updated_at) VALUES (?, 'liquid', 'mL', 9, 1, "
        "'x', 'x')",
        ['Reagent $name'],
      );
      await fx.db.rawInsert(
        'INSERT INTO lab_analysis_items (analysis_id, inventory_id, '
        'qty_per_sample, unit) VALUES (?, ?, ?, ?)',
        [aid, inv, 1.5, 'mL'],
      );
      await fx.db.rawInsert(
        'INSERT INTO lab_field_chemical_links (analysis_id, dynamic_field, '
        'kind, inventory_id, unit, list_values, created_at) '
        "VALUES (?, 'F', 'link', ?, 'mL', '[\"a\"]', 'x')",
        [aid, inv],
      );
    }
  });

  tearDown(() async {
    await fx.dispose();
  });

  test('batched decorate matches per-row decorate', () async {
    final rows = await repo.listAnalyses();
    expect(rows, hasLength(2));

    // Per-row path (kept for single-id reads like getAnalysis).
    final single = [
      for (final r in await repo.listAnalysesRawForTest())
        await repo.decorateAnalysisForTest(r),
    ];
    expect(single, hasLength(2));
    for (var i = 0; i < rows.length; i++) {
      expect(
        rows[i],
        equals(single[i]),
        reason: 'row $i differs between batched and single decorate',
      );
    }
  });

  test('paged list decorates with items + links', () async {
    final page = await repo.listAnalysesPaged(limit: 25, offset: 0);
    expect(page, hasLength(2));
    for (final a in page) {
      expect((a['items'] as List), hasLength(1));
      expect((a['field_chemical_links'] as List), hasLength(1));
      expect(
        ((a['field_chemical_links'] as List).single
            as Map)['list_values'],
        ['a'],
      );
    }
    expect(await repo.countAnalyses(), 2);
  });
}
