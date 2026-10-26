import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../core/test_history_logic.dart';
import '../cubit/test_history_cubit.dart';

/// Shared filter/sort/page state for the test-history tab.
///
/// The desktop table and the mobile cards are two views over one state:
/// this scope owns the query controller, the filter draft application,
/// sorting and pagination (all delegated to the pure `th*` helpers in
/// `core/test_history_logic.dart`), and rebuilds its [builder] on change.
/// Variants mutate through the [TestHistoryScopeState] methods — never by
/// copying this logic.
class TestHistoryScope extends StatefulWidget {
  const TestHistoryScope({
    super.key,
    this.refreshTick = 0,
    required this.builder,
  });

  final int refreshTick;

  /// [scope] is the state itself: the builder runs with the scope's own
  /// context, which is NOT below the scope in the tree, so `of(context)`
  /// up there would find nothing. Deeper widgets keep using `of()`.
  final Widget Function(
    BuildContext context,
    TestHistoryScopeState scope,
    TestHistoryData data,
  )
  builder;

  @override
  State<TestHistoryScope> createState() => TestHistoryScopeState();

  static TestHistoryScopeState of(BuildContext context) =>
      context.findAncestorStateOfType<TestHistoryScopeState>()!;
}

/// Precomputed view data for one build of the scope.
class TestHistoryData {
  const TestHistoryData({
    required this.chemOptions,
    required this.sorted,
    required this.summary,
    required this.paged,
    required this.chips,
  });

  final List<({String value, String label})> chemOptions;
  final List<Map<String, dynamic>> sorted;
  final Map<String, int> summary;
  final ({
    int pageCount,
    int start,
    List<Map<String, dynamic>> slice,
    int pageSize,
  })
  paged;
  final List<({String key, String label})> chips;
}

class TestHistoryScopeState extends State<TestHistoryScope> {
  final query = TextEditingController();

  /// سبب القرار filter: `has` shows only the rows whose محضر carries a
  /// decision reason (records without one are hidden; nothing new appears
  /// in the table itself). `''` = all records.
  String reasonState = '';
  String filterMode = 'last24h';
  String specificDate = '';
  String recordLimit = '100';
  String analysisId = '';
  String sourceType = '';
  String chemicalId = '';
  String rangeState = '';
  int page = 1;
  int pageSize = thPageSize;
  String sortKey = 'tested_at';
  int sortDir = -1;

  /// Long-press multi-select: hidden until the first long-press, cleared
  /// explicitly or whenever the visible set changes (filter/query). Kept
  /// across pages so a print can span them; the print resolves keys against
  /// the current rows and ignores stale ones.
  final Set<String> selectedIds = <String>{};

  bool get selecting => selectedIds.isNotEmpty;

