import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class ParamsState extends Equatable {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> units;

  const ParamsState({
    this.loading = true,
    this.error,
    this.rows = const [],
    this.units = const [],
  });

  ParamsState copyWith({
    bool? loading,
    String? error,
    List<Map<String, dynamic>>? rows,
    List<Map<String, dynamic>>? units,
  }) =>
      ParamsState(
        loading: loading ?? this.loading,
        error: error ?? this.error,
        rows: rows ?? this.rows,
        units: units ?? this.units,
      );

  @override
  List<Object?> get props => [loading, error, rows, units];
}