import 'dart:convert';

import '../domain/rules.dart';
import 'seal_codec.dart';

/// Port of core/utils.py build_qr_payload_text.
String buildQrPayloadText({
  required Map<String, dynamic> inspection,
  required List<dynamic> physicalData,
  required List<dynamic> chemicalData,
  List<int>? encryptKey,
}) {
  Map<String, dynamic> latestDecision = {};
  final history = (inspection['status_history'] as List<dynamic>?) ?? const [];
  for (final row in history.reversed) {
    if (row is Map) {
      final statusCode = '${row['new_status'] ?? ''}';
      if (isDecisionStatus(statusCode)) {
        latestDecision = {
          's': statusCode,
          'v': '${row['version'] ?? ''}',
          'r': '${row['change_reason'] ?? ''}',
        };
        break;
      }
    }
  }

  final physicalSummary = <String, List<dynamic>>{};
  for (final param in physicalData) {
    if (param is Map) {
      final name = '${param['name'] ?? '-'}';
      final results = (param['actuals'] as List<dynamic>?) ?? const [];
      physicalSummary[name] = results.map((r) => r ?? '-').toList();
    }
  }

  final chemicalSummary = <String, List<dynamic>>{};
  for (final param in chemicalData) {
    if (param is Map) {
      final name = '${param['name'] ?? '-'}';
      final results = (param['actuals'] as List<dynamic>?) ?? const [];
      chemicalSummary[name] = results.map((r) => r ?? '-').toList();
    }
  }

  final payload = <String, dynamic>{
    'ec': inspection['entry_code'] ?? '',
    'm': inspection['material_name'] ?? '',
    'mc': inspection['material_code'] ?? '',
    'd': inspection['inspection_date'] ?? '',
    's': inspection['supplier'] ?? '',
    't': inspection['truck_number'] ?? '',
    'q': inspection['quantity'] ?? '',
    'by': inspection['sample_taken_by'] ??
        inspection['specialist_name'] ??
        '',
    'sn': inspection['sample_names'] ?? const [],
    'dec': latestDecision,
    'ph': physicalSummary,
    'ch': chemicalSummary,
  };

  final raw = jsonEncode(payload);
  if (encryptKey != null && encryptKey.isNotEmpty) {
    return sealText(raw, encryptKey);
  }
  return raw;
}