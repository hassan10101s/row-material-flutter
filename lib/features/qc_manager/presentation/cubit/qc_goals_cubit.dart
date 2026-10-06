import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/qc_enums.dart';
import '../../domain/qc_goal.dart';
import '../../domain/qc_repositories.dart';

/// How many goals one page asks for. The repository has no count for goals, so
/// the list is "load another page while the last one came back full" rather
/// than a page/skip pair - see [QcGoalsCubit.loadMore].
const qcGoalsPageSize = 50;

/// The filter scope behind the goals list.
///
/// Kept as one value object (rather than loose fields on the state) so the
/// "more" link from the dashboard and the filter drawer in the list screen
/// describe a query identically.
class QcGoalFilters extends Equatable {
  const QcGoalFilters({
    this.statuses = const {},
    this.dept = '',
    this.ownerId = '',
    this.assigneeId = '',
    this.dueFrom = '',
    this.dueTo = '',
    this.overdueOnly = false,
  });

  final Set<String> statuses;
  final String dept;

  /// Goals whose owner is this uid.
  final String ownerId;

  /// Goals this uid is assigned to, through `qc_goal_assignments`.
  ///
  /// Not a [QcGoalFilters] member the repository understands: [QcGoalsCubit]
  /// resolves it to a set of goal ids and filters in memory, because the goals
  /// table has no assignee column and the assignments table has no status.
  final String assigneeId;
  final String dueFrom;
  final String dueTo;
  final bool overdueOnly;

  bool get isEmpty =>
      statuses.isEmpty &&
      dept.isEmpty &&
      ownerId.isEmpty &&
      assigneeId.isEmpty &&
      dueFrom.isEmpty &&
      dueTo.isEmpty &&
      !overdueOnly;

  int get activeCount =>
      (statuses.isEmpty ? 0 : 1) +
      (dept.isEmpty ? 0 : 1) +
      (ownerId.isEmpty ? 0 : 1) +
      (assigneeId.isEmpty ? 0 : 1) +
      (dueFrom.isEmpty && dueTo.isEmpty ? 0 : 1) +
      (overdueOnly ? 1 : 0);

  QcGoalFilters copyWith({
    Set<String>? statuses,
    String? dept,
    String? ownerId,
    String? assigneeId,
    String? dueFrom,
    String? dueTo,
    bool? overdueOnly,
  }) => QcGoalFilters(
    statuses: statuses ?? this.statuses,
    dept: dept ?? this.dept,
    ownerId: ownerId ?? this.ownerId,
    assigneeId: assigneeId ?? this.assigneeId,
    dueFrom: dueFrom ?? this.dueFrom,
    dueTo: dueTo ?? this.dueTo,
    overdueOnly: overdueOnly ?? this.overdueOnly,
  );

  @override
  List<Object?> get props => [
    // Sorted so two filters holding the same statuses compare equal.
    (statuses.toList()..sort()),
    dept,
    ownerId,
    assigneeId,
    dueFrom,
    dueTo,
    overdueOnly,
  ];
}

/// Counters for the goal list's summary strip.
///
/// These are derived from the rows already loaded rather than from extra
/// aggregate queries: the list is a management screen over one scope, and a
/// counter that disagreed with the rows under it would be worse than none.
class QcGoalSummary extends Equatable {
  const QcGoalSummary({
    this.total = 0,
    this.active = 0,
    this.overdue = 0,
    this.completed = 0,
  });

  final int total;
  final int active;
  final int overdue;
  final int completed;

  factory QcGoalSummary.from(List<QcGoal> goals) => QcGoalSummary(
    total: goals.length,
    active: goals.where((g) => g.status == QcGoalStatus.active).length,
    overdue: goals.where((g) => g.isOverdue).length,
    completed: goals.where((g) => g.isCompleted).length,
  );

  @override
  List<Object?> get props => [total, active, overdue, completed];
}

@immutable
class QcGoalsState extends Equatable {
  const QcGoalsState({
    this.goals = const [],
    this.filters = const QcGoalFilters(),
    this.summary = const QcGoalSummary(),
    this.loading = false,
    this.loadingMore = false,
    this.saving = false,
    this.error,
    this.saved = false,
    this.hasMore = false,
    this.deptSuggestions = const [],
    this.siteSuggestions = const [],
    this.unitSuggestions = const [],
    this.titleSuggestions = const [],
    this.userSuggestions = const [],
  });

