import '../../data/dashboard_repo.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import 'dashboard_kpis_cubit.dart';
import 'dashboard_state.dart';

/// Loads the dashboard summary, today-KPIs and filter options. The raw KPI map
/// is forwarded to [kpis] so the typed KPI cards can be rebuilt from Equatable
/// state.
class DashboardCubit extends AppCubit<DashboardState> {
  DashboardCubit({
    required this.repo,
    required this.kpis,
  }) : super(const DashboardState());

  final DashboardRepo repo;
  final DashboardKpisCubit kpis;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final results = await Future.wait([
        repo.summary(
          period: state.period,
          materialId: state.selectedMaterial,
          supplier: state.selectedSupplier,
          status: state.selectedStatus,
        ),
        repo.todayKpis(),
        repo.filterOptions(),
      ]);
      kpis.hydrate(results[1] as Map<String, dynamic>);
      safeEmit(state.copyWith(
        loading: false,
        summary: results[0] as Map<String, dynamic>,
        filterOptions: results[2] as DashboardFilterOptions,
      ));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  void setPeriod(String period) {
    if (period == state.period || state.loading) return;
    safeEmit(state.copyWith(period: period));
    load();
  }

  void setMaterial(String material) {
    if (material == state.selectedMaterial || state.loading) return;
    safeEmit(state.copyWith(selectedMaterial: material));
    load();
  }

  void setSupplier(String supplier) {
    if (supplier == state.selectedSupplier || state.loading) return;
    safeEmit(state.copyWith(selectedSupplier: supplier));
    load();
  }

  void setStatus(String status) {
    if (status == state.selectedStatus || state.loading) return;
    safeEmit(state.copyWith(selectedStatus: status));
    load();
  }
}