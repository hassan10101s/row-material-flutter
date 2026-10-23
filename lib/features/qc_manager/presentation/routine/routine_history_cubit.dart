import 'package:equatable/equatable.dart';

import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_dates.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/routine_repository.dart';

export '../../domain/routine_repository.dart' show RoutineHistoryFilters;

/// The general "everything done" log. Every open of the screen is a fresh
/// session: the date range defaults to **today** (each day starts an empty
/// view, the same way the lists reset) and widening it is one tap away.
class RoutineHistoryState extends Equatable {
  const RoutineHistoryState({
    this.loading = true,
    this.log = const [],
    this.filters = const RoutineHistoryFilters(),
    this.error,
  });

  final bool loading;
  final List<RoutineDoneLog> log;
  final RoutineHistoryFilters filters;
  final String? error;

  RoutineHistoryState copyWith({
    bool? loading,
    List<RoutineDoneLog>? log,
    RoutineHistoryFilters? filters,
    Object? error = _unset,
  }) => RoutineHistoryState(
    loading: loading ?? this.loading,
    log: log ?? this.log,
    filters: filters ?? this.filters,
    error: identical(error, _unset) ? this.error : error as String?,
  );

  @override
  List<Object?> get props => [loading, log, filters, error];
}

const Object _unset = Object();

/// Filters + paged rows of the done log over [RoutineListsRepository].
class RoutineHistoryCubit extends AppCubit<RoutineHistoryState> {
  RoutineHistoryCubit({required this.repo})
    : super(const RoutineHistoryState());

  final RoutineListsRepository repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final log = await repo.doneLog(state.filters);
      safeEmit(state.copyWith(loading: false, log: log));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  Future<void> applyFilters(RoutineHistoryFilters filters) async {
    safeEmit(state.copyWith(filters: filters));
    await load();
  }

  /// Clears the list/person/item filters but keeps the today default: an
  /// explicitly *empty* range (all history) is the refresh intent.
  Future<void> clearFilters({bool allTime = false}) => applyFilters(
    allTime
        ? const RoutineHistoryFilters()
        : RoutineHistoryFilters(from: todayIso().substring(0, 10)),
  );

  void clearError() => safeEmit(state.copyWith(error: null));
}
