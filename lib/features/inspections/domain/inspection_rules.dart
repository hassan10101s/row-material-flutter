import '../../../core/domain/rules.dart';
import '../../../core/utils/app_exceptions.dart';
import 'inspection.dart';

/// Decision validation rules (port of InspectionService decision logic).

/// Normalize decision fields: strip, defaults.
Map<String, dynamic> normalizeDecisionFields(Map<String, dynamic> d) {
  final decisionStatus = '${d['decision_status'] ?? ''}'.trim();
  final normalized = <String, dynamic>{
    'decision_status': decisionStatus,
    'decision_reason': '${d['decision_reason'] ?? ''}'.trim(),
    'follow_up_note': '${d['follow_up_note'] ?? ''}'.trim(),
    'rejected_quantity': '${d['rejected_quantity'] ?? ''}'.trim(),
  };
  if (decisionStatus == 'APPROVED') {
    normalized['decision_reason'] = '';
    normalized['follow_up_note'] = '';
    normalized['rejected_quantity'] = '';
  }
  return normalized;
}

void validateDecisionFields(Map<String, dynamic> d) {
  final status = '${d['decision_status'] ?? ''}';
  if (!isDecisionStatus(status)) {
    throw const ValidationError('Unsupported decision status.');
  }
  final reason = '${d['decision_reason'] ?? ''}'.trim();
  final followUp = '${d['follow_up_note'] ?? ''}'.trim();
  final rejectedQty = '${d['rejected_quantity'] ?? ''}'.trim();

  switch (status) {
    case 'CONDITIONAL_APPROVAL':
      if (followUp.isEmpty) {
        throw const ValidationError(
            'Note is required for conditional approval. | ملاحظة المتابعة مطلوبة في القبول المبدئي.');
      }
    case 'PARTIAL_REJECTION':
      if (rejectedQty.isEmpty) {
        throw const ValidationError(
            'Rejected quantity is required for partial rejection. | الكمية المرفوضة مطلوبة في الرفض الجزئي.');
      }
    case 'FULL_REJECTION':
      if (reason.isEmpty) {
        throw const ValidationError(
            'Reason is required for rejection. | سبب القرار مطلوب في حالات الرفض.');
      }
  }
}

/// Detect whether a decision patch actually changes anything.
bool hasDecisionChange(Inspection existing, Map<String, dynamic> normalized) =>
    normalized['decision_status'] != existing.decisionStatus ||
    normalized['decision_reason'] != (existing.decisionReason) ||
    normalized['follow_up_note'] != (existing.followUpNote) ||
    normalized['rejected_quantity'] != (existing.rejectedQuantity);

void ensureWithinMaxVersions(int version) {
  if (version >= maxDecisionVersions) {
    throw ValidationError(
        'Reached maximum quality decision updates ($maxDecisionVersions times). | تم الوصول إلى الحد الأقصى من تحديثات قرار الجودة ($maxDecisionVersions مرات).');
  }
}

/// Snap-shot the physical/chemical reference for an inspection.
Map<String, dynamic> buildSnapshot(Inspection i) => {
      'material_name': i.materialName,
      'material_code': i.materialCode,
      'physical_reference': i.physicalReference,
      'chemical_reference': i.chemicalReference,
    };