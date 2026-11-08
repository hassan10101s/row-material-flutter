import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class RunTestState extends Equatable {
  static const _unchanged = Object();
  final bool loading;
  final String? error;
  final List<Map<String, dynamic>> analyses;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> rawMaterials;
  final List<Map<String, dynamic>> inspections;
  final int? analysisId;
  final String sourceType;
  final String sourceName;
  final int? rawMaterialId;
  final Map<String, dynamic> selectedInspection;
  final String selectedSampleName;
  final int? productId;
  final bool loadingInspections;
  final bool running;

  const RunTestState({
    this.loading = true,
    this.error,
    this.analyses = const [],
    this.products = const [],
    this.rawMaterials = const [],
    this.inspections = const [],
    this.analysisId,
    this.sourceType = 'raw_material',
    this.sourceName = '',
    this.rawMaterialId,
    this.selectedInspection = const {},
    this.selectedSampleName = '',
    this.productId,
    this.loadingInspections = false,
    this.running = false,
  });

  RunTestState copyWith({
    bool? loading,
    Object? error = _unchanged,
    List<Map<String, dynamic>>? analyses,
    List<Map<String, dynamic>>? products,
    List<Map<String, dynamic>>? rawMaterials,
    List<Map<String, dynamic>>? inspections,
    Object? analysisId = _unchanged,
    String? sourceType,
    String? sourceName,
    Object? rawMaterialId = _unchanged,
    Map<String, dynamic>? selectedInspection,
    String? selectedSampleName,
    Object? productId = _unchanged,
    bool? loadingInspections,
    bool? running,
  }) => RunTestState(
    loading: loading ?? this.loading,
    error: identical(error, _unchanged) ? this.error : error as String?,
    analyses: analyses ?? this.analyses,
    products: products ?? this.products,
    rawMaterials: rawMaterials ?? this.rawMaterials,
    inspections: inspections ?? this.inspections,
    analysisId: identical(analysisId, _unchanged)
        ? this.analysisId
        : analysisId as int?,
    sourceType: sourceType ?? this.sourceType,
    sourceName: sourceName ?? this.sourceName,
    rawMaterialId: identical(rawMaterialId, _unchanged)
        ? this.rawMaterialId
        : rawMaterialId as int?,
    selectedInspection: selectedInspection ?? this.selectedInspection,
    selectedSampleName: selectedSampleName ?? this.selectedSampleName,
    productId: identical(productId, _unchanged)
        ? this.productId
        : productId as int?,
    loadingInspections: loadingInspections ?? this.loadingInspections,
    running: running ?? this.running,
  );

  @override
  List<Object?> get props => [
    loading,
    error,
    analyses,
    products,
    rawMaterials,
    inspections,
    analysisId,
    sourceType,
    sourceName,
    rawMaterialId,
    selectedInspection,
    selectedSampleName,
    productId,
    loadingInspections,
    running,
  ];
}
