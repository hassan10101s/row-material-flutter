import 'package:equatable/equatable.dart';

import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/routine_repository.dart';

class RoutineListsState extends Equatable {
  const RoutineListsState({
    this.loading = true,
    this.lists = const [],
    this.error,
  });

  final bool loading;
  final List<RoutineList> lists;
  final String? error;

  RoutineListsState copyWith({
    bool? loading,
    List<RoutineList>? lists,
    Object? error = _unset,
  }) => RoutineListsState(
    loading: loading ?? this.loading,
    lists: lists ?? this.lists,
    error: identical(error, _unset) ? this.error : error as String?,
  );

  @override
  List<Object?> get props => [loading, lists, error];
}

const Object _unset = Object();

/// The routine-lists hub: every list with its progress in the current period.
class RoutineListsCubit extends AppCubit<RoutineListsState> {
  RoutineListsCubit({required this.repo}) : super(const RoutineListsState());

  final RoutineListsRepository repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final lists = await repo.listRoutineLists();
      safeEmit(state.copyWith(loading: false, lists: lists));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  Future<void> refresh() => load();

  void clearError() => safeEmit(state.copyWith(error: null));

  Future<bool> deleteList(int templateId) async {
    try {
      await repo.deleteRoutineList(templateId);
      await load();
      return true;
    } on AppError catch (e) {
      safeEmit(state.copyWith(error: e.message));
      return false;
    } catch (e) {
      safeEmit(state.copyWith(error: AppError.friendly(e)));
      return false;
    }
  }

  /// Opens this period's sheet (creating it on first use) and returns its
  /// id, or null when it could not be opened (see [state.error]).
  Future<int?> openTodaySheet(int templateId) async {
    try {
      final sheet = await repo.openPeriodSheet(templateId);
      await load();
      return sheet.inspection.inspectionId;
    } on AppError catch (e) {
      safeEmit(state.copyWith(error: e.message));
      return null;
    } catch (e) {
      safeEmit(state.copyWith(error: AppError.friendly(e)));
      return null;
    }
  }
}
