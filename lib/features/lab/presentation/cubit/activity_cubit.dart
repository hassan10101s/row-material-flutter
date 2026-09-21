import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/lab_repo.dart';
import 'activity_state.dart';

/// Loads the lab activity log (stock adjustments + consumptions).
class ActivityCubit extends AppCubit<ActivityState> {
  ActivityCubit({required this.repo}) : super(const ActivityState());

  final LabRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final rows = await repo.activityLog(limit: 300);
      safeEmit(state.copyWith(loading: false, rows: rows));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }
}