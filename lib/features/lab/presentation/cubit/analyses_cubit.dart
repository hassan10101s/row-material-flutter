import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/widgets/app_infinite_list.dart';
import '../../domain/lab_result_repository.dart';
import 'analyses_state.dart';

/// Loads the analyses catalog and exposes delete for the Analyses tab.
/// Create/edit happen in the self-contained dialog; the tab reloads after a
/// successful save.
///
/// Mobile infinite-scroll model: DB-side search + `LIMIT/OFFSET`.
class AnalysesCubit extends AppCubit<AnalysesState> {
  AnalysesCubit({required this.repo, this.pageSize = kMobilePageSize})
    : super(const AnalysesState());

  final LabConfigurationRepository repo;
  final int pageSize;

  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(
      state.copyWith(loading: true, error: null, errorMore: null),
    );
    try {
      final settled = await Future.wait([
        repo.listAnalysesPaged(
          query: state.query,
          limit: pageSize,
          offset: 0,
        ),
        repo.countAnalyses(query: state.query),
      ]);
      if (token != _token) return;
      final rows = settled[0] as List<Map<String, dynamic>>;
      final total = settled[1] as int;
      safeEmit(
        state.copyWith(
          loading: false,
          rows: rows,
          total: total,
          hasMore: rows.length >= pageSize,
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

  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    safeEmit(state.copyWith(loadingMore: true, errorMore: null));
    try {
      final more = await repo.listAnalysesPaged(
        query: state.query,
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

  /// Deletes an analysis (soft archive). Errors rethrow so the caller can
  /// surface them via app feedback.
  Future<void> delete(int id) => repo.deleteAnalysis(id);
}
