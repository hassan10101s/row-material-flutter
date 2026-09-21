import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/lab_repo.dart';
import 'constants_state.dart';

/// Loads the global formula constants and exposes delete for the Constants
/// tab. Create/edit run inside the self-contained dialog; the tab reloads
/// after a successful save.
class ConstantsCubit extends AppCubit<ConstantsState> {
  ConstantsCubit({required this.repo}) : super(const ConstantsState());

  final LabRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.listGlobalConstants();
      safeEmit(state.copyWith(loading: false, rows: rows));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  /// Deletes a global constant. Errors rethrow so the caller can surface
  /// them via app feedback.
  Future<void> delete(int id) => repo.deleteGlobalConstant(id);
}