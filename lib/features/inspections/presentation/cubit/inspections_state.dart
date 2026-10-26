import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

/// Inspections ledger state: server-filtered page plus its total.
///
/// `rows`/`visible` are the current page (server already applied query+status);
/// keeping both preserves the existing screen/export call sites while the
/// source of truth moved from in-memory filtering to SQLite LIMIT/OFFSET.
///
/// `selectedIds` holds inspection ids for bulk export (the Vue register's
/// checkbox column). Ids — not indices — so the selection survives paging
/// and filter changes exactly like the legacy app.
@immutable
class InspectionsState extends Equatable {
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> visible;
  final String query;
  final String status;

  /// Reason filter (`decision_reason` substring). Never rendered as a table
  /// column — only used to narrow the register and shown back as a chip.
  final String reason;

  /// Exact supplier filter (dashboard drill-down seeds it); empty = all.
  /// Unlike [materialId] it is a plain string — `supplier` is free text,
  /// stored trimmed, so equality is identity here.
  final String supplier;

  /// Inclusive `inspection_date` bounds (`yyyy-MM-dd`); empty = unbounded.
  final String dateFrom;
  final String dateTo;

  /// Selected material (raw register) or product (product register) id;
  /// null = all. The same fields serve both registers because each cubit
  /// instance is bound to one `kind` (see `InspectionsCubit.load`).
  final int? materialId;

  /// Display name of [materialId] for the filter chip; empty when unfiltered.
  final String materialName;
  final bool loading;
  final bool exporting;
  final String? error;
  final int page;
  final int pageSize;
  final int total;
  final Set<int> selectedIds;

  const InspectionsState({
    this.rows = const [],
    this.visible = const [],
    this.query = '',
    this.status = '',
    this.reason = '',
    this.supplier = '',
    this.dateFrom = '',
    this.dateTo = '',
    this.materialId,
    this.materialName = '',
    this.loading = true,
    this.exporting = false,
    this.error,
    this.page = 0,
    this.pageSize = 200,
    this.total = 0,
    this.selectedIds = const {},
  });

  InspectionsState copyWith({
    List<Map<String, dynamic>>? rows,
    List<Map<String, dynamic>>? visible,
    String? query,
    String? status,
    String? reason,
    String? supplier,
    String? dateFrom,
    String? dateTo,
    int? materialId,
    String? materialName,
    // `copyWith` cannot tell "clear to null" from "not passed" for the
    // nullable [materialId]; `true` resets both material fields to unfiltered.
    bool clearMaterialId = false,
    bool? loading,
    bool? exporting,
    String? error,
    int? page,
    int? pageSize,
    int? total,
    Set<int>? selectedIds,
  }) => InspectionsState(
    rows: rows ?? this.rows,
    visible: visible ?? this.visible,
    query: query ?? this.query,
    status: status ?? this.status,
    reason: reason ?? this.reason,
    supplier: supplier ?? this.supplier,
    dateFrom: dateFrom ?? this.dateFrom,
    dateTo: dateTo ?? this.dateTo,
    materialId: clearMaterialId ? null : (materialId ?? this.materialId),
    materialName: clearMaterialId ? '' : (materialName ?? this.materialName),
    loading: loading ?? this.loading,
    exporting: exporting ?? this.exporting,
    error: error ?? this.error,
    page: page ?? this.page,
    pageSize: pageSize ?? this.pageSize,
    total: total ?? this.total,
    selectedIds: selectedIds ?? this.selectedIds,
  );

  @override
  List<Object?> get props => [
    rows,
    visible,
    query,
    status,
    reason,
    supplier,
    dateFrom,
    dateTo,
    materialId,
    materialName,
    loading,
    exporting,
    error,
    page,
    pageSize,
    total,
    selectedIds,
  ];
}
