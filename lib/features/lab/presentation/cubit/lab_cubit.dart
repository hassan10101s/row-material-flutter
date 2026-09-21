import '../../../../core/state/app_cubit.dart';
import 'lab_state.dart';

/// Lab center coordination: active tab and the test-history refresh tick
/// incremented each time a sample test finishes.
class LabCubit extends AppCubit<LabState> {
  LabCubit() : super(const LabState());

  void setTab(int tab) {
    if (tab == state.tab) return;
    safeEmit(state.copyWith(tab: tab));
  }

  void notifyTestRun() {
    safeEmit(state.copyWith(historyTick: state.historyTick + 1));
  }
}