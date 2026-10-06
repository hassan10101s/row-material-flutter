import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/state/app_cubit.dart';
import '../../domain/ncr_filters.dart';
import '../../domain/ncr_kpis.dart';
import '../../domain/ncr_report_repository.dart';
import '../../domain/ncr_report_row.dart';

/// Read-only state of the NCR report (plan V6_ENHANCED §22.6).
///
/// [filters] is held here rather than inside the screens so the filter drawer,
/// the KPI cards and the table can never disagree about the population - the
/// dashboard is literally a function of the same state the table renders.
@immutable
class QcNcrState extends Equatable {
  const QcNcrState({
    this.filters = const NcrFilters(),
    this.kpis = NcrKpis.empty,
    this.rows = const [],
    this.aging = const [],
    this.topDefects = const [],
    this.repeatRefs = const [],
    this.options = const NcrFilterOptions(),
    this.total = 0,
    this.sortColumn = 'finding_id',
    this.sortDir = 'DESC',
    this.selectedFindingId,
    this.detail,
    this.loading = false,
    this.detailLoading = false,
    this.exporting = false,
    this.error,
    this.detailError,
  });

  final NcrFilters filters;
  final NcrKpis kpis;
  final List<NcrReportRow> rows;
  final List<NcrAgingBucket> aging;
  final List<NcrTopDefect> topDefects;
  final List<NcrRepeatRef> repeatRefs;

  /// Facets for the filter drawer. Empty until the first load succeeds.
  final NcrFilterOptions options;

  /// Rows matching [filters], ignoring the current page.
  final int total;

  /// Active table sort. Held in state rather than in the cubit so a header
  /// cell can render itself as sorted and the sort survives a rebuild.
  final String sortColumn;
  final String sortDir;

  /// Which finding the detail screen is showing, if any.
  final int? selectedFindingId;
  final NcrReportRow? detail;

  final bool loading;
  final bool detailLoading;

  /// True while a PDF/Excel export is being produced.
  final bool exporting;

  final String? error;
  final String? detailError;

  int get page => (filters.offset ~/ filters.limit) + 1;

  int get pageCount => total == 0 ? 1 : (total / filters.limit).ceil();

  bool get hasPrevious => filters.offset > 0;

  bool get hasNext => filters.offset + filters.limit < total;

  bool get hasRows => rows.isNotEmpty;

  /// True when a filter is active, so the screen can offer a reset.
  bool get hasFilters => !filters.isEmpty;

  QcNcrState copyWith({
    NcrFilters? filters,
    NcrKpis? kpis,
    List<NcrReportRow>? rows,
    List<NcrAgingBucket>? aging,
    List<NcrTopDefect>? topDefects,
    List<NcrRepeatRef>? repeatRefs,
    NcrFilterOptions? options,
    int? total,
    String? sortColumn,
    String? sortDir,
    int? selectedFindingId,
    bool clearSelectedFindingId = false,
    NcrReportRow? detail,
    bool clearDetail = false,
    bool? loading,
    bool? detailLoading,
    bool? exporting,
    String? error,
    bool clearError = false,
    String? detailError,
    bool clearDetailError = false,
  }) => QcNcrState(
    filters: filters ?? this.filters,
    kpis: kpis ?? this.kpis,
    rows: rows ?? this.rows,
    aging: aging ?? this.aging,
    topDefects: topDefects ?? this.topDefects,
    repeatRefs: repeatRefs ?? this.repeatRefs,
    options: options ?? this.options,
    total: total ?? this.total,
    sortColumn: sortColumn ?? this.sortColumn,
    sortDir: sortDir ?? this.sortDir,
    selectedFindingId: clearSelectedFindingId
        ? null
        : (selectedFindingId ?? this.selectedFindingId),
    detail: clearDetail ? null : (detail ?? this.detail),
    loading: loading ?? this.loading,
    detailLoading: detailLoading ?? this.detailLoading,
    exporting: exporting ?? this.exporting,
    error: clearError ? null : (error ?? this.error),
    detailError: clearDetailError ? null : (detailError ?? this.detailError),
  );

  @override
  List<Object?> get props => [
    filters,
    kpis,
    rows,
    aging,
    topDefects,
    repeatRefs,
    options,
    total,
    sortColumn,
    sortDir,
    selectedFindingId,
    detail,
    loading,
    detailLoading,
    exporting,
    error,
    detailError,
  ];
}

/// Loads KPIs and rows for one filter set (plan V6_ENHANCED §22.6).
///
/// Every load is all-or-nothing: the cards, the table and the panels are
/// refreshed from a single filter snapshot, so the screen can never show
/// "3 critical" above a table of 40 unrelated rows while two of the five
/// parallel queries are still in flight.
class QcNcrCubit extends AppCubit<QcNcrState> {
  QcNcrCubit(this.repo, {this.pageSize = 50}) : super(const QcNcrState());

  /// The domain contract, not a local seam.
  ///
  /// An earlier version declared a private interface here with the same seven
  /// methods. Dart types nominally, so that bought nothing: the one class that
  /// actually queries SQLite implemented [QcNcReportRepository] and could not
  /// be passed in, meaning the seam was only ever satisfied by test doubles
  /// and production wiring would have failed to compile.
  final QcNcReportRepository repo;
  final int pageSize;

  /// Guards against an older load overwriting a newer one.
  ///
  /// Filter changes fire a new load without cancelling the previous, and SQLite
  /// does not guarantee the order two queries finish in. Without this token the
  /// report can settle on the *older* filter's rows while the drawer shows the
  /// newer one - the filter and the data would permanently disagree.
  int _generation = 0;

