import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class ProductsState extends Equatable {
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final int total;
  final String query;
  final String? error;
  final String? errorMore;
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> analyses;

  const ProductsState({
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = false,
    this.total = 0,
    this.query = '',
    this.error,
    this.errorMore,
    this.rows = const [],
    this.analyses = const [],
  });

  ProductsState copyWith({
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    int? total,
    String? query,
    String? error,
    String? errorMore,
    bool clearError = false,
    bool clearErrorMore = false,
    List<Map<String, dynamic>>? rows,
    List<Map<String, dynamic>>? analyses,
  }) => ProductsState(
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
    total: total ?? this.total,
    query: query ?? this.query,
    error: clearError ? null : error ?? this.error,
    errorMore: clearErrorMore ? null : errorMore ?? this.errorMore,
    rows: rows ?? this.rows,
    analyses: analyses ?? this.analyses,
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
    analyses,
  ];
}
