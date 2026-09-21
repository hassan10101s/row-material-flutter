import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class RunTestState extends Equatable {
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> analyses;
  final List<Map<String, dynamic>> products;
  final int? analysisId;
  final String sourceType;
  final String sourceName;
  final int? productId;
  final bool running;

  const RunTestState({
    this.loading = true,
    this.error,
    this.analyses = const [],
    this.products = const [],
    this.analysisId,
    this.sourceType = 'raw_material',
    this.sourceName = '',
    this.productId,
    this.running = false,
  });

  RunTestState copyWith({
    bool? loading,
    String? error,
    List<Map<String, dynamic>>? analyses,
    List<Map<String, dynamic>>? products,
    int? analysisId,
    String? sourceType,
    String? sourceName,
    int? productId,
    bool? running,
  }) =>
      RunTestState(
        loading: loading ?? this.loading,
        error: error ?? this.error,
        analyses: analyses ?? this.analyses,
        products: products ?? this.products,
        analysisId: analysisId ?? this.analysisId,
        sourceType: sourceType ?? this.sourceType,
        sourceName: sourceName ?? this.sourceName,
        productId: productId ?? this.productId,
        running: running ?? this.running,
      );

  @override
  List<Object?> get props => [
        loading,
        error,
        analyses,
        products,
        analysisId,
        sourceType,
        sourceName,
        productId,
        running,
      ];
}