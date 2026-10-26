import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/qc_custom_table.dart';
import '../../domain/qc_repositories.dart';

/// How many records one page asks for. The repository is keyset-paged over
/// `row_id DESC`, so the list is "load another page while the last one came
/// back full" rather than a page/skip pair - see [QcTableRowsCubit.loadMore].
const qcCustomRowsPageSize = 50;

/// The in-memory filter scope over one custom table's records.
///
/// SQL does not get these filters: record values live in `values_json` keyed
/// by column `remote_id`, so rows are loaded keyset-paged (newest first) and
/// narrowed here. That keeps the repository contract to one listing method
/// and lets filters mix columns of any types.
@immutable
class QcCustomRowFilters extends Equatable {
  const QcCustomRowFilters({
    this.search = '',
    this.numberMin = const {},
    this.numberMax = const {},
    this.dateFrom = const {},
    this.dateTo = const {},
    this.textIn = const {},
  });

  final String search;

  /// Per-column bounds, keyed by the column's `remote_id`. Number columns
  /// get numeric bounds, date columns day-precision ISO bounds (`YYYY-MM-DD`,
  /// compared against the row's stored ISO string by day prefix), text
  /// columns a case-insensitive substring.
  final Map<String, num> numberMin;
  final Map<String, num> numberMax;
  final Map<String, String> dateFrom;
  final Map<String, String> dateTo;
  final Map<String, String> textIn;

  int get activeCount =>
      (search.isEmpty ? 0 : 1) +
      numberMin.length +
      numberMax.length +
      dateFrom.length +
      dateTo.length +
      textIn.length;

  bool get isEmpty => search.isEmpty && activeCount == 0;

  QcCustomRowFilters copyWith({
    String? search,
    Map<String, num>? numberMin,
    Map<String, num>? numberMax,
    Map<String, String>? dateFrom,
    Map<String, String>? dateTo,
    Map<String, String>? textIn,
  }) => QcCustomRowFilters(
    search: search ?? this.search,
    numberMin: numberMin ?? this.numberMin,
    numberMax: numberMax ?? this.numberMax,
    dateFrom: dateFrom ?? this.dateFrom,
    dateTo: dateTo ?? this.dateTo,
    textIn: textIn ?? this.textIn,
  );

  @override
  List<Object?> get props => [
    search,
    numberMin,
    numberMax,
    dateFrom,
    dateTo,
    textIn,
  ];
}

/// The summary strip of a records screen: what is loaded, what survives the
/// filters, and the freshest recording date among the visible ones.
@immutable
class QcRowsSummary extends Equatable {
  const QcRowsSummary({this.loaded = 0, this.visible = 0, this.latestAt = ''});

  final int loaded;
  final int visible;
  final String latestAt;

  @override
  List<Object?> get props => [loaded, visible, latestAt];
}

@immutable
class QcTableRowsState extends Equatable {
  const QcTableRowsState({
    this.table,
    this.fields = const [],
    this.rows = const [],
    this.filters = const QcCustomRowFilters(),
    this.summary = const QcRowsSummary(),
    this.selectedIds = const {},
    this.loading = false,
    this.loadingMore = false,
    this.saving = false,
    this.error,
    this.saved = false,
    this.hasMore = false,
  });

  final QcCustomTable? table;
  final List<QcCustomTableField> fields;

  /// Stored order: newest first (keyset over `row_id DESC`).
  final List<QcCustomTableRow> rows;
  final QcCustomRowFilters filters;
  final QcRowsSummary summary;

  /// Bulk action pick (the register's checkbox column): local `row_id`s of
  /// the selected records. Export reads through it; every reload prunes it
  /// against the rows still known so a vanished record never lingers.
  final Set<int> selectedIds;
  final bool loading;
  final bool loadingMore;
  final bool saving;

  /// Transient error (failed load / write / validation).
  final String? error;

  /// Set once by a successful add/save/delete so the record form can pop.
  final bool saved;

  /// True while the last full page came back, so there is probably another.
  final bool hasMore;

