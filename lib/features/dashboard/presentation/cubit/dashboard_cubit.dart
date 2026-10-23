import '../../domain/dashboard_kpis.dart';
import '../../domain/dashboard_repository.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import 'dashboard_kpis_cubit.dart';
import 'dashboard_state.dart';

/// Loads the dashboard summary, today-KPIs, filter options and the
/// cross-module KPI bundle. The raw KPI map is forwarded to [kpis] so the
/// typed KPI cards can be rebuilt from Equatable state; the bundle follows
/// in the same load so hero cards and analyst sections never disagree.
class DashboardCubit extends AppCubit<DashboardState> {
  DashboardCubit({required this.repo, required this.kpis})
    : super(const DashboardState());

  final DashboardRepository repo;
  final DashboardKpisCubit kpis;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      // All four sections together: `summary` and `dashboardBundle` share the
      // same filter key, so their `_filtered` reads overlap in time and the
      // repo serves both from one query (single-flight) instead of
      // transferring the full filtered row set across the isolate twice.
      // The bundle stays best-effort via `_safeBundle` — an old mock (or a
      // device missing QC tables) resolves to null and the core load still
      // succeeds, exactly as before.
      final results = await Future.wait([
        repo.summary(
          period: state.period,
          materialId: state.selectedMaterial,
          supplier: state.selectedSupplier,
          status: state.selectedStatus,
        ),
        repo.todayKpis(),
        repo.filterOptions(),
        _safeBundle(),
      ]);
      kpis.hydrate(results[1] as Map<String, dynamic>);
      final bundle = results[3] as DashboardBundle?;
      if (bundle != null) kpis.hydrateBundle(bundle);
      safeEmit(
        state.copyWith(
          loading: false,
          summary: results[0] as Map<String, dynamic>,
          filterOptions: results[2] as DashboardFilterOptions,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  /// Best-effort bundle fetch: never throws (sync or async), so a legacy mock
  /// or a device missing QC tables yields null and the analyst sections stay
  /// zeroed — the core dashboard load is unaffected.
  Future<DashboardBundle?> _safeBundle() async {
    try {
      return await repo.dashboardBundle(
        period: state.period,
        materialId: state.selectedMaterial,
        supplier: state.selectedSupplier,
        status: state.selectedStatus,
      );
    } catch (_) {
      return null;
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

  /// Clears material/supplier/status in one shot — a single reload instead of
  /// three stacked loads.
  void clearFilters() {
    if (state.selectedMaterial == 'ALL' &&
        state.selectedSupplier == 'ALL' &&
        state.selectedStatus == 'ALL') {
      return;
    }
    safeEmit(
      state.copyWith(
        selectedMaterial: 'ALL',
        selectedSupplier: 'ALL',
        selectedStatus: 'ALL',
      ),
    );
    load();
  }
}