  static const recordLimits = ['50', '100', '300', '500', '1000', '5000'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<TestHistoryCubit>().load();
    });
  }

  @override
  void didUpdateWidget(covariant TestHistoryScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.read<TestHistoryCubit>().load();
      });
    }
  }

  Timer? _queryDebounce;

  @override
  void dispose() {
    _queryDebounce?.cancel();
    query.dispose();
    super.dispose();
  }

  void resetPage() => page = 1;

  /// Called on every keystroke (the controller already holds the text).
  /// Perf: debounced 250ms so fast typing filters once instead of running
  /// thBuildChemTestMap + filter + sort + pagination on every character.
  void onQueryChanged() {
    _queryDebounce?.cancel();
    _queryDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        resetPage();
        selectedIds.clear();
      });
    });
  }

  void clearQuery() => setState(() {
    query.clear();
    resetPage();
    selectedIds.clear();
  });

  void setSort(String key) {
    setState(() {
      final next = thNextSort(key, sortKey, sortDir);
      sortKey = next.key;
      sortDir = next.dir;
    });
  }

  String sortMark(String key) {
    if (sortKey != key) return '';
    return sortDir > 0 ? ' ▲' : ' ▼';
  }

  void clearAllFilters() {
    setState(() {
      filterMode = 'all';
      specificDate = '';
      analysisId = '';
      sourceType = '';
      chemicalId = '';
      rangeState = '';
      reasonState = '';
      query.clear();
      resetPage();
      selectedIds.clear();
    });
  }

  void applyFilters({
    required String mode,
    required String date,
    required String analysis,
    required String source,
    required String chemical,
    required String range,
    required String reason,
    required String limit,
  }) {
    setState(() {
      filterMode = mode;
      specificDate = date;
      analysisId = analysis;
      sourceType = source;
      chemicalId = chemical;
      rangeState = range;
      reasonState = reason;
      recordLimit = limit;
      resetPage();
      selectedIds.clear();
    });
  }

  void clearChip(String key) {
    setState(() {
      final next = thClearChip(
        filterMode: filterMode,
        specificDate: specificDate,
        analysisId: analysisId,
        sourceType: sourceType,
        chemicalId: chemicalId,
        rangeState: rangeState,
        reasonState: reasonState,
        query: query.text,
        key: key,
      );
      filterMode = next.filterMode;
      specificDate = next.specificDate;
      analysisId = next.analysisId;
      sourceType = next.sourceType;
      chemicalId = next.chemicalId;
      rangeState = next.rangeState;
      resetPage();
      selectedIds.clear();
    });
  }

  /// Enters selection mode on first use (long-press) and toggles [key].
  /// Leaving zero selected exits the mode and hides the checkboxes again.
  void toggleSelected(String key) {
    setState(() {
      if (!selectedIds.remove(key)) selectedIds.add(key);
    });
  }

  void selectKeys(Iterable<String> keys) {
    setState(() => selectedIds.addAll(keys));
  }

  /// Select-all-on-page checkbox: selects the page when any row is missing,
  /// clears it back when all of it is already selected.
  void toggleSelectAll(Iterable<String> keys) {
    setState(() {
      final list = keys.toList();
      if (list.isNotEmpty && list.every(selectedIds.contains)) {
        selectedIds.removeAll(list);
      } else {
        selectedIds.addAll(list);
      }
    });
  }

  void clearSelection() {
    if (selectedIds.isEmpty) return;
    setState(selectedIds.clear);
  }

  /// Rows (from the current filtered list) behind the selection, in list
  /// order. Stale keys (row filtered out since) are ignored.
  List<Map<String, dynamic>> selectedRows(List<Map<String, dynamic>> rows) => [
    for (final r in rows)
      if (selectedIds.contains(thRowKey(r))) r,
  ];

  void setPage(int p) => setState(() => page = p);
  void nextPage() => setState(() => page++);
  void prevPage() => setState(() => page--);

  void setPageSize(int size) {
    if (size <= 0 || size == pageSize) return;
    setState(() {
      pageSize = size;
      resetPage();
    });
  }

  List<Map<String, dynamic>>? _lastLogIdentity;
  Map<String, Set<String>> _cachedChemMap = const {};

  Map<String, Set<String>> _chemMapFor(List<Map<String, dynamic>> log) {
    // Perf: thBuildChemTestMap is O(log) and log only changes on cubit load.
    // Reuse the map while the list identity is unchanged (same result).
    if (!identical(log, _lastLogIdentity)) {
      _lastLogIdentity = log;
      _cachedChemMap = thBuildChemTestMap(log);
    }
    return _cachedChemMap;
  }

  List<Map<String, dynamic>> buildRows(
    List<Map<String, dynamic>> history,
    List<Map<String, dynamic>> log,
  ) {
    var rows = thFilterModeRows(history, filterMode, specificDate);
    rows = thSlice(rows, thCoerceRecordLimit(recordLimit));
    rows = thApplyRowFilters(
      rows,
      analysisId: analysisId,
      sourceType: sourceType,
      chemicalId: chemicalId,
      rangeState: rangeState,
      reasonState: reasonState,
      query: query.text,
      chemTestMap: _chemMapFor(log),
    );
    return thSortRows(rows, sortKey, sortDir);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TestHistoryCubit>().state;
    final chemOptions = thBuildChemicalOptions(state.log);
    final sorted = buildRows(state.rows, state.log);
    final summary = thBuildSummary(sorted);
    final paged = thPagination(sorted, page, pageSize);
    final chips = thBuildChips(
      filterMode: filterMode,
      specificDate: specificDate,
      analysisId: analysisId,
      sourceType: sourceType,
      chemicalId: chemicalId,
      rangeState: rangeState,
      reasonState: reasonState,
      analyses: state.analyses,
      chemicalOptions: chemOptions,
    );
    return widget.builder(
      context,
      this,
      TestHistoryData(
        chemOptions: chemOptions,
        sorted: sorted,
        summary: summary,
        paged: paged,
        chips: chips,
      ),
    );
  }
}