  /// The rows surviving [filters], in stored order.
  List<QcCustomTableRow> visibleRows() =>
      filters.isEmpty ? rows : rows.where((r) => _matches(r, filters)).toList();

  static bool _matches(QcCustomTableRow row, QcCustomRowFilters f) {
    final values = row.values;
    for (final e in f.numberMin.entries) {
      final v = values[e.key];
      if (v is! num || v < e.value) return false;
    }
    for (final e in f.numberMax.entries) {
      final v = values[e.key];
      if (v is! num || v > e.value) return false;
    }
    for (final e in f.dateFrom.entries) {
      final day = _dayOf(values[e.key]);
      final bound = _dayOf(e.value);
      if (bound == null) continue;
      if (day == null || day.compareTo(bound) < 0) return false;
    }
    for (final e in f.dateTo.entries) {
      final day = _dayOf(values[e.key]);
      final bound = _dayOf(e.value);
      if (bound == null) continue;
      if (day == null || day.compareTo(bound) > 0) return false;
    }
    for (final e in f.textIn.entries) {
      final v = values[e.key];
      if (v is! String ||
          !v.toLowerCase().contains(e.value.trim().toLowerCase())) {
        return false;
      }
    }
    if (f.search.isNotEmpty) {
      final q = f.search.toLowerCase();
      final inNote = row.note.toLowerCase().contains(q);
      final inValues = values.entries.any(
        (v) => '${v.value}'.toLowerCase().contains(q),
      );
      if (!inNote && !inValues) return false;
    }
    return true;
  }

  static String? _dayOf(Object? v) {
    final s = '$v';
    return s.length >= 10 ? s.substring(0, 10) : (s.isEmpty ? null : s);
  }

  QcTableRowsState copyWith({
    QcCustomTable? table,
    List<QcCustomTableField>? fields,
    List<QcCustomTableRow>? rows,
    QcCustomRowFilters? filters,
    QcRowsSummary? summary,
    Set<int>? selectedIds,
    bool? loading,
    bool? loadingMore,
    bool? saving,
    Object? error = _unset,
    bool? saved,
    bool? hasMore,
  }) => QcTableRowsState(
    table: table ?? this.table,
    fields: fields ?? this.fields,
    rows: rows ?? this.rows,
    filters: filters ?? this.filters,
    summary: summary ?? this.summary,
    selectedIds: selectedIds ?? this.selectedIds,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    saving: saving ?? this.saving,
    error: identical(error, _unset) ? this.error : error as String?,
    saved: saved ?? this.saved,
    hasMore: hasMore ?? this.hasMore,
  );

  @override
  List<Object?> get props => [
    table,
    fields,
    rows,
    filters,
    summary,
    selectedIds,
    loading,
    loadingMore,
    saving,
    error,
    saved,
    hasMore,
  ];
}

const _unset = Object();

/// Drives one custom table's records screen: the definition and its columns,
/// the keyset-paged records, and the in-memory filter scope over them. One
/// cubit per open table (see the DI `registerFactoryParam` for its keying).
class QcTableRowsCubit extends AppCubit<QcTableRowsState> {
  QcTableRowsCubit({required this.repo, required this.tableId})
    : super(const QcTableRowsState(loading: true)) {
    refreshOnSync(load);
  }

  final QcCustomTablesRepository repo;
  final int tableId;

  /// Bumped on every scope-bearing load so a stale page (the user filtered
  /// or another device reconciled columns mid-flight) cannot overwrite the
  /// newer view.
  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final bundle = await repo.getTableBundle(tableId);
      if (bundle == null) {
        if (token != _token) return;
        safeEmit(
          state.copyWith(
            loading: false,
            error: AppText.t('الجدول غير', 'This table no longer exists'),
          ),
        );
        return;
      }
      final rows = await repo.listRows(
        tableId,
        limit: qcCustomRowsPageSize,
        afterRowId: 0,
      );
      if (token != _token) return;
      safeEmit(
        state.copyWith(
          table: bundle.table,
          fields: bundle.fields,
          rows: rows,
          loading: false,
          hasMore: rows.length >= qcCustomRowsPageSize,
          summary: _summarize(rows.length, rows, state.filters),
        ),
      );
      _pruneSelection();
    } on AppError catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  /// Appends the next page with a keyset over `row_id DESC`. No-op unless
  /// the last load filled a page, so a screen at the end stops asking.
  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    final last = state.rows.lastOrNull?.rowId;
    if (last == null) return;
    safeEmit(state.copyWith(loadingMore: true, error: null));
    try {
      final more = await repo.listRows(
        tableId,
        limit: qcCustomRowsPageSize,
        afterRowId: last,
      );
      final merged = [...state.rows, ...more];
      safeEmit(
        state.copyWith(
          rows: merged,
          loadingMore: false,
          hasMore: more.length >= qcCustomRowsPageSize,
          summary: _summarize(merged.length, merged, state.filters),
        ),
      );
      _pruneSelection();
    } on AppError catch (e) {
      safeEmit(state.copyWith(loadingMore: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loadingMore: false, error: AppError.friendly(e)));
    }
  }

  // ── Bulk selection (export) ─────────────────────────────────────────

  void toggleSelect(int rowId) {
    final next = Set<int>.from(state.selectedIds);
    if (next.remove(rowId)) {
      return safeEmit(state.copyWith(selectedIds: next));
    }
    next.add(rowId);
    safeEmit(state.copyWith(selectedIds: next));
  }

  /// Selects or clears the whole visible scope (the header checkbox).
  void setAllSelection(Iterable<int> ids, bool select) {
    if (select) {
      final union = Set<int>.from(state.selectedIds)..addAll(ids);
      return safeEmit(state.copyWith(selectedIds: union));
    }
    final diff = Set<int>.from(state.selectedIds)..removeAll(ids);
    safeEmit(state.copyWith(selectedIds: diff));
  }

  void clearSelection() => safeEmit(state.copyWith(selectedIds: const <int>{}));

  /// Drops picked ids the reload no longer knows (deleted on another
  /// device / filtered page refresh), so a stale pick cannot export.
  void _pruneSelection() {
    final known = {for (final r in state.rows) r.rowId!};
    final pruned = state.selectedIds.where(known.contains).toSet();
    if (pruned.length != state.selectedIds.length) {
      safeEmit(state.copyWith(selectedIds: pruned));
    }
  }

  Future<void> refresh() => load();

  /// Applies the in-memory scope. No reload: filters narrow what is already
  /// on screen, so typing stays instant even offline.
  void applyFilters(QcCustomRowFilters filters) {
    safeEmit(
      state.copyWith(
        filters: filters,
        summary: _summarize(state.rows.length, state.rows, filters),
      ),
    );
  }

  void clearFilters() => applyFilters(const QcCustomRowFilters());

  Future<void> addRow(QcCustomTableRow row) => _write(() async {
    await repo.addRow(row);
  });

  Future<void> saveRow(QcCustomTableRow row) => _write(() async {
    await repo.saveRow(row);
  });

  Future<void> deleteRow(int rowId) => _write(() async {
    await repo.deleteRow(rowId);
  });

  Future<void> _write(Future<void> Function() action) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await action();
      safeEmit(state.copyWith(saving: false, saved: true));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: AppError.friendly(e)));
    }
  }

  void clearError() => safeEmit(state.copyWith(error: null));

  void clearSaved() => safeEmit(state.copyWith(saved: false));

  static QcRowsSummary _summarize(
    int loaded,
    List<QcCustomTableRow> rows,
    QcCustomRowFilters filters,
  ) {
    final visible = filters.isEmpty
        ? rows
        : rows.where((r) => QcTableRowsState._matches(r, filters)).toList();
    final latest = visible.isEmpty
        ? ''
        : visible
              .map((r) => r.recordedAt)
              .reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
    return QcRowsSummary(
      loaded: loaded,
      visible: visible.length,
      latestAt: latest,
    );
  }
}
