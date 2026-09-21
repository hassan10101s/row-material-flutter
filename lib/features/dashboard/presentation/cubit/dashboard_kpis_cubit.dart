import '../../../../core/state/app_cubit.dart';
import 'dashboard_kpis_state.dart';

/// Drives the four KPI cards on the dashboard.
///
/// `hydrate` takes the same raw KPI map the screen already builds (keys:
/// `today_count`, `today_approved`, `today_rejected`, `total_count`) and
/// derives the four typed card values with the exact `?? 0` fallbacks the
/// tuple list used to apply inline — so both render paths agree on zeroed
/// cards until live data lands.
class DashboardKpisCubit extends AppCubit<DashboardKpisState> {
  DashboardKpisCubit() : super(const DashboardKpisState());

  /// Derives typed KPI card values from the raw dashboard KPI map.
  void hydrate(Map<String, dynamic> raw) {
    safeEmit(DashboardKpisState(
      todayInspections: _count(raw['today_count']),
      todayApproved: _count(raw['today_approved']),
      todayRejected: _count(raw['today_rejected']),
      totalCount: _count(raw['total_count']),
    ));
  }

  /// Resets to zeroed cards (loading / no data).
  void reset() => safeEmit(const DashboardKpisState());

  static int _count(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
}
