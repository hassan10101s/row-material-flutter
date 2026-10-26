import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../../design_system/widgets/app_infinite_list.dart';
import '../../domain/lab_local_repository.dart';
import 'inventory_state.dart';

/// Loads the lab inventory list for the Inventory tab.
///
/// Mobile infinite-scroll model: DB-side search + `LIMIT/OFFSET`, accumulated
/// rows in state. Mutations (add/edit/adjust) run inside the self-contained
/// dialogs; the tab reloads this cubit after a successful save.
class InventoryCubit extends AppCubit<InventoryState> {
  InventoryCubit({required this.repo, this.pageSize = kMobilePageSize})
    : super(const InventoryState()) {
    refreshOnSync(load);
  }

  final LabLocalRepository repo;
  final int pageSize;

  int _token = 0;

  Future<void> load() async {
    final token = ++_token;
    safeEmit(
      state.copyWith(loading: true, clearError: true, clearErrorMore: true),
    );
    try {
      final settled = await Future.wait([
        repo.listInventoryPaged(query: state.query, limit: pageSize, offset: 0),
        repo.countInventory(query: state.query),
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
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    safeEmit(state.copyWith(loadingMore: true, clearErrorMore: true));
    try {
      final more = await repo.listInventoryPaged(
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
}
