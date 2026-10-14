import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class InventoryState extends Equatable {
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final int total;
  final String query;
  final String? error;
  final String? errorMore;
  final List<Map<String, dynamic>> rows;

  const InventoryState({
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = false,
    this.total = 0,
    this.query = '',
    this.error,
    this.errorMore,
    this.rows = const [],
  });

  InventoryState copyWith({
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    int? total,
    String? query,
    String? error,
    String? errorMore,
    List<Map<String, dynamic>>? rows,
    bool clearError = false,
    bool clearErrorMore = false,
  }) => InventoryState(
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
    total: total ?? this.total,
    query: query ?? this.query,
    error: clearError ? null : error ?? this.error,
    errorMore: clearErrorMore ? null : errorMore ?? this.errorMore,
    rows: rows ?? this.rows,
  );

  @override
  List<Object?> get props => [
    loading,
    loadingMore,
    hasMore,
    total,
    query,
    error,
    errorMore,
    rows,
  ];
}
