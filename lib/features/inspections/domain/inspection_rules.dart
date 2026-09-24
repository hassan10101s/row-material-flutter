import '../../../core/constants/app_errors.dart';
import '../../../core/domain/rules.dart';
import '../../../core/utils/app_exceptions.dart';
import '../../../core/utils/app_format.dart';
import 'inspection.dart';

/// Decision validation rules (port of InspectionService decision logic).

/// Normalize decision fields: strip defaults (port of inspection.py:94-99).
///
/// `decision_reason` is never cleared. `follow_up_note` is only kept for
/// CONDITIONAL_APPROVAL and `rejected_quantity` only for PARTIAL_REJECTION —
/// everything else is blanked so stale values never leak across statuses.
Map<String, dynamic> normalizeDecisionFields(Map<String, dynamic> d) {
  final decisionStatus = '${d['decision_status'] ?? ''}'.trim();
  final normalized = <String, dynamic>{
    'decision_status': decisionStatus,
    'decision_reason': '${d['decision_reason'] ?? ''}'.trim(),
    'follow_up_note': '${d['follow_up_note'] ?? ''}'.trim(),
    'rejected_quantity': '${d['rejected_quantity'] ?? ''}'.trim(),
  };
  if (decisionStatus != 'CONDITIONAL_APPROVAL') {
    normalized['follow_up_note'] = '';
  }
  if (decisionStatus != 'PARTIAL_REJECTION') {
    normalized['rejected_quantity'] = '';
  }
  return normalized;
}

void validateDecisionFields(Map<String, dynamic> d) {
  final status = '${d['decision_status'] ?? ''}';
  if (!isDecisionStatus(status)) {
    throw ValidationError(AppErrors.decisionStatusRequired);
  }
  final reason = '${d['decision_reason'] ?? ''}'.trim();
  final followUp = '${d['follow_up_note'] ?? ''}'.trim();
  final rejectedQty = '${d['rejected_quantity'] ?? ''}'.trim();

  final notApproved = status == 'CONDITIONAL_APPROVAL' ||
      status == 'PARTIAL_REJECTION' ||
      status == 'FULL_REJECTION';
  if (notApproved && reason.isEmpty) {
    throw ValidationError(AppErrors.decisionReasonRequired);
  }
  if (status == 'CONDITIONAL_APPROVAL' && followUp.isEmpty) {
    throw ValidationError(AppErrors.followUpNoteRequired);
  }
  if (status == 'PARTIAL_REJECTION') {
    if (rejectedQty.isEmpty) {
      throw ValidationError(AppErrors.rejectedQtyRequired);
    }
    validateNonNegativeNumericText(rejectedQty, 'Rejected quantity',
        allowEmpty: false, maxLength: rejectedQuantityMaxLength);
    final quantityValue = '${d['quantity'] ?? ''}'.trim();
    if (quantityValue.isNotEmpty) {
      final rj = safeFloat(rejectedQty) ?? 0.0;
      final q = safeFloat(quantityValue) ?? 0.0;
      if (rj > q) {
        throw ValidationError(AppErrors.rejectedQtyExceeds);
      }
    }
  } else if (rejectedQty.isNotEmpty) {
    validateNonNegativeNumericText(rejectedQty, 'Rejected quantity',
        allowEmpty: false, maxLength: rejectedQuantityMaxLength);
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
        AppErrors.maxDecisionUpdates(maxDecisionVersions));
  }
}

/// Snap-shot the physical/chemical reference for an inspection.
Map<String, dynamic> buildSnapshot(Inspection i) => {
      'material_name': i.materialName,
      'material_code': i.materialCode,
      'physical_reference': i.physicalReference,
      'chemical_reference': i.chemicalReference,
    };