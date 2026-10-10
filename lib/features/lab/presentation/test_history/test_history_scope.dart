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
  ) builder;

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
  }) paged;
  final List<({String key, String label})> chips;
}

class TestHistoryScopeState extends State<TestHistoryScope> {
  final query = TextEditingController();
  String filterMode = 'last24h';
  String specificDate = '';
  String recordLimit = '100';
  String analysisId = '';
  String sourceType = '';
  String chemicalId = '';
  String rangeState = '';
  int page = 1;
  String sortKey = 'tested_at';
  int sortDir = -1;

  static const recordLimits = ['50', '100', '300', '500', '1000', '5000'];

  @override
  void initState() {
    super.initState();
    context.read<TestHistoryCubit>().load();
  }

  @override
  void didUpdateWidget(covariant TestHistoryScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) {
      context.read<TestHistoryCubit>().load();
    }
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  void resetPage() => page = 1;

  /// Called on every keystroke (the controller already holds the text).
  void onQueryChanged() => setState(resetPage);

  void clearQuery() => setState(() {
    query.clear();
    resetPage();
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
      query.clear();
      resetPage();
    });
  }

  void applyFilters({
    required String mode,
    required String date,
    required String analysis,
    required String source,
    required String chemical,
    required String range,
    required String limit,
  }) {
    setState(() {
      filterMode = mode;
      specificDate = date;
      analysisId = analysis;
      sourceType = source;
      chemicalId = chemical;
      rangeState = range;
      recordLimit = limit;
      resetPage();
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
    });
  }

  void setPage(int p) => setState(() => page = p);
  void nextPage() => setState(() => page++);
  void prevPage() => setState(() => page--);

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
      query: query.text,
      chemTestMap: thBuildChemTestMap(log),
    );
    return thSortRows(rows, sortKey, sortDir);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<TestHistoryCubit>().state;
    final chemOptions = thBuildChemicalOptions(state.log);
    final sorted = buildRows(state.rows, state.log);
    final summary = thBuildSummary(sorted);
    final paged = thPagination(sorted, page);
    final chips = thBuildChips(
      filterMode: filterMode,
      specificDate: specificDate,
      analysisId: analysisId,
      sourceType: sourceType,
      chemicalId: chemicalId,
      rangeState: rangeState,
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
