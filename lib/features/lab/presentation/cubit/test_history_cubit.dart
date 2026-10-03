import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/lab_local_repository.dart';
import '../../domain/lab_result_repository.dart';
import 'test_history_state.dart';

/// Loads the sample-tests history for the Tests tab. Reloaded by the tab when
/// the LabCubit history tick changes (i.e. after a test finishes).
///
/// The history pairs a replicated result with a device-local consumption log,
/// so it needs the result and local contracts; the analyses are only read to
/// label the rows.
class TestHistoryCubit extends AppCubit<TestHistoryState> {
  TestHistoryCubit({
    required this.results,
    required this.local,
    required this.config,
  }) : super(const TestHistoryState());

  final LabResultRepository results;
  final LabLocalRepository local;
  final LabConfigurationRepository config;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final loaded = await Future.wait<Object>([
        results.listSampleTests(),
        local.listConsumptionLog(),
        config.listAnalyses(),
      ]);
      safeEmit(
        state.copyWith(
          loading: false,
          rows: loaded[0] as List<Map<String, dynamic>>,
          log: loaded[1] as List<Map<String, dynamic>>,
          analyses: loaded[2] as List<Map<String, dynamic>>,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }
}
