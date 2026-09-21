import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../inspections/data/inspection_repo.dart';
import 'history_state.dart';

/// Loads and filters the inspection history by the active search query.
class HistoryCubit extends AppCubit<HistoryState> {
  HistoryCubit({required this.repo}) : super(const HistoryState());

  final InspectionRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.list(query: state.query);
      safeEmit(state.copyWith(rows: rows, loading: false));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  void setQuery(String query) {
    safeEmit(state.copyWith(query: query));
    load();
  }
}