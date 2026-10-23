import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/widgets/app_infinite_list.dart';
import '../../domain/reference_repository.dart';
import 'reference_state.dart';

/// Loads the reference materials catalog for the Materials tab.
///
/// Mobile infinite-scroll model (mirrors the routine history cubit): the DB does
/// the search + `LIMIT/OFFSET`, the cubit holds the accumulated rows.
/// Desktop callers keep working — `load()` resets to the first page and
/// `state.materials` still holds everything loaded so far.
class ReferenceCubit extends AppCubit<ReferenceState> {
  ReferenceCubit({required this.repo, this.pageSize = kMobilePageSize})
    : super(const ReferenceState());

  final ReferenceRepository repo;
  final int pageSize;

  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(
      state.copyWith(loading: true, clearError: true, clearErrorMore: true),
    );
    try {
      final settled = await Future.wait([
        repo.listMaterialsPaged(query: state.query, limit: pageSize, offset: 0),
        repo.countMaterials(query: state.query),
      ]);
      if (token != _token) return;
      final rows = settled[0] as List<Map<String, dynamic>>;
      final total = settled[1] as int;
      safeEmit(
        state.copyWith(
          loading: false,
          materials: rows,
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

  /// Appends the next page. No-op unless the last load filled a page.
  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    safeEmit(state.copyWith(loadingMore: true, clearErrorMore: true));
    try {
      final more = await repo.listMaterialsPaged(
        query: state.query,
        limit: pageSize,
        offset: state.materials.length,
      );
      safeEmit(
        state.copyWith(
          loadingMore: false,
          materials: [...state.materials, ...more],
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
    safeEmit(state.copyWith(query: query, materials: const []));
    await load();
  }

  Future<void> update(
    int id, {
    required String name,
    required String code,
  }) async {
    await repo.updateMaterial(id, materialName: name, materialCode: code);
    await load();
  }

  /// Soft-deletes a material (matches `materials_delete` in lab_vue).
  Future<void> delete(int id) async {
    await repo.deleteMaterial(id);
    await load();
  }
}
