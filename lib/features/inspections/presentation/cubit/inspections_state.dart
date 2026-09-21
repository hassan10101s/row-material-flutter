import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

/// Inspections ledger state: all rows plus the client-filtered [visible] list.
@immutable
class InspectionsState extends Equatable {
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> visible;
  final String query;
  final String status;
  final bool loading;
  final bool exporting;
  final String? error;

  const InspectionsState({
    this.rows = const [],
    this.visible = const [],
    this.query = '',
    this.status = '',
    this.loading = true,
    this.exporting = false,
    this.error,
  });

  InspectionsState copyWith({
    List<Map<String, dynamic>>? rows,
    List<Map<String, dynamic>>? visible,
    String? query,
    String? status,
    bool? loading,
    bool? exporting,
    String? error,
  }) =>
      InspectionsState(
        rows: rows ?? this.rows,
        visible: visible ?? this.visible,
        query: query ?? this.query,
        status: status ?? this.status,
        loading: loading ?? this.loading,
        exporting: exporting ?? this.exporting,
        error: error ?? this.error,
      );

  @override
  List<Object?> get props => [rows, visible, query, status, loading, exporting, error];
}