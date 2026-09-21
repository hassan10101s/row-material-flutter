import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

/// Inspection history state: active search query and the matching rows.
@immutable
class HistoryState extends Equatable {
  final String query;
  final List<Map<String, dynamic>> rows;
  final bool loading;
  final String? error;

  const HistoryState({
    this.query = '',
    this.rows = const [],
    this.loading = true,
    this.error,
  });

  HistoryState copyWith({
    String? query,
    List<Map<String, dynamic>>? rows,
    bool? loading,
    String? error,
  }) =>
      HistoryState(
        query: query ?? this.query,
        rows: rows ?? this.rows,
        loading: loading ?? this.loading,
        error: error ?? this.error,
      );

  @override
  List<Object?> get props => [query, rows, loading, error];
}