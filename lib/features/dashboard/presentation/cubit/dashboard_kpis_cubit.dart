import '../../../../core/state/app_cubit.dart';
import '../../domain/dashboard_kpis.dart';
import 'dashboard_kpis_state.dart';

/// Drives the KPI cards on the dashboard.
///
/// `hydrate` takes the same raw KPI map the screen already builds (keys:
/// `today_count`, `today_approved`, `today_rejected`, `total_count`) and
/// derives the four typed card values with the exact `?? 0` fallbacks the
/// tuple list used to apply inline — so both render paths agree on zeroed
/// cards until live data lands. `hydrateBundle` carries the cross-module
/// analyst bundle alongside the legacy scalars.
class DashboardKpisCubit extends AppCubit<DashboardKpisState> {
  DashboardKpisCubit() : super(const DashboardKpisState());

  /// Derives typed KPI card values from the raw dashboard KPI map.
  void hydrate(Map<String, dynamic> raw) {
    safeEmit(state.copyWith(
      todayInspections: _count(raw['today_count']),
      todayApproved: _count(raw['today_approved']),
      todayRejected: _count(raw['today_rejected']),
      totalCount: _count(raw['total_count']),
    ));
  }

  /// Stores the full cross-module bundle (volume/quality/lab/QC/NCR/SOP/
  /// goals/inventory/trend). Display-only: no navigation side effects.
  void hydrateBundle(DashboardBundle bundle) {
    safeEmit(state.copyWith(
      bundle: bundle,
      todayInspections: bundle.volume.today,
      todayApproved: bundle.volume.todayApproved,
      todayRejected: bundle.volume.todayRejected,
      totalCount: bundle.volume.total,
    ));
  }

  /// Resets to zeroed cards (loading / no data).
  void reset() => safeEmit(const DashboardKpisState());

  static int _count(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
}
