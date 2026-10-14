import 'dart:convert' show json;

/// Product batch samples (محضر التشغيلة rows).
///
/// The batch header IS the existing product `inspections` row
/// (`inspection_kind = 'product'`): `entry_code` is the batch code scanned
/// by QR, `quantity` is the batch size (e.g. 50 tons). This contract covers
/// only the sample rows inside that report (`product_batch_samples`).
///
/// A sample carries its own results as JSON on its row — fully independent
/// of the lab chemistry pipeline (`lab_sample_tests` is never touched for
/// batch samples): who took the sample (`sample_taker`), a physical map
/// (`physical_results_json`: `{name: value}`) and multiple chemical rows
/// (`chemical_results_json`: `[{name, result, unit}]`).
///
/// Legacy rows filed through `runSampleTest` keep living in
/// `lab_sample_tests`; `listSampleResults` still reads them, but no new
/// batch data flows there. Raw-material flow never touches any of this.
abstract interface class ProductBatchRepository {
  /// Samples of one batch (`inspections.id`), ordered by `sample_no`.
  Future<List<Map<String, dynamic>>> listBatchSamples(int batchId);

  /// Appends the next sample (`sample_no = max + 1`) with taker + results.
  Future<Map<String, dynamic>> addBatchSample({
    required int batchId,
    String? sampleName,
    String sampleTaker = '',
    Map<String, String> physicalResults = const {},
    List<Map<String, String>> chemicalResults = const [],
    Map<String, dynamic>? user,
  });

  /// Edits a sample's identity and/or its own results (null = unchanged).
  Future<void> updateBatchSample(
    int sampleId, {
    String? sampleName,
    String? sampleTaker,
    Map<String, String>? physicalResults,
    List<Map<String, String>>? chemicalResults,
  });

  /// Per-sample decision (pass/fail vs the product ranges).
  Future<void> setBatchSampleDecision(
    int sampleId, {
    required String status,
    String reason = '',
  });

  /// Removes a sample (plus its legacy `lab_sample_tests` rows, if any).
  Future<void> deleteBatchSample(int sampleId);

  /// Legacy lab-pipeline results of one sample with `tested_by_name`
  /// resolved, newest analysis first. New batch data lives on the sample
  /// row itself ([decodeBatchPhysical]/[decodeBatchChemical]); this stays
  /// for rows filed before the decoupling.
  Future<List<Map<String, dynamic>>> listSampleResults(int sampleId);
}

/// Physical map of one batch sample: `{analysis name: result}`.
Map<String, String> decodeBatchPhysical(Object? raw) {
  if (raw is Map) {
    return {
      for (final e in raw.entries) '${e.key}'.trim(): '${e.value ?? ''}'.trim(),
    }..removeWhere((k, v) => k.isEmpty && v.isEmpty);
  }
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final decoded = _jsonDecode(raw);
      if (decoded is Map) return decodeBatchPhysical(decoded);
    } catch (_) {}
  }
  return {};
}

/// Multiple chemical rows of one batch sample:
/// `[{name, result, unit}]`, free of empty rows.
List<Map<String, String>> decodeBatchChemical(Object? raw) {
  List decoded = const [];
  if (raw is List) {
    decoded = raw;
  } else if (raw is String && raw.trim().isNotEmpty) {
    try {
      final d = _jsonDecode(raw);
      if (d is List) decoded = d;
    } catch (_) {
      return [];
    }
  } else {
    return [];
  }
  final out = <Map<String, String>>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final row = {
      'name': '${item['name'] ?? ''}'.trim(),
      'result': '${item['result'] ?? ''}'.trim(),
      'unit': '${item['unit'] ?? ''}'.trim(),
    };
    if (row['name']!.isEmpty && row['result']!.isEmpty) continue;
    out.add(row);
  }
  return out;
}

String encodeBatchPhysical(Map<String, String> physical) {
  final clean = <String, String>{};
  physical.forEach((k, v) {
    final key = k.trim();
    if (key.isNotEmpty) clean[key] = v.trim();
  });
  return _jsonEncode(clean);
}

String encodeBatchChemical(List<Map<String, String>> chemical) {
  return _jsonEncode([
    for (final r in chemical)
      {
        'name': (r['name'] ?? '').trim(),
        'result': (r['result'] ?? '').trim(),
        'unit': (r['unit'] ?? '').trim(),
      },
  ]);
}

dynamic _jsonDecode(String raw) => json.decode(raw);
String _jsonEncode(Object? value) => json.encode(value);
