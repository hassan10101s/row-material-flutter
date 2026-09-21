import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class AnalysesState extends Equatable {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> rows;

  const AnalysesState({
    this.loading = true,
    this.error,
    this.rows = const [],
  });

  AnalysesState copyWith({
    bool? loading,
    String? error,
    List<Map<String, dynamic>>? rows,
  }) =>
      AnalysesState(
        loading: loading ?? this.loading,
        error: error ?? this.error,
        rows: rows ?? this.rows,
      );

  @override
  List<Object?> get props => [loading, error, rows];
}