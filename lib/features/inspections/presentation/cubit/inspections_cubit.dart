import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../reports/domain/report_repository.dart';
import '../../domain/inspection_repository.dart';
import 'inspections_state.dart';

/// Inspections ledger: server-side query/status filters with LIMIT/OFFSET
/// pagination. The DB does the filtering (indexed `idx_inspections_alive` +
/// status/supplier), the cubit only holds the current page.
class InspectionsCubit extends AppCubit<InspectionsState> {
  InspectionsCubit({
    required this.repo,
    required this.reports,
    this.kind = 'raw',
  }) : super(const InspectionsState());

  final InspectionRepository repo;
  final ReportRepository reports;

  /// Inspection kind this register shows (`raw` or `product`).
  final String kind;

  bool get isProduct => kind == 'product';

  Future<void> load({int page = 0}) async {
    safeEmit(state.copyWith(loading: true, error: null, page: page));
    try {
      // Parallel: page rows + filtered total in one round.
      final settled = await Future.wait([
        repo.list(
          query: state.query,
          status: state.status,
          limit: state.pageSize,
          offset: page * state.pageSize,
          orderBy: 'inspection_date DESC, id DESC',
          kind: kind,
        ),
        repo.count(query: state.query, status: state.status, kind: kind),
      ]);
      final rows = settled[0] as List<Map<String, dynamic>>;
      final total = settled[1] as int;
      safeEmit(state.copyWith(
        rows: rows,
        visible: rows,
        total: total,
        page: page,
        loading: false,
      ));
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<void> setPage(int page) async {
    final maxPage = state.total <= 0
        ? 0
        : ((state.total - 1) ~/ state.pageSize).clamp(0, 1 << 31);
    await load(page: page.clamp(0, maxPage));
  }

  Future<void> setQuery(String query) async {
    safeEmit(state.copyWith(query: query));
    await load(page: 0);
  }

  Future<void> setStatus(String status) async {
    safeEmit(state.copyWith(status: status));
    await load(page: 0);
  }

  /// Toggles one inspection id in the bulk-export selection.
  void toggleSelect(int id) {
    final next = Set<int>.of(state.selectedIds);
    if (!next.remove(id)) next.add(id);
    safeEmit(state.copyWith(selectedIds: next));
  }

  /// Selects (`select` true) or deselects all of [ids] — typically the ids
  /// of the current page, driven by the header checkbox.
  void setPageSelection(List<int> ids, bool select) {
    final next = Set<int>.of(state.selectedIds);
    if (select) {
      next.addAll(ids);
    } else {
      next.removeAll(ids);
    }
    safeEmit(state.copyWith(selectedIds: next));
  }

  /// Empties the bulk-export selection (after a successful export, or the
  /// explicit "clear selection" action — mirroring the Vue register).
  void clearSelection() {
    if (state.selectedIds.isEmpty) return;
    safeEmit(state.copyWith(selectedIds: const {}));
  }

  /// Returns the saved report path, or `null` when there is nothing to export.
  /// Export errors are surfaced by the caller (they are not ledger errors).
  /// Note: exports the current server-filtered page (DB-side pagination holds
  /// at most [InspectionsState.pageSize] rows in memory).
  Future<String?> exportFollowUp() async {
    final visible = state.visible;
    if (visible.isEmpty) return null;
    safeEmit(state.copyWith(exporting: true));
    try {
      final doc = await reports.followUpReport([
        for (final r in visible) (r['id'] as num).toInt(),
      ]);
      final file = await reports.saveReport(doc);
      return file.path;
    } finally {
      safeEmit(state.copyWith(exporting: false));
    }
  }
}