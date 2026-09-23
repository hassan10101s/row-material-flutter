import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/reference_repo.dart';
import 'params_state.dart';

/// Loads parameters of one type (chemical/physical) plus units (used as
/// unit suggestions on the chemical tab) for the Reference app.
class ParamsCubit extends AppCubit<ParamsState> {
  ParamsCubit({
    required this.repo,
    required this.parameterType,
    required this.loadUnits,
  }) : super(const ParamsState());

  final ReferenceRepo repo;
  final String parameterType;
  final bool loadUnits;

  ParamsCubit.chemical({required ReferenceRepo repo})
      : this(repo: repo, parameterType: 'chemical', loadUnits: true);

  ParamsCubit.physical({required ReferenceRepo repo})
      : this(repo: repo, parameterType: 'physical', loadUnits: false);

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.listParameters(parameterType: parameterType);
      final units =
          loadUnits ? await repo.listUnits() : const <Map<String, dynamic>>[];
      safeEmit(state.copyWith(loading: false, rows: rows, units: units));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<void> upsert(String name, String unit) async {
    await repo.upsertParameter(name, unit, parameterType: parameterType);
  }

  Future<void> delete(String name) async {
    await repo.deleteParameter(name);
  }
}