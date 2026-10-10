import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class UnitsState extends Equatable {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> rows;

  /// Reference counts per symbol: how many rows across the program inherit
  /// each unit. Drives the usage column and the delete guard.
  final Map<String, int> usage;

  const UnitsState({
    this.loading = true,
    this.error,
    this.rows = const [],
    this.usage = const {},
  });

  UnitsState copyWith({
    bool? loading,
    String? error,
    List<Map<String, dynamic>>? rows,
    Map<String, int>? usage,
  }) => UnitsState(
    loading: loading ?? this.loading,
    error: error ?? this.error,
    rows: rows ?? this.rows,
    usage: usage ?? this.usage,
  );

  @override
  List<Object?> get props => [loading, error, rows, usage];
}