  final List<QcGoal> goals;
  final QcGoalFilters filters;
  final QcGoalSummary summary;
  final bool loading;
  final bool loadingMore;
  final bool saving;
  final String? error;

  /// Set once by a successful create/edit so the form can pop itself.
  final bool saved;

  /// True while a full page came back, so there is probably another one.
  final bool hasMore;

  final List<String> deptSuggestions;
  final List<String> siteSuggestions;
  final List<String> unitSuggestions;
  final List<String> titleSuggestions;
  final List<MapEntry<String, String>> userSuggestions;

  QcGoalsState copyWith({
    List<QcGoal>? goals,
    QcGoalFilters? filters,
    QcGoalSummary? summary,
    bool? loading,
    bool? loadingMore,
    bool? saving,
    Object? error = _unset,
    bool? saved,
    bool? hasMore,
    List<String>? deptSuggestions,
    List<String>? siteSuggestions,
    List<String>? unitSuggestions,
    List<String>? titleSuggestions,
    List<MapEntry<String, String>>? userSuggestions,
  }) => QcGoalsState(
    goals: goals ?? this.goals,
    filters: filters ?? this.filters,
    summary: summary ?? this.summary,
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    saving: saving ?? this.saving,
    error: identical(error, _unset) ? this.error : error as String?,
    saved: saved ?? this.saved,
    hasMore: hasMore ?? this.hasMore,
    deptSuggestions: deptSuggestions ?? this.deptSuggestions,
    siteSuggestions: siteSuggestions ?? this.siteSuggestions,
    unitSuggestions: unitSuggestions ?? this.unitSuggestions,
    titleSuggestions: titleSuggestions ?? this.titleSuggestions,
    userSuggestions: userSuggestions ?? this.userSuggestions,
  );

  @override
  List<Object?> get props => [
    goals,
    filters,
    summary,
    loading,
    loadingMore,
    saving,
    error,
    saved,
    hasMore,
    deptSuggestions,
    siteSuggestions,
    unitSuggestions,
    titleSuggestions,
    userSuggestions,
  ];
}

const _unset = Object();

/// Drives the goals list: filtering, paging, and the create/edit flow that
/// shares this screen's repository.
///
/// The repository takes a single `status`, so a multi-select on status is
/// resolved into one call per status and merged here. Two statuses is the
/// common case and one extra query is cheaper than a new repository contract.
class QcGoalsCubit extends AppCubit<QcGoalsState> {
  QcGoalsCubit({required this.repo, QcGoalFilters? initialFilters})
    : super(
        QcGoalsState(
          filters: initialFilters ?? const QcGoalFilters(),
          loading: true,
        ),
      );

  final QcGoalRepository repo;

  /// Bumped on every filter change. A load whose token is stale is dropped
  /// rather than allowed to overwrite the newer scope's rows.
  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    // `saved` is deliberately left alone: a successful save emits it and then
    // reloads, and clearing it here would eat the signal the form listens for.
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final goals = await _query(state.filters);
      if (token != _token) return;
      final deptSuggestions = <String>{};
      final siteSuggestions = <String>{};
      final unitSuggestions = <String>{};
      final titleSuggestions = <String>{};
      final userSuggestionsMap = <String, String>{};
      for (final g in goals) {
        if (g.dept.isNotEmpty) deptSuggestions.add(g.dept);
        if (g.site.isNotEmpty) siteSuggestions.add(g.site);
        if (g.targetUnit.isNotEmpty) unitSuggestions.add(g.targetUnit);
        if (g.title.isNotEmpty) titleSuggestions.add(g.title);
        if (g.ownerId.isNotEmpty) {
          userSuggestionsMap[g.ownerId] = g.ownerName.isNotEmpty ? g.ownerName : g.ownerId;
        }
      }
      safeEmit(
        state.copyWith(
          goals: goals,
          summary: QcGoalSummary.from(goals),
          loading: false,
          hasMore: goals.length >= qcGoalsPageSize,
          deptSuggestions: deptSuggestions.toList()..sort(),
          siteSuggestions: siteSuggestions.toList()..sort(),
          unitSuggestions: unitSuggestions.toList()..sort(),
          titleSuggestions: titleSuggestions.toList()..sort(),
          userSuggestions: userSuggestionsMap.entries.toList()
            ..sort((a, b) => a.value.compareTo(b.value)),
        ),
      );
    } on AppError catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  /// Appends the next page. No-op unless the last load filled a page, so a
  /// screen that reached the end stops asking.
  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    safeEmit(state.copyWith(loadingMore: true, error: null));
    try {
      final more = await _query(
        state.filters,
        offset: state.goals.length,
        limit: qcGoalsPageSize,
      );
      final merged = [...state.goals, ...more];
      safeEmit(
        state.copyWith(
          goals: merged,
          summary: QcGoalSummary.from(merged),
          loadingMore: false,
          hasMore: more.length >= qcGoalsPageSize,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loadingMore: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loadingMore: false, error: '$e'));
    }
  }

  Future<void> refresh() => load();

  Future<void> applyFilters(QcGoalFilters filters) async {
    safeEmit(state.copyWith(filters: filters, goals: const []));
    await load();
  }

  /// Toggles one status in the multi-select and reloads.
  Future<void> toggleStatus(String status) async {
    final next = {...state.filters.statuses};
    if (!next.remove(status)) next.add(status);
    await applyFilters(state.filters.copyWith(statuses: next));
  }

  Future<void> clearFilters() => applyFilters(const QcGoalFilters());

  /// Creates a goal and refreshes the list so the new row is in scope.
  Future<void> createGoal(QcGoal goal) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.createGoal(goal);
      safeEmit(state.copyWith(saving: false, saved: true));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> saveGoal(QcGoal goal) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.saveGoal(goal);
      safeEmit(state.copyWith(saving: false, saved: true));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  Future<void> deleteGoal(int goalId) async {
    safeEmit(state.copyWith(saving: true, error: null));
    try {
      await repo.deleteGoal(goalId);
      safeEmit(state.copyWith(saving: false, saved: true));
      await load();
    } on AppError catch (e) {
      safeEmit(state.copyWith(saving: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(saving: false, error: '$e'));
    }
  }

  void clearError() => safeEmit(state.copyWith(error: null));

  void clearSaved() => safeEmit(state.copyWith(saved: false));

  /// Runs the filter scope, then applies the parts SQL cannot express.
  ///
  /// Two honest compromises, both because `qc_goals` has no such columns:
  /// a multi-status filter costs one query per status, and an assignee filter
  /// resolves to the assignee's goal ids and narrows the page in memory.
  Future<List<QcGoal>> _query(
    QcGoalFilters filters, {
    int offset = 0,
    int limit = qcGoalsPageSize,
  }) async {
    List<QcGoal> rows;
    if (filters.statuses.isEmpty) {
      rows = await repo.listGoals(
        status: '',
        dept: filters.dept,
        ownerId: filters.ownerId,
        overdueOnly: filters.overdueOnly,
        limit: limit,
        offset: offset,
      );
    } else {
      final statuses = filters.statuses.toList()..sort();
      final batches = await Future.wait(
        statuses.map(
          (s) => repo.listGoals(
            status: s,
            dept: filters.dept,
            ownerId: filters.ownerId,
            overdueOnly: filters.overdueOnly,
            limit: limit,
            offset: offset,
          ),
        ),
      );
      final merged = <int, QcGoal>{};
      for (final batch in batches) {
        for (final goal in batch) {
          merged[goal.goalId ?? 0] = goal;
        }
      }
      rows = merged.values.toList()
        ..sort((a, b) => a.dueDate.compareTo(b.dueDate));
    }

    if (filters.assigneeId.isNotEmpty) {
      rows = await _narrowToAssignee(rows, filters.assigneeId);
    }
    if (filters.dueFrom.isNotEmpty) {
      rows = rows
          .where((g) => g.dueDate.compareTo(filters.dueFrom) >= 0)
          .toList();
    }
    if (filters.dueTo.isNotEmpty) {
      rows = rows
          .where((g) => g.dueDate.compareTo(filters.dueTo) <= 0)
          .toList();
    }
    return rows;
  }

  /// Turns "assigned to X" into "these goal ids", then keeps only those.
  Future<List<QcGoal>> _narrowToAssignee(
    List<QcGoal> candidates,
    String assigneeId,
  ) async {
    final ids = <int>{};
    for (final goal in candidates) {
      final id = goal.goalId;
      if (id == null) continue;
      final assignments = await repo.listAssignments(id);
      if (assignments.any((a) => a.assigneeId == assigneeId)) ids.add(id);
    }
    return candidates.where((g) => ids.contains(g.goalId)).toList();
  }
}
