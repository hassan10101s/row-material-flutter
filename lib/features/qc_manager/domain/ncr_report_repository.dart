import 'ncr_filters.dart';
import 'ncr_kpis.dart';
import 'ncr_report_row.dart';

/// Centralized, read-only NCR projection (plan V6_ENHANCED §22.5).
///
/// Deliberately not part of [QcRepositories] and deliberately not a
/// `DatabaseExecutor` consumer: this view answers questions *across* entities,
/// so it needs joins and aggregation rather than the transaction-scoped,
/// audited, one-row-at-a-time access the write facades provide. There is no
/// mutator on this interface at all - every figure it returns is derived, and a
/// derived value that can be written back stops being evidence.
abstract interface class QcNcReportRepository {
  /// Headline figures for [filters], computed in one aggregation pass.
  ///
  /// Shares its WHERE clause with [list], so the KPI cards and the table can
  /// never describe different populations.
  Future<NcrKpis> kpis(NcrFilters filters);

  /// A page of matching findings, newest first by default.
  ///
  /// [limit] and [offset] default to the values on [filters] so a screen that
  /// has already paged its table does not have to restate the numbers.
  Future<List<NcrReportRow>> list(
    NcrFilters filters, {
    int? limit,
    int? offset,
    String orderBy = 'finding_id',
    String orderDir = 'DESC',
  });

  /// Total matching rows, ignoring paging - the denominator for "page 2 of 9".
  Future<int> count(NcrFilters filters);

  /// One finding with its inspection and CAPA context, or null when it does not
  /// exist or has been deleted.
  Future<NcrReportRow?> detail(int findingId);

  /// The five aging bands of §22.3, zero-filled so a chart never drops a band.
  Future<List<NcrAgingBucket>> agingBuckets(NcrFilters filters);

  /// Most frequent defect codes/categories, for the "top defects" panel.
  Future<List<NcrTopDefect>> topDefects(NcrFilters filters, {int limit = 10});

  /// Lots/batches/references that drew more than one NCR - the repeat-offence
  /// signal the plan asks for. Excludes findings with no reference at all.
  Future<List<NcrRepeatRef>> repeatByRef(NcrFilters filters, {int limit = 10});

  /// Distinct values for the filter pickers, so the drawer does not have to
  /// hard-code the CHECK-constrained vocabularies.
  Future<NcrFilterOptions> filterOptions();
}

/// Facets for the NCR filter drawer.
class NcrFilterOptions {
  const NcrFilterOptions({
    this.statuses = const [],
    this.severities = const [],
    this.types = const [],
    this.categories = const [],
    this.depts = const [],
    this.inspectors = const [],
    this.assignees = const [],
    this.capaStatuses = const [],
  });

  final List<String> statuses;
  final List<String> severities;
  final List<String> types;
  final List<String> categories;
  final List<String> depts;

  /// `id`/`name` pairs for the inspector and assignee pickers, which need both
  /// to show a human label while filtering on the id.
  final List<({String id, String name})> inspectors;
  final List<({String id, String name})> assignees;
  final List<String> capaStatuses;

  bool get isEmpty =>
      statuses.isEmpty &&
      severities.isEmpty &&
      types.isEmpty &&
      categories.isEmpty &&
      depts.isEmpty &&
      inspectors.isEmpty &&
      assignees.isEmpty &&
      capaStatuses.isEmpty;
}
