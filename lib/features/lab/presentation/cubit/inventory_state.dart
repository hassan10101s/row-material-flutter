import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class InventoryState extends Equatable {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> rows;

  const InventoryState({
    this.loading = true,
    this.error,
    this.rows = const [],
  });

  InventoryState copyWith({
    bool? loading,
    String? error,
    List<Map<String, dynamic>>? rows,
  }) =>
      InventoryState(
        loading: loading ?? this.loading,
        error: error ?? this.error,
        rows: rows ?? this.rows,
      );

  @override
  List<Object?> get props => [loading, error, rows];
}