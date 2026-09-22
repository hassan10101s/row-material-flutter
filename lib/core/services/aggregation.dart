import '../utils/app_format.dart';

/// Port of core/services/aggregation.py.
const Map<String, String> decisionLabels = {
  'APPROVED': 'قبول نهائي',
  'CONDITIONAL_APPROVAL': 'قبول مع متابعة',
  'PARTIAL_REJECTION': 'رفض جزئي',
  'FULL_REJECTION': 'رفض كلي',
};

String decisionLabel(String? status) =>
    decisionLabels[status ?? ''] ?? status ?? '-';

double _safeQty(Object? value, double fallback) {
  final d = safeFloat(value);
  return d ?? fallback;
}

Map<String, List<Map<String, dynamic>>> groupByMaterial(
    List<Map<String, dynamic>> inspections) {
  final materials = <String, List<Map<String, dynamic>>>{};
  for (final insp in inspections) {
    final name = '${insp['material_name'] ?? 'Unknown'}';
    materials.putIfAbsent(name, () => []).add(insp);
  }
  return materials;
}

int uniqueSuppliersCount(List<Map<String, dynamic>> inspections,
    {bool allowBlankSuppliers = false}) {
  final suppliers = <String>{};
  for (final i in inspections) {
    final s = '${i['supplier'] ?? ''}'.trim();
    if (s.isNotEmpty) suppliers.add(s);
  }
  return suppliers.length;
}

/// Port of aggregate_totals.
Map<String, dynamic> aggregateTotals(List<Map<String, dynamic>> inspections,
    {bool allowBlankSuppliers = false}) {
  var approved = 0, conditional = 0, partial = 0, rejected = 0;
  var totalQty = 0.0, totalRejectedQty = 0.0;

  for (final i in inspections) {
    final status = i['decision_status'];
    final q = _safeQty(i['quantity'], 0);
    final rj = _safeQty(i['rejected_quantity'], 0);
    totalQty += q;
    switch (status) {
      case 'APPROVED':
        approved++;
        break;
      case 'CONDITIONAL_APPROVAL':
        conditional++;
        break;
      case 'PARTIAL_REJECTION':
        partial++;
        totalRejectedQty += rj;
        break;
      case 'FULL_REJECTION':
        rejected++;
        totalRejectedQty += q;
        break;
    }
  }

  final totalAcceptedQty = totalQty - totalRejectedQty;
  final acceptedTotalCount = approved + conditional;
  final approvalRate = inspections.isEmpty
      ? 0.0
      : roundPct((acceptedTotalCount / inspections.length) * 100);

  return {
    'approved': approved,
    'conditional': conditional,
    'partial': partial,
    'rejected': rejected,
    'accepted_total': acceptedTotalCount,
    'conditional_partial': conditional + partial,
    'total_qty': totalQty,
    'total_rejected_qty': totalRejectedQty,
    'total_accepted_qty': totalAcceptedQty,
    'approval_rate': approvalRate,
    'unique_suppliers': uniqueSuppliersCount(
        inspections, allowBlankSuppliers: allowBlankSuppliers),
    'unique_materials': groupByMaterial(inspections).length,
  };
}

String decisionTime(Map<String, dynamic> item) {
  final raw = '${item['updated_at'] ?? item['created_at'] ?? '-'}';
  for (var i = 0; i < raw.length; i++) {
    if (raw[i] == ' ' || raw[i] == 'T') {
      final time = raw.substring(i + 1).trim();
      return time.length > 5 ? time.substring(0, 5) : time;
    }
  }
  return raw;
}

Map<String, dynamic> detailRow(int index, Map<String, dynamic> item, String? status) =>
    {
      'index': index,
      'entry_code': item['entry_code'] ?? '-',
      'decision_time': decisionTime(item),
      'supplier': item['supplier'] ?? '-',
      'quantity': formatQuantity(item['quantity']),
      'decision_status': decisionLabel(status),
      'decision_status_raw': status ?? 'UNKNOWN',
      'decision_reason': item['decision_reason'] ?? '-',
      'follow_up_note': item['follow_up_note'] ?? '-',
      'rejected_quantity': status == 'PARTIAL_REJECTION'
          ? formatQuantity(item['rejected_quantity'])
          : '-',
      'specialist_name':
          item['specialist_name'] ?? item['created_by_name'] ?? '-',
      'expiry_date': item['expiry_date'] ?? '-',
    };

/// Port of build_material_sections — per-material summary + detail rows.
List<Map<String, dynamic>> buildMaterialSections(
    List<Map<String, dynamic>> inspections) {
  final sections = <Map<String, dynamic>>[];
  groupByMaterial(inspections).forEach((materialName, matItems) {
    var mQty = 0.0, mRejQty = 0.0;
    var mApp = 0, mCond = 0, mPart = 0, mRej = 0;
    final rows = <Map<String, dynamic>>[];
    var index = 1;
    for (final item in matItems) {
      final status = item['decision_status'];
      final iq = _safeQty(item['quantity'], 0);
      final irj = _safeQty(item['rejected_quantity'], 0);
      mQty += iq;
      switch (status) {
        case 'APPROVED':
          mApp++;
          break;
        case 'CONDITIONAL_APPROVAL':
          mCond++;
          break;
        case 'PARTIAL_REJECTION':
          mPart++;
          mRejQty += irj;
          break;
        case 'FULL_REJECTION':
          mRej++;
          mRejQty += iq;
          break;
      }
      rows.add(detailRow(index++, item, status));
    }
    sections.add({
      'name': materialName,
      'count': matItems.length,
      'total_quantity': formatQuantity(mQty),
      'accepted_quantity': formatQuantity(mQty - mRejQty),
      'rejected_quantity': formatQuantity(mRejQty),
      'approved': mApp,
      'conditional': mCond,
      'partial': mPart,
      'rejected': mRej,
      'conditional_partial': mCond + mPart,
      'rows': rows,
    });
  });
  return sections;
}