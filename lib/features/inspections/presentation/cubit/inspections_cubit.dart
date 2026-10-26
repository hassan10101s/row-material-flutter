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
    // Phones pass `kMobileMaxPageSize` (25); desktop keeps the default (200).
    // A constructor parameter — not a `FormFactor` read — so the cubit stays
    // platform-agnostic and tests keep the old default.
    int initialPageSize = 200,
    // Deep-link seeds (dashboard drill-down): applied once at construction,
    // before the first load. Empty/null filters are inert.
    String initialStatus = '',
    String initialSupplier = '',
    int? initialMaterialId,
    String initialMaterialName = '',
    String initialDateFrom = '',
    String initialDateTo = '',
  }) : super(
         InspectionsState(
           pageSize: initialPageSize,
           status: initialStatus,
           supplier: initialSupplier,
           materialId: initialMaterialId,
           materialName: initialMaterialName,
           dateFrom: initialDateFrom,
           dateTo: initialDateTo,
         ),
       ) {
    refreshOnSync(() => load(page: state.page));
  }

  final InspectionRepository repo;
  final ReportRepository reports;

  /// Inspection kind this register shows (`raw` or `product`).
  final String kind;

  bool get isProduct => kind == 'product';

  Future<void> load({int page = 0}) async {
    safeEmit(state.copyWith(loading: true, error: null, page: page));
    try {
      // Parallel: page rows + filtered total in one round. The shared
      // `materialId` filters `material_id` on the raw register and
      // `product_id` on the product register (each cubit owns one kind).
      final settled = await Future.wait([
        repo.list(
          query: state.query,
          status: state.status,
          reason: state.reason,
          limit: state.pageSize,
          offset: page * state.pageSize,
          orderBy: 'inspection_date DESC, id DESC',
          kind: kind,
          dateFrom: state.dateFrom,
          dateTo: state.dateTo,
          supplier: state.supplier,
          materialId: isProduct ? null : state.materialId,
          productId: isProduct ? state.materialId : null,
        ),
        repo.count(
          query: state.query,
          status: state.status,
          reason: state.reason,
          kind: kind,
          dateFrom: state.dateFrom,
          dateTo: state.dateTo,
          supplier: state.supplier,
          materialId: isProduct ? null : state.materialId,
          productId: isProduct ? state.materialId : null,
        ),
      ]);
      final rows = settled[0] as List<Map<String, dynamic>>;
      final total = settled[1] as int;
      safeEmit(
        state.copyWith(
          rows: rows,
          visible: rows,
          total: total,
          page: page,
          loading: false,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(loading: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: AppError.friendly(e)));
    }
  }

  Future<void> setPage(int page) async {
    final maxPage = state.total <= 0
        ? 0
        : ((state.total - 1) ~/ state.pageSize).clamp(0, 1 << 31);
    await load(page: page.clamp(0, maxPage));
  }

  Future<void> setPageSize(int size) async {
    if (size <= 0 || size == state.pageSize) return;
    safeEmit(state.copyWith(pageSize: size, page: 0));
    await load(page: 0);
  }

  Future<void> setQuery(String query) async {
    safeEmit(state.copyWith(query: query));
    await load(page: 0);
  }

  Future<void> setStatus(String status) async {
    safeEmit(state.copyWith(status: status));
    await load(page: 0);
  }

  /// Applies the reason (decision_reason) substring filter. The reason is
  /// never a table column — it only narrows the register.
  Future<void> setReason(String reason) async {
    safeEmit(state.copyWith(reason: reason));
    await load(page: 0);
  }

  /// Applies the exact-supplier filter (dashboard drill-down or the filter
  /// dialog). Empty clears it.
  Future<void> setSupplier(String supplier) async {
    final next = supplier.trim();
    if (next == state.supplier) return;
    safeEmit(state.copyWith(supplier: next));
    await load(page: 0);
  }

  /// Applies the filter-dialog draft (status + reason + inclusive date bounds
  /// + supplier + material/product selection; null id = all).
  Future<void> applyFilters({
    required String status,
    String reason = '',
    required String dateFrom,
    required String dateTo,
    required int? materialId,
    required String materialName,
    String supplier = '',
  }) async {
    safeEmit(
      state.copyWith(
        status: status,
        reason: reason,
        dateFrom: dateFrom,
        dateTo: dateTo,
        supplier: supplier,
        materialId: materialId,
        materialName: materialName,
        clearMaterialId: materialId == null,
      ),
    );
    await load(page: 0);
  }

  Future<void> setDateRange(String from, String to) async {
    safeEmit(state.copyWith(dateFrom: from, dateTo: to));
    await load(page: 0);
  }

  /// Clears status + reason + date + material + supplier filters (the search
  /// query has its own clear).
  Future<void> clearFilters() async {
    if (state.status.isEmpty &&
        state.reason.isEmpty &&
        state.dateFrom.isEmpty &&
        state.dateTo.isEmpty &&
        state.supplier.isEmpty &&
        state.materialId == null) {
      return;
    }
    safeEmit(
      state.copyWith(
        status: '',
        reason: '',
        dateFrom: '',
        dateTo: '',
        supplier: '',
        clearMaterialId: true,
      ),
    );
    await load(page: 0);
  }

  /// Removes one filter chip (`status`, `reason`, `dates`, `material` or
  /// `supplier`).
  Future<void> clearChip(String key) async {
    switch (key) {
      case 'status':
        if (state.status.isEmpty) return;
        safeEmit(state.copyWith(status: ''));
      case 'reason':
        if (state.reason.isEmpty) return;
        safeEmit(state.copyWith(reason: ''));
      case 'dates':
        if (state.dateFrom.isEmpty && state.dateTo.isEmpty) return;
        safeEmit(state.copyWith(dateFrom: '', dateTo: ''));
      case 'material':
        if (state.materialId == null) return;
        safeEmit(state.copyWith(clearMaterialId: true));
      case 'supplier':
        if (state.supplier.isEmpty) return;
        safeEmit(state.copyWith(supplier: ''));
      default:
        return;
    }
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
