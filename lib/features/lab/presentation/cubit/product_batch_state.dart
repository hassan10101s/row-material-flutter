import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

/// Samples of one product batch (محضر التشغيلة).
///
/// The batch header itself stays on the product `inspections` row; this
/// state holds only the "table inside the report". Each sample carries its
/// own results on its row (taker, time, physical map, multiple chemical
/// rows) — independent of the lab pipeline.
@immutable
class ProductBatchState extends Equatable {
  final bool loading;
  final bool saving;
  final String? error;
  final List<Map<String, dynamic>> samples;

  const ProductBatchState({
    this.loading = true,
    this.saving = false,
    this.error,
    this.samples = const [],
  });

  int get decidedCount =>
      samples.where((s) => '${s['decision_status'] ?? ''}'.isNotEmpty).length;

  ProductBatchState copyWith({
    bool? loading,
    bool? saving,
    String? error,
    bool clearError = false,
    List<Map<String, dynamic>>? samples,
  }) => ProductBatchState(
    loading: loading ?? this.loading,
    saving: saving ?? this.saving,
    error: clearError ? null : error ?? this.error,
    samples: samples ?? this.samples,
  );

  @override
  List<Object?> get props => [loading, saving, error, samples];
}
