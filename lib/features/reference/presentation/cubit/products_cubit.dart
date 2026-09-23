import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../lab/data/lab_repo.dart';
import 'products_state.dart';

/// Loads products + analyses for the Products tab of the Reference app.
class ProductsCubit extends AppCubit<ProductsState> {
  ProductsCubit({required this.repo}) : super(const ProductsState());

  final LabRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
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
}