import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../lab/domain/lab_result_repository.dart';
import 'products_state.dart';

/// Loads products + analyses for the Products tab of the Reference app.
/// Products and analyses are lab *configuration*, so this tab depends on
/// [LabConfigurationRepository] rather than the lab's concrete data class.
class ProductsCubit extends AppCubit<ProductsState> {
  ProductsCubit({required this.repo}) : super(const ProductsState());

  final LabConfigurationRepository repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, clearError: true));
    try {
      final rows = await repo.listProducts();
      final analyses = await repo.listAnalyses();
      safeEmit(state.copyWith(loading: false, rows: rows, analyses: analyses));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<Map<String, dynamic>> create({
    required String name,
    String category = '',
    String description = '',
    List<Map<String, dynamic>>? ranges,
  }) async {
    safeEmit(state.copyWith(loading: true, clearError: true));
    try {
      final product = await repo.createProduct(
        name: name,
        category: category,
        description: description,
        ranges: ranges,
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