  Future<void> load({bool resetPaging = true}) async {
    final generation = ++_generation;
    final filters = resetPaging
        ? state.filters.copyWith(offset: 0, limit: pageSize)
        : state.filters;

    safeEmit(state.copyWith(filters: filters, loading: true, clearError: true));
    try {
      final results = await Future.wait([
        repo.kpis(filters),
        repo.list(
          filters,
          limit: pageSize,
          offset: filters.offset,
          orderBy: state.sortColumn,
          orderDir: state.sortDir,
        ),
        repo.count(filters),
        repo.agingBuckets(filters),
        repo.topDefects(filters, limit: 10),
        repo.repeatByRef(filters, limit: 10),
      ]);
      if (generation != _generation) return;

      safeEmit(
        state.copyWith(
          kpis: results[0] as NcrKpis,
          rows: results[1] as List<NcrReportRow>,
          total: results[2] as int,
          aging: results[3] as List<NcrAgingBucket>,
          topDefects: results[4] as List<NcrTopDefect>,
          repeatRefs: results[5] as List<NcrRepeatRef>,
          loading: false,
        ),
      );
    } on Object catch (e) {
      if (generation != _generation) return;
      // The rows are dropped as well as the error: leaving the previous
      // filter's table under a new set of cards would misattribute NCRs.
      safeEmit(
        state.copyWith(
          loading: false,
          error: '$e',
          rows: const [],
          kpis: NcrKpis.empty,
          aging: const [],
          topDefects: const [],
          repeatRefs: const [],
          total: 0,
        ),
      );
    }
  }

  /// Facets are loaded once: they describe the whole dataset, not the current
  /// filter, so re-reading them on every filter change would be wasted work.
  Future<void> loadOptions() async {
    try {
      final options = await repo.filterOptions();
      safeEmit(state.copyWith(options: options));
    } on Object {
      // A missing facet list degrades the drawer to a free-text box; it is not
      // worth surfacing as an error over the report itself.
    }
  }

  /// Applies a new filter set and reloads from the first page.
  Future<void> applyFilters(NcrFilters filters) async {
    safeEmit(state.copyWith(filters: filters));
    await load();
  }

  Future<void> clearFilters() => applyFilters(const NcrFilters());

  Future<void> toggleFilter(String field, String value) async {
    final f = state.filters;
    final next = switch (field) {
      'status' => f.copyWith(statuses: NcrFilters.toggled(f.statuses, value)),
      'severity' => f.copyWith(
        severities: NcrFilters.toggled(f.severities, value),
      ),
      'type' => f.copyWith(types: NcrFilters.toggled(f.types, value)),
      'category' => f.copyWith(
        categories: NcrFilters.toggled(f.categories, value),
      ),
      'dept' => f.copyWith(depts: NcrFilters.toggled(f.depts, value)),
      'inspector' => f.copyWith(
        inspectorIds: NcrFilters.toggled(f.inspectorIds, value),
      ),
      'assignedTo' => f.copyWith(
        assignedTo: NcrFilters.toggled(f.assignedTo, value),
      ),
      'capaStatus' => f.copyWith(
        capaStatuses: NcrFilters.toggled(f.capaStatuses, value),
      ),
      _ => f,
    };
    if (identical(next, f)) return;
    await applyFilters(next);
  }

  Future<void> setDateRange(String from, String to, {String? field}) =>
      applyFilters(
        state.filters.copyWith(
          from: from,
          to: to,
          dateField: field ?? state.filters.dateField,
        ),
      );

  Future<void> toggleOnlyOverdue() => applyFilters(
    state.filters.copyWith(onlyOverdue: !state.filters.onlyOverdue),
  );

  /// Changing the sort keeps the current page: re-reading page 4 because the
  /// user clicked a column header would throw away their place.
  Future<void> setSort(String column, String direction) async {
    if (state.sortColumn == column && state.sortDir == direction) return;
    safeEmit(state.copyWith(sortColumn: column, sortDir: direction));
    await load(resetPaging: false);
  }

  Future<void> nextPage() async {
    if (!state.hasNext) return;
    safeEmit(
      state.copyWith(
        filters: state.filters.copyWith(
          offset: state.filters.offset + pageSize,
        ),
      ),
    );
    await load(resetPaging: false);
  }

  Future<void> previousPage() async {
    if (!state.hasPrevious) return;
    final offset = (state.filters.offset - pageSize).clamp(0, 1 << 31);
    safeEmit(state.copyWith(filters: state.filters.copyWith(offset: offset)));
    await load(resetPaging: false);
  }

  Future<void> selectFinding(int findingId) async {
    safeEmit(
      state.copyWith(
        selectedFindingId: findingId,
        detailLoading: true,
        clearDetailError: true,
      ),
    );
    try {
      final row = await repo.detail(findingId);
      if (isClosed) return;
      safeEmit(
        state.copyWith(
          detail: row,
          detailLoading: false,
          detailError: row == null
              ? 'Finding $findingId no longer exists'
              : null,
        ),
      );
    } on Object catch (e) {
      if (isClosed) return;
      safeEmit(state.copyWith(detailLoading: false, detailError: '$e'));
    }
  }

  Future<void> clearSelection() async {
    safeEmit(
      state.copyWith(
        clearSelectedFindingId: true,
        clearDetail: true,
        clearDetailError: true,
      ),
    );
  }

  void setExporting(bool value) {
    if (!isClosed) safeEmit(state.copyWith(exporting: value));
  }
}
