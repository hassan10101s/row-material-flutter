import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/lab/core/test_history_logic.dart';

void main() {
  group('thNormalizeText', () {
    test('normalizes Arabic variants', () {
      expect(thNormalizeText('أإآ'), 'ااا');
      expect(thNormalizeText('ة'), 'ه');
      expect(thNormalizeText('ى'), 'ي');
      expect(thNormalizeText('بِسْم'), 'بسم');
    });
  });

  group('thCoerceRecordLimit', () {
    test('clamps to allowed range', () {
      expect(thCoerceRecordLimit(''), 100);
      expect(thCoerceRecordLimit('0'), 100);
      expect(thCoerceRecordLimit('-5'), 100);
      expect(thCoerceRecordLimit('50'), 50);
      expect(thCoerceRecordLimit('99999'), 10000);
      expect(thCoerceRecordLimit('abc'), 100);
    });
  });

  group('thFilterModeRows', () {
    final rows = [
      {'tested_at': '2026-01-01 10:00:00', 'id': 1},
      {'tested_at': '2020-01-01 10:00:00', 'id': 2},
    ];

    test('last24h keeps recent rows', () {
      final now = DateTime(2026, 1, 1, 12);
      final out = thFilterModeRows(rows, 'last24h', '', now: now);
      expect(out.map((r) => r['id']), [1]);
    });

    test('specific-date matches day prefix', () {
      final out = thFilterModeRows(rows, 'specific-date', '2020-01-01');
      expect(out.map((r) => r['id']), [2]);
    });

    test('all mode passes rows through', () {
      final out = thFilterModeRows(rows, 'all', '');
      expect(out, hasLength(2));
    });
  });

  group('thApplyRowFilters', () {
    final rows = [
      {'id': 1, 'analysis_id': 7, 'source_type': 'raw_material', 'range_state': 'out', 'result_text': 'pH 7.2', 'sample_name': 'S1'},
      {'id': 2, 'analysis_id': 8, 'source_type': 'product', 'range_state': 'in', 'result_text': '99%', 'sample_name': 'S2'},
    ];

    test('filters by analysis, source, range and query', () {
      var out = thApplyRowFilters(rows,
          analysisId: '7', sourceType: '', chemicalId: '', rangeState: '', query: '', chemTestMap: {});
      expect(out, hasLength(1));

      out = thApplyRowFilters(rows,
          analysisId: '', sourceType: 'product', chemicalId: '', rangeState: '', query: '', chemTestMap: {});
      expect(out.map((r) => r['id']), [2]);

      out = thApplyRowFilters(rows,
          analysisId: '', sourceType: '', chemicalId: '', rangeState: 'out', query: '', chemTestMap: {});
      expect(out.map((r) => r['id']), [1]);

      out = thApplyRowFilters(rows,
          analysisId: '', sourceType: '', chemicalId: '', rangeState: '', query: 's2', chemTestMap: {});
      expect(out.map((r) => r['id']), [2]);
    });

    test('filters by consumed chemical via chemTestMap', () {
      final map = {'1': {'10'}};
      final out = thApplyRowFilters(rows,
          analysisId: '', sourceType: '', chemicalId: '10', rangeState: '', query: '', chemTestMap: map);
      expect(out.map((r) => r['id']), [1]);
    });

    test('and-style OR search with &', () {
      final out = thApplyRowFilters(rows,
          analysisId: '', sourceType: '', chemicalId: '', rangeState: '', query: 's1 & 99', chemTestMap: {});
      expect(out, hasLength(2));
    });
  });

  group('thSortRows', () {
    test('sorts ascending then descending', () {
      final rows = [
        {'id': 2, 'name': 'Beta'},
        {'id': 1, 'name': 'Alpha'},
        {'id': 3, 'name': 'Gamma'},
      ];
      final asc = thSortRows(rows, 'name', 1);
      expect(asc.map((r) => r['name']), ['Alpha', 'Beta', 'Gamma']);
      final desc = thSortRows(rows, 'name', -1);
      expect(desc.map((r) => r['name']), ['Gamma', 'Beta', 'Alpha']);
    });
  });

  group('thPagination', () {
    test('computes pages and slices', () {
      final rows = List.generate(120, (i) => {'id': i + 1});
      final p1 = thPagination(rows, 1, 50);
      expect(p1.pageCount, 3);
      expect(p1.slice, hasLength(50));
      final p3 = thPagination(rows, 3, 50);
      expect(p3.slice, hasLength(20));
      final beyond = thPagination(rows, 9, 50);
      expect(beyond.pageCount, 3);
      expect(beyond.slice, isEmpty);
    });
  });

  group('thBuildChemTestMap / options', () {
    test('maps and dedupes chemicals', () {
      final log = [
        {'sample_test_id': 1, 'inventory_id': 10, 'inventory_name': 'A'},
        {'sample_test_id': 1, 'inventory_id': 11, 'inventory_name': 'B'},
        {'sample_test_id': 2, 'inventory_id': 10, 'inventory_name': 'A'},
      ];
      final map = thBuildChemTestMap(log);
      expect(map['1'], {'10', '11'});
      expect(map['2'], {'10'});
      final opts = thBuildChemicalOptions(log);
      expect(opts, hasLength(2));
      expect(opts.map((o) => o.value), ['10', '11']);
    });
  });

  group('thBuildChips', () {
    test('builds removable chips per active filter', () {
      final chips = thBuildChips(
        filterMode: 'last24h',
        specificDate: '',
        analysisId: '7',
        sourceType: 'product',
        chemicalId: '10',
        rangeState: '',
        analyses: [
          {'id': 7, 'name': 'Moisture'},
        ],
        chemicalOptions: [
          (value: '10', label: 'A'),
        ],
      );
      expect(chips.map((c) => c.key), ['mode', 'analysis', 'source', 'chemical']);
    });

    test('clearChip resets the matching filter', () {
      final next = thClearChip(
        filterMode: 'specific-date',
        specificDate: '2026-09-01',
        analysisId: '7',
        sourceType: '',
        chemicalId: '',
        rangeState: 'out',
        query: '',
        key: 'mode',
      );
      expect(next.filterMode, 'all');
      expect(next.specificDate, '');
      expect(next.rangeState, 'out');
    });
  });
}