import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/reference_repo.dart';
import 'units_state.dart';

/// Loads the lab units catalog for the Units settings tab.
class UnitsCubit extends AppCubit<UnitsState> {
  UnitsCubit({required this.repo}) : super(const UnitsState());

  final ReferenceRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.listUnits();
      safeEmit(state.copyWith(loading: false, rows: rows));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<void> upsert(
    String symbol, {
    String name = '',
    String dimension = '',
  }) =>
      repo.upsertUnit(symbol, name: name, dimension: dimension);

  Future<void> delete(String symbol) => repo.deleteUnit(symbol);
}