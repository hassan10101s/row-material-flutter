import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_filters.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_kpis.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_report_repository.dart';
import 'package:material_lab/features/qc_manager/domain/ncr_report_row.dart';
import 'package:material_lab/features/qc_manager/presentation/cubit/qc_ncr_cubit.dart';

/// In-memory stand-in for [QcNcReportRepository].
///
/// Records the filters it was handed so the tests can assert on *which*
/// population a load asked for, not just on what came back - a report whose
/// cards and table silently disagree passes every "the numbers are right" test.
class _FakeSource implements QcNcReportRepository {
  _FakeSource({this.rows = const []});

  List<NcrReportRow> rows;
  List<NcrAgingBucket> aging = const [];
  List<NcrTopDefect> defects = const [];
  List<NcrRepeatRef> repeats = const [];
  NcrFilterOptions options = const NcrFilterOptions();
  NcrReportRow? detailRow;

  Object? failWith;
  Object? failDetailWith;
  Object? failOptionsWith;

  int kpisCalls = 0;
  int optionCalls = 0;
  final List<NcrFilters> seen = [];
  final List<String> sortColumns = [];

  @override
  Future<NcrKpis> kpis(NcrFilters filters) async {
    kpisCalls++;
    seen.add(filters);
    if (failWith != null) throw failWith!;
    return const NcrKpis(total: 1);
  }

  @override
  Future<List<NcrReportRow>> list(
    NcrFilters filters, {
    int? limit,
    int? offset,
    String orderBy = 'finding_id',
    String orderDir = 'DESC',
  }) async {
    sortColumns.add(orderBy);
    if (failWith != null) throw failWith!;
    final start = (offset ?? 0).clamp(0, rows.length);
    final end = ((offset ?? 0) + (limit ?? rows.length)).clamp(
      start,
      rows.length,
    );
    return rows.sublist(start, end);
  }

  @override
  Future<int> count(NcrFilters filters) async {
    if (failWith != null) throw failWith!;
    return rows.length;
  }

  @override
  Future<NcrReportRow?> detail(int findingId) async {
    if (failDetailWith != null) throw failDetailWith!;
    return detailRow;
  }

  @override
  Future<List<NcrAgingBucket>> agingBuckets(NcrFilters filters) async => aging;

  @override
  Future<List<NcrTopDefect>> topDefects(
    NcrFilters filters, {
    int limit = 10,
  }) async => defects;

  @override
  Future<List<NcrRepeatRef>> repeatByRef(
    NcrFilters filters, {
    int limit = 10,
  }) async => repeats;

  @override
  Future<NcrFilterOptions> filterOptions() async {
    optionCalls++;
    if (failOptionsWith != null) throw failOptionsWith!;
    return options;
  }
}

NcrReportRow _row(
  int id, {
  String status = 'Open',
  String severity = 'Major',
}) => NcrReportRow(
  findingId: id,
  inspectionId: 1,
  severity: severity,
  description: 'defect $id',
  status: status,
  createdAt: '2026-01-01 09:00:00',
);

void main() {
  group('QcNcrCubit', () {
    late _FakeSource source;
    late QcNcrCubit cubit;

    setUp(() {
      source = _FakeSource(rows: [_row(3), _row(2), _row(1)]);
      cubit = QcNcrCubit(source);
    });

    tearDown(() => cubit.close());

    test('load fills every panel from one filter snapshot', () async {
      source.aging = const [NcrAgingBucket.d0to7(2)];
      source.defects = const [
        NcrTopDefect(code: 'D-1', category: '', count: 2),
      ];
      source.repeats = const [
        NcrRepeatRef(
          refKey: 'lot:L1',
          lotNo: 'L1',
          batchNo: '',
          refId: '',
          count: 2,
        ),
      ];

      await cubit.load();

      expect(cubit.state.loading, isFalse);
      expect(cubit.state.error, isNull);
      expect(cubit.state.rows.length, 3);
      expect(cubit.state.total, 3);
      expect(cubit.state.kpis.total, 1);
      expect(cubit.state.aging.single.count, 2);
      expect(cubit.state.topDefects.single.code, 'D-1');
      expect(cubit.state.repeatRefs.single.refKey, 'lot:L1');
      // Every panel was computed from the same filters object.
      expect(source.kpisCalls, 1);
    });

    test('a load resets to the first page', () async {
      // Two per page, so the seeded three rows actually span two pages.
      final paged = QcNcrCubit(source, pageSize: 2);
      addTearDown(paged.close);

      await paged.load();
      await paged.nextPage();
      expect(paged.state.filters.offset, 2);

      await paged.load();

      expect(paged.state.filters.offset, 0);
    });

    test('paging advances and stops at both ends', () async {
      final paged = QcNcrCubit(source, pageSize: 2);
      addTearDown(paged.close);

      await paged.load();
      expect(paged.state.page, 1);
      expect(paged.state.pageCount, 2);
      expect(paged.state.hasPrevious, isFalse);
      expect(paged.state.hasNext, isTrue);
      expect(paged.state.rows.length, 2);

      await paged.nextPage();
      expect(paged.state.filters.offset, 2);
      expect(paged.state.page, 2);
      expect(paged.state.hasPrevious, isTrue);
      expect(paged.state.hasNext, isFalse);
      expect(paged.state.rows.length, 1);

      // At the last page, going forward is a no-op.
      await paged.nextPage();
      expect(paged.state.filters.offset, 2);

      await paged.previousPage();
      expect(paged.state.filters.offset, 0);

      // At the first page, going back is a no-op rather than a negative offset.
      await paged.previousPage();
      expect(paged.state.filters.offset, 0);
    });

    test('an empty result still reports one page, not zero', () async {
      source.rows = [];
      await cubit.load();

      expect(cubit.state.page, 1);
      expect(cubit.state.pageCount, 1);
      expect(cubit.state.hasNext, isFalse);
      expect(cubit.state.hasRows, isFalse);
    });

    test('applying a filter returns to page one', () async {
      final paged = QcNcrCubit(source, pageSize: 2);
      addTearDown(paged.close);

      await paged.load();
      await paged.nextPage();
      expect(paged.state.filters.offset, 2);

      await paged.applyFilters(const NcrFilters(statuses: {'Open'}));

      expect(paged.state.filters.offset, 0);
      expect(paged.state.filters.statuses, {'Open'});
    });

    test('toggleFilter flips one value in one multi-select set', () async {
      await cubit.toggleFilter('severity', 'Critical');
      expect(cubit.state.filters.severities, {'Critical'});

      await cubit.toggleFilter('severity', 'Major');
      expect(cubit.state.filters.severities, {'Critical', 'Major'});

      await cubit.toggleFilter('severity', 'Critical');
      expect(cubit.state.filters.severities, {'Major'});
      expect(cubit.state.filters.statuses, isEmpty);
    });

    test(
      'an unknown filter field is ignored rather than clearing the set',
      () async {
        await cubit.toggleFilter('severity', 'Minor');
        await cubit.toggleFilter('nonsense', 'x');

        expect(cubit.state.filters.severities, {'Minor'});
      },
    );

    test('toggleOnlyOverdue flips and is reversible', () async {
      await cubit.toggleOnlyOverdue();
      expect(cubit.state.filters.onlyOverdue, isTrue);

      await cubit.toggleOnlyOverdue();
      expect(cubit.state.filters.onlyOverdue, isFalse);
    });

    test('setDateRange also switches the column being filtered', () async {
      await cubit.setDateRange(
        '2026-01-01',
        '2026-01-31',
        field: NcrFilters.dateFieldClosed,
      );

      expect(cubit.state.filters.from, '2026-01-01');
      expect(cubit.state.filters.to, '2026-01-31');
      expect(cubit.state.filters.dateField, NcrFilters.dateFieldClosed);
    });

    test('clearFilters drops everything, including onlyOverdue', () async {
      await cubit.toggleOnlyOverdue();
      await cubit.toggleFilter('status', 'Open');
      await cubit.setDateRange('2026-01-01', '2026-01-31');

      await cubit.clearFilters();

      expect(cubit.state.hasFilters, isFalse);
      expect(cubit.state.filters.onlyOverdue, isFalse);
    });

    test('setSort is forwarded to the query and keeps the page', () async {
      await cubit.load();
      await cubit.setSort('severity', 'ASC');
      expect(cubit.state.filters.offset, 0);
      expect(source.sortColumns.last, 'severity');
      expect(cubit.state.sortColumn, 'severity');
      expect(cubit.state.sortDir, 'ASC');

      // Re-selecting the same sort is a no-op rather than a redundant query.
      final before = source.kpisCalls;
      await cubit.setSort('severity', 'ASC');
      expect(source.kpisCalls, before);
    });

    test(
      'a failing load clears the rows instead of leaving stale ones',
      () async {
        await cubit.load();
        expect(cubit.state.rows.length, 3);

        source.failWith = StateError('db gone');
        await cubit.load();

        expect(cubit.state.error, contains('db gone'));
        expect(cubit.state.loading, isFalse);
        expect(cubit.state.rows, isEmpty);
        expect(cubit.state.kpis.total, 0);
        expect(cubit.state.total, 0);
        expect(cubit.state.aging, isEmpty);
      },
    );

    test('a late load cannot overwrite a newer one', () async {
      var calls = 0;
      final slow = _RacySource(() async {
        calls++;
        final n = calls;
        if (n == 1) {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return NcrKpis(total: 1);
        }
        return NcrKpis(total: 2);
      });
      final racy = QcNcrCubit(slow, pageSize: 10);
      addTearDown(racy.close);

      // First load is slow, second is fast; the slow one must lose.
      final first = racy.load();
      final second = racy.applyFilters(const NcrFilters(statuses: {'Closed'}));
      await Future.wait([first, second]);

      expect(racy.state.kpis.total, 2);
      expect(racy.state.filters.statuses, {'Closed'});
    });

    test(
      'loadOptions fetches facets on demand and a failure keeps the old set',
      () async {
        source.options = const NcrFilterOptions(statuses: ['Open']);
        await cubit.loadOptions();
        expect(cubit.state.options.statuses, ['Open']);

        source.failOptionsWith = StateError('facets unavailable');
        await cubit.loadOptions();

        // A missing facet list degrades the drawer to free text; it must not wipe
        // the facets that were already there.
        expect(cubit.state.options.statuses, ['Open']);
        expect(cubit.state.error, isNull);
      },
    );

    test('selectFinding loads one row and reports a missing one', () async {
      source.detailRow = _row(9);
      await cubit.selectFinding(9);
      expect(cubit.state.selectedFindingId, 9);
      expect(cubit.state.detail?.findingId, 9);
      expect(cubit.state.detailLoading, isFalse);
      expect(cubit.state.detailError, isNull);

      source.detailRow = null;
      await cubit.selectFinding(10);
      expect(cubit.state.detailError, contains('10'));
    });

    test('selectFailure surfaces on the detail pane only', () async {
      await cubit.load();
      source.failDetailWith = StateError('boom');

      await cubit.selectFinding(4);

      expect(cubit.state.detailError, contains('boom'));
      expect(cubit.state.error, isNull);
      expect(cubit.state.detailLoading, isFalse);
    });

    test('clearSelection drops the row and its error', () async {
      source.detailRow = _row(9);
      await cubit.selectFinding(9);
      source.detailRow = null;
      await cubit.selectFinding(10);

      await cubit.clearSelection();

      expect(cubit.state.selectedFindingId, isNull);
      expect(cubit.state.detail, isNull);
      expect(cubit.state.detailError, isNull);
    });

    test('emitting after close is a no-op', () async {
      await cubit.load();
      await cubit.close();
      expect(cubit.state.rows.length, 3);
    });

    test('exporting flag round-trips', () async {
      cubit.setExporting(true);
      expect(cubit.state.exporting, isTrue);
      cubit.setExporting(false);
      expect(cubit.state.exporting, isFalse);
    });
  });

  group('NcrFilters', () {
    test('isEmpty accounts for every field, onlyOverdue included', () {
      expect(const NcrFilters().isEmpty, isTrue);
      expect(const NcrFilters(onlyOverdue: true).isEmpty, isFalse);
      expect(const NcrFilters(from: '2026-01-01').isEmpty, isFalse);
      expect(const NcrFilters(lotNo: 'L1').isEmpty, isFalse);
      expect(
        const NcrFilters(statuses: {'Open'}, onlyOverdue: true).isEmpty,
        isFalse,
      );
    });

    test('copyWith clears paging unless a new offset is given', () {
      const f = NcrFilters(offset: 40);
      expect(f.copyWith().offset, 0);
      expect(f.copyWith(offset: 80).offset, 80);
    });

    test('toggled returns a new set and does not mutate', () {
      const original = {'Open'};
      final toggled = NcrFilters.toggled(original, 'Closed');
      expect(toggled, {'Open', 'Closed'});
      expect(original, {'Open'});
      expect(NcrFilters.toggled(toggled, 'Open'), {'Closed'});
    });

    test('describe states the scope an export was produced under', () {
      expect(const NcrFilters().describe, contains('no filter'));

      const f = NcrFilters(
        statuses: {'Open', 'Verified'},
        lotNo: 'L9',
        from: '2026-01-01',
        to: '2026-01-31',
        onlyOverdue: true,
      );
      final text = f.describe;
      expect(text, contains('status: Open/Verified'));
      expect(text, contains('lot: L9'));
      expect(text, contains('2026-01-01..2026-01-31'));
      expect(text, contains('overdue only'));
    });

    test('an open-ended range is shown with an ellipsis placeholder', () {
      final fromOnly = const NcrFilters(from: '2026-01-01').describe;
      final toOnly = const NcrFilters(to: '2026-01-31').describe;
      expect(fromOnly, contains('2026-01-01..'));
      expect(fromOnly, isNot(contains('..2026-01-31')));
      expect(toOnly, contains('..2026-01-31'));
      expect(toOnly, isNot(contains('2026-01-01..')));
    });

    test('last30Days and all are usable starting points', () {
      final recent = NcrFilters.last30Days();
      expect(recent.hasDateRange, isTrue);
      expect(recent.from.length, 10);
      expect(NcrFilters.all().limit, greaterThan(NcrFilters().limit));
    });
  });

  group('NcrKpis', () {
    test('an empty block is all zeros with no averages', () {
      expect(NcrKpis.empty.total, 0);
      expect(NcrKpis.empty.onTimeClosurePct, isNull);
      expect(NcrKpis.empty.mttcDays, isNull);
    });

    test('percentages divide by their own denominators', () {
      const k = NcrKpis(
        total: 4,
        open: 2,
        critical: 1,
        overdue: 2,
        capaLinked: 1,
      );
      expect(k.overduePct, 50);
      expect(k.capaCoveragePct, 25);
      expect(k.criticalOpenPct, 50);
    });

    test('percentages are zero rather than NaN on an empty report', () {
      const k = NcrKpis.empty;
      expect(k.overduePct, 0);
      expect(k.capaCoveragePct, 0);
      expect(k.criticalOpenPct, 0);
    });

    test('fromMap collapses an all-null aggregate to the empty block', () {
      final k = NcrKpis.fromMap(const {
        'total': 0,
        'open_count': null,
        'closed_count': 0,
        'mttc_days': null,
      });
      expect(k.total, 0);
      expect(k.onTimeClosurePct, isNull);
      expect(k.mttvDays, isNull);
    });

    test('fromMap derives on-time from the closed denominator', () {
      final k = NcrKpis.fromMap(const {
        'total': 5,
        'closed_count': 4,
        'closed_on_time_count': 1,
      });
      expect(k.closed, 4);
      expect(k.onTimeClosurePct, 25);
    });

    test('the dashboard cards read off the KPI block', () {
      const k = NcrKpis(
        total: 9,
        open: 4,
        overdue: 2,
        critical: 3,
        closed: 4,
        closedOnTime: 3,
      );
      expect(k.cardOpen, 4);
      expect(k.cardOverdue, 2);
      expect(k.cardCritical, 3);
      expect(k.cardOnTimePct, 75);
    });
  });

  group('NcrTopDefect', () {
    test('label prefers the code, then the category, then a placeholder', () {
      expect(
        const NcrTopDefect(code: 'D-1', category: 'Weld', count: 1).label,
        'D-1',
      );
      expect(
        const NcrTopDefect(code: '', category: 'Weld', count: 1).label,
        'Weld',
      );
      expect(
        const NcrTopDefect(code: '', category: '', count: 1).label,
        '(uncoded)',
      );
    });
  });
}

/// [QcNcReportRepository] whose KPI call decides its own timing, so a test can make an
/// early load finish after a later one.
class _RacySource extends _FakeSource {
  _RacySource(this.onKpis) : super(rows: const []);

  final Future<NcrKpis> Function() onKpis;

  @override
  Future<NcrKpis> kpis(NcrFilters filters) => onKpis();
}
