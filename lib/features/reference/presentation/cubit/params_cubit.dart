import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/widgets/app_infinite_list.dart';
import '../../domain/parameter_type.dart';
import '../../domain/reference_repository.dart';
import 'params_state.dart';

/// Loads parameters of one type (chemical/physical) plus units (used as
/// unit suggestions on the chemical tab) for the Reference app.
///
/// Mobile infinite-scroll model: DB-side search + `LIMIT/OFFSET` scoped to
/// [parameterType].
class ParamsCubit extends AppCubit<ParamsState> {
  ParamsCubit({
    required this.repo,
    required this.parameterType,
    required this.loadUnits,
    this.pageSize = kMobilePageSize,
  }) : super(const ParamsState());

  final ReferenceRepository repo;
  final String parameterType;
  final bool loadUnits;
  final int pageSize;

  int _token = 0;

  ParamsCubit.chemical({required ReferenceRepository repo})
    : this(
        repo: repo,
        parameterType: ParameterType.chemical.value,
        loadUnits: true,
      );

  ParamsCubit.physical({required ReferenceRepository repo})
    : this(
        repo: repo,
        parameterType: ParameterType.physical.value,
        loadUnits: true,
      );

  Future<void> load() async {
    final token = ++_token;
    safeEmit(
      state.copyWith(loading: true, clearError: true, clearErrorMore: true),
    );
    try {
      final settled = await Future.wait([
        repo.listParametersPaged(
          query: state.query,
          parameterType: parameterType,
          limit: pageSize,
          offset: 0,
        ),
        repo.countParameters(query: state.query, parameterType: parameterType),
      ]);
      final units = loadUnits
          ? await repo.listUnits()
          : const <Map<String, dynamic>>[];
      if (token != _token) return;
      final rows = settled[0] as List<Map<String, dynamic>>;
      final total = settled[1] as int;
      safeEmit(
        state.copyWith(
          loading: false,
          rows: rows,
          units: units,
          total: total,
          hasMore: rows.length >= pageSize,
        ),
      );
    } on AppError catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      if (token != _token) return;
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    safeEmit(state.copyWith(loadingMore: true, clearErrorMore: true));
    try {
      final more = await repo.listParametersPaged(
        query: state.query,
        parameterType: parameterType,
        limit: pageSize,
        offset: state.rows.length,
      );
      safeEmit(
        state.copyWith(
          loadingMore: false,
          rows: [...state.rows, ...more],
          hasMore: more.length >= pageSize,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loadingMore: false, errorMore: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loadingMore: false, errorMore: '$e'));
    }
  }

  Future<void> refresh() => load();

  Future<void> setQuery(String query) async {
    if (query == state.query) return;
    safeEmit(state.copyWith(query: query, rows: const []));
    await load();
  }

  Future<void> upsert(String name, String unit) async {
    await repo.upsertParameter(name, unit, parameterType: parameterType);
  }

  Future<void> delete(String name) async {
    await repo.deleteParameter(name);
  }
}
