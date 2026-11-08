import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class ReferenceState extends Equatable {
  final bool loading;
  final bool loadingMore;
  final bool hasMore;
  final int total;
  final String query;
  final String? error;
  final String? errorMore;
  final List<Map<String, dynamic>> materials;
  final Set<int> busyIds;
  final Set<int> pendingIds;
  bool isBlocked(int id) => busyIds.contains(id) || pendingIds.contains(id);

  const ReferenceState({
    this.loading = true,
    this.loadingMore = false,
    this.hasMore = false,
    this.total = 0,
    this.query = '',
    this.error,
    this.errorMore,
    this.materials = const [],
    this.busyIds = const {},
    this.pendingIds = const {},
  });

  ReferenceState copyWith({
    bool? loading,
    bool? loadingMore,
    bool? hasMore,
    int? total,
    String? query,
    String? error,
    String? errorMore,
    List<Map<String, dynamic>>? materials,
    bool clearError = false,
    bool clearErrorMore = false,
    Set<int>? busyIds,
    Set<int>? pendingIds,
  }) => ReferenceState(
    loading: loading ?? this.loading,
    loadingMore: loadingMore ?? this.loadingMore,
    hasMore: hasMore ?? this.hasMore,
    total: total ?? this.total,
    query: query ?? this.query,
    error: clearError ? null : error ?? this.error,
    errorMore: clearErrorMore ? null : errorMore ?? this.errorMore,
    materials: materials ?? this.materials,
    busyIds: busyIds ?? this.busyIds,
    pendingIds: pendingIds ?? this.pendingIds,
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
    materials,
    busyIds,
    pendingIds,
  ];
}
