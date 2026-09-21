import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class ReferenceState extends Equatable {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> materials;

  const ReferenceState({
    this.loading = true,
    this.error,
    this.materials = const [],
  });

  ReferenceState copyWith({
    bool? loading,
    String? error,
    List<Map<String, dynamic>>? materials,
  }) =>
      ReferenceState(
        loading: loading ?? this.loading,
        error: error ?? this.error,
        materials: materials ?? this.materials,
      );

  @override
  List<Object?> get props => [loading, error, materials];
}