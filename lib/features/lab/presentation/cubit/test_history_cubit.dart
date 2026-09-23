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
      final results = await Future.wait<Object>([
        repo.listSampleTests(),
        repo.listConsumptionLog(),
        repo.listAnalyses(),
      ]);
      safeEmit(state.copyWith(
        loading: false,
        rows: results[0] as List<Map<String, dynamic>>,
        log: results[1] as List<Map<String, dynamic>>,
        analyses: results[2] as List<Map<String, dynamic>>,
      ));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }
}