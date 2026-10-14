import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class UnitsState extends Equatable {
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final int total;
  final String query;
  final String? error;
  final String? errorMore;
  final List<Map<String, dynamic>> rows;

  /// Reference counts per symbol: how many rows across the program inherit
  /// each unit. Drives the usage column and the delete guard.
  final Map<String, int> usage;

  const UnitsState({
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = false,
    this.total = 0,
    this.query = '',
    this.error,
    this.errorMore,
    this.rows = const [],
    this.usage = const {},
  });

  UnitsState copyWith({
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    int? total,
    String? query,
    String? error,
    String? errorMore,
    List<Map<String, dynamic>>? rows,
    Map<String, int>? usage,
    bool clearError = false,
    bool clearErrorMore = false,
  }) => UnitsState(
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
    total: total ?? this.total,
    query: query ?? this.query,
    error: clearError ? null : error ?? this.error,
    errorMore: clearErrorMore ? null : errorMore ?? this.errorMore,
    rows: rows ?? this.rows,
    usage: usage ?? this.usage,
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
    usage,
  ];
}
