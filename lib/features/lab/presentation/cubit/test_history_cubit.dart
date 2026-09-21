import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/lab_repo.dart';
import 'test_history_state.dart';

/// Loads the sample-tests history for the Tests tab. Reloaded by the tab when
/// the LabCubit history tick changes (i.e. after a test finishes).
class TestHistoryCubit extends AppCubit<TestHistoryState> {
  TestHistoryCubit({required this.repo}) : super(const TestHistoryState());

  final LabRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.listSampleTests();
      safeEmit(state.copyWith(loading: false, rows: rows));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }
}