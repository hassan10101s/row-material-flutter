/// Dashboard analytics.
///
/// ## Why a contract
///
/// `DashboardRepo` is a ~470-line concrete class that builds its aggregates in
/// Dart on top of raw inspection rows. The dashboard is also the screen the
/// per-feature split duplicates most aggressively (it is the landing route), so
/// both variants need to reach the same three reads - and neither should have
/// to import `data/dashboard_repo.dart` to do it.
///
/// Every method aggregates read-only; the dashboard never writes, so there is no
/// queue/audit/permission machinery to model here (unlike the lab contracts).
abstract interface class DashboardRepository {
  /// Inspection analytics for the current filter: decision counts and rates,
  /// per-material and per-supplier breakdowns, monthly buckets, and the latest
  /// inspection.
  Future<Map<String, dynamic>> summary({
    String period,
    String? materialId,
    String? supplier,
    String? status,
  });

  /// The four KPI cards, computed in one pass over today's inspections.
  Future<Map<String, dynamic>> todayKpis();

  /// Dropdown options for the material/supplier/status filter bars.
  Future<DashboardFilterOptions> filterOptions();
}

/// Dropdown options for dashboard filters.
///
/// Lives in the domain because it is part of the state the dashboard renders,
/// not an implementation detail of how the options are queried.
class DashboardFilterOptions {
  final List<Map<String, dynamic>> materials;
  final List<Map<String, dynamic>> suppliers;
  final List<String> statuses;

  const DashboardFilterOptions({
    required this.materials,
    required this.suppliers,
    required this.statuses,
  });
}
