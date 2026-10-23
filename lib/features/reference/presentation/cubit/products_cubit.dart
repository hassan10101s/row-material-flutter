import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/widgets/app_infinite_list.dart';
import '../../../lab/domain/lab_result_repository.dart';
import 'products_state.dart';

/// Loads products + analyses for the Products tab of the Reference app.
/// Products and analyses are lab *configuration*, so this tab depends on
/// [LabConfigurationRepository] rather than the lab's concrete data class.
///
/// Mobile infinite-scroll model: DB-side search + `LIMIT/OFFSET`.
class ProductsCubit extends AppCubit<ProductsState> {
  ProductsCubit({required this.repo, this.pageSize = kMobilePageSize})
    : super(const ProductsState());

  final LabConfigurationRepository repo;
  final int pageSize;

  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(state.copyWith(loading: true, clearError: true));
    try {
      final settled = await Future.wait([
        repo.listProductsPaged(query: state.query, limit: pageSize, offset: 0),
        repo.countProducts(query: state.query),
        // Analyses picker stays unpaged (small catalog, needed by editor).
        repo.listAnalyses(),
      ]);
      if (token != _token) return;
      final rows = settled[0] as List<Map<String, dynamic>>;
      final total = settled[1] as int;
      final analyses = settled[2] as List<Map<String, dynamic>>;
      safeEmit(
        state.copyWith(
          loading: false,
          rows: rows,
          analyses: analyses,
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
      final more = await repo.listProductsPaged(
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

  Future<Map<String, dynamic>> create({
    required String name,
    String category = '',
    String description = '',
    List<Map<String, dynamic>>? ranges,
    Map<String, dynamic>? physicalReference,
    Map<String, dynamic>? chemicalReference,
  }) async {
    safeEmit(state.copyWith(loading: true, clearError: true));
    try {
      final product = await repo.createProduct(
        name: name,
        category: category,
        description: description,
        ranges: ranges,
        physicalReference: physicalReference,
        chemicalReference: chemicalReference,
      );
      await load();
      return product;
    } on Object {
      safeEmit(state.copyWith(loading: false));
      rethrow;
    }
  }

  Future<Map<String, dynamic>> update(
    int productId,
    Map<String, dynamic> fields,
  ) async {
    safeEmit(state.copyWith(loading: true, clearError: true));
    try {
      final product = await repo.updateProduct(productId, fields);
      await load();
      return product;
    } on Object {
      safeEmit(state.copyWith(loading: false));
      rethrow;
    }
  }

  Future<void> delete(int productId) async {
    safeEmit(state.copyWith(loading: true, clearError: true));
    try {
      await repo.deleteProduct(productId);
      await load();
    } on Object {
      safeEmit(state.copyWith(loading: false));
      rethrow;
    }
  }
}
