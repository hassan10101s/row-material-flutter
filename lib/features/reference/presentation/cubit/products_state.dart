import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class ProductsState extends Equatable {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> analyses;

  const ProductsState({
    this.loading = true,
    this.error,
    this.rows = const [],
    this.analyses = const [],
  });

  ProductsState copyWith({
    bool? loading,
    String? error,
    List<Map<String, dynamic>>? rows,
    List<Map<String, dynamic>>? analyses,
  }) =>
      ProductsState(
        loading: loading ?? this.loading,
        error: error ?? this.error,
        rows: rows ?? this.rows,
        analyses: analyses ?? this.analyses,
      );

  @override
  List<Object?> get props => [loading, error, rows, analyses];
}