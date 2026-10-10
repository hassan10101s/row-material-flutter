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
    this.loading = true,
    this.exporting = false,
    this.error,
    this.page = 0,
    this.pageSize = 50,
    this.total = 0,
    this.selectedIds = const {},
  });

  InspectionsState copyWith({
    List<Map<String, dynamic>>? rows,
    List<Map<String, dynamic>>? visible,
    String? query,
    String? status,
    bool? loading,
    bool? exporting,
    String? error,
    int? page,
    int? pageSize,
    int? total,
    Set<int>? selectedIds,
  }) =>
      InspectionsState(
        rows: rows ?? this.rows,
        visible: visible ?? this.visible,
        query: query ?? this.query,
        status: status ?? this.status,
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
        loading,
        exporting,
        error,
        page,
        pageSize,
        total,
        selectedIds,
      ];
}