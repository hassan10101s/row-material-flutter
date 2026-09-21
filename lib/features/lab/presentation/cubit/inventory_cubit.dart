import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/lab_repo.dart';
import 'inventory_state.dart';

/// Loads the lab inventory list for the Inventory tab.
/// Mutations (add/edit/adjust) run inside the self-contained dialogs; the
/// tab reloads this cubit after a successful save.
class InventoryCubit extends AppCubit<InventoryState> {
  InventoryCubit({required this.repo}) : super(const InventoryState());

  final LabRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.listInventory();
      safeEmit(state.copyWith(loading: false, rows: rows));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }
}