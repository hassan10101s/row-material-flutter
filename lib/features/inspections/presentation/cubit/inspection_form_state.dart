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
  final bool loading;
  final bool saving;
  final String? error;
  final String decision;

  const InspectionFormState({
    this.materials = const [],
    this.materialId,
    this.materialCode = '',
    this.entryCode = '',
    this.physicalReference = const {},
    this.chemicalReference = const {},
    this.refRevision = 0,
    this.loading = true,
    this.saving = false,
    this.error,
    this.decision = 'APPROVED',
  });

  InspectionFormState copyWith({
    List<Map<String, dynamic>>? materials,
    int? materialId,
    String? materialCode,
    String? entryCode,
    Map<String, dynamic>? physicalReference,
    Map<String, dynamic>? chemicalReference,
    int? refRevision,
    bool? loading,
    bool? saving,
    String? error,
    String? decision,
  }) =>
      InspectionFormState(
        materials: materials ?? this.materials,
        materialId: materialId ?? this.materialId,
        materialCode: materialCode ?? this.materialCode,
        entryCode: entryCode ?? this.entryCode,
        physicalReference: physicalReference ?? this.physicalReference,
        chemicalReference: chemicalReference ?? this.chemicalReference,
        refRevision: refRevision ?? this.refRevision,
        loading: loading ?? this.loading,
        saving: saving ?? this.saving,
        error: error ?? this.error,
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
        loading,
        saving,
        error,
        decision,
      ];
}