import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

/// New-inspection form state: the material list, the selected material's
/// reference/entry-code data (needed to rebuild the result input grids) and
/// the save busy/error flags.
@immutable
class InspectionFormState extends Equatable {
  final List<Map<String, dynamic>> materials;
  final int? materialId;
  final String materialCode;
  final String entryCode;
  final Map<String, dynamic> physicalReference;
  final Map<String, dynamic> chemicalReference;
  final int refRevision;

  /// Supplier history for the selected material (Vue parity autocomplete).
  /// Row shape: `{name, lastDate, uses}`, most recent first, de-duplicated.
  final List<Map<String, dynamic>> supplierOptions;

  /// Sample-taker history (the technicians log), same row shape.
  final List<Map<String, dynamic>> sampleTakerOptions;

  final bool loading;
  final bool selectingReference;
  final bool saving;
  final String? error;
  final bool pendingApproval;
  final String decision;

  const InspectionFormState({
    this.materials = const [],
    this.materialId,
    this.materialCode = '',
    this.entryCode = '',
    this.physicalReference = const {},
    this.chemicalReference = const {},
    this.refRevision = 0,
    this.supplierOptions = const [],
    this.sampleTakerOptions = const [],
    this.loading = true,
    this.selectingReference = false,
    this.saving = false,
    this.error,
    this.pendingApproval = false,
    this.decision = 'APPROVED',
  });

  InspectionFormState copyWith({
    List<Map<String, dynamic>>? materials,
    int? materialId,
    bool clearMaterialId = false,
    String? materialCode,
    String? entryCode,
    Map<String, dynamic>? physicalReference,
    Map<String, dynamic>? chemicalReference,
    int? refRevision,
    List<Map<String, dynamic>>? supplierOptions,
    List<Map<String, dynamic>>? sampleTakerOptions,
    bool? loading,
    bool? selectingReference,
    bool? saving,
    String? error,
    bool clearError = false,
    bool? pendingApproval,
    String? decision,
  }) => InspectionFormState(
    materials: materials ?? this.materials,
    materialId: clearMaterialId ? null : materialId ?? this.materialId,
    materialCode: materialCode ?? this.materialCode,
    entryCode: entryCode ?? this.entryCode,
    physicalReference: physicalReference ?? this.physicalReference,
    chemicalReference: chemicalReference ?? this.chemicalReference,
    refRevision: refRevision ?? this.refRevision,
    supplierOptions: supplierOptions ?? this.supplierOptions,
    sampleTakerOptions: sampleTakerOptions ?? this.sampleTakerOptions,
    loading: loading ?? this.loading,
    selectingReference: selectingReference ?? this.selectingReference,
    saving: saving ?? this.saving,
    error: clearError ? null : error ?? this.error,
    pendingApproval: pendingApproval ?? this.pendingApproval,
    decision: decision ?? this.decision,
  );

  @override
  List<Object?> get props => [
    materials,
    materialId,
    materialCode,
    entryCode,
    physicalReference,
    chemicalReference,
    refRevision,
    supplierOptions,
    sampleTakerOptions,
    loading,
    selectingReference,
    saving,
    error,
    pendingApproval,
    decision,
  ];
}
