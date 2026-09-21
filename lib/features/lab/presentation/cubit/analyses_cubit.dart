import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/lab_repo.dart';
import 'analyses_state.dart';

/// Loads the analyses catalog and exposes delete for the Analyses tab.
/// Create/edit happen in the self-contained dialog; the tab reloads after a
/// successful save.
class AnalysesCubit extends AppCubit<AnalysesState> {
  AnalysesCubit({required this.repo}) : super(const AnalysesState());

  final LabRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.listAnalyses();
      safeEmit(state.copyWith(loading: false, rows: rows));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  /// Deletes an analysis (soft archive). Errors rethrow so the caller can
  /// surface them via app feedback.
  Future<void> delete(int id) => repo.deleteAnalysis(id);
}