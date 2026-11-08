import 'dart:convert';

import 'app_format.dart';
import 'decimal_input.dart';

const _number = r'[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?';
const _units = r'%|ppm|ppb|°C|°F|mg/kg|g/kg|mg/L|g/L|kg|mg|g|mL|L|cm|mm|m';

String _referenceUnit(Object? reference) {
  final declared = referenceUnitText(reference);
  if (declared.isNotEmpty) return declared;
  final raw = unwrapReferenceValue(reference);
  final text = raw is Map ? '${raw['max'] ?? ''}' : '${raw ?? ''}';
  return RegExp(
        '($_units)\\s*\$',
        caseSensitive: false,
      ).firstMatch(text)?.group(1) ??
      '';
}

double? _measurement(Object? raw, String unit) {
  if (raw is num) return raw.isFinite ? raw.toDouble() : null;
  final text = normalizeDecimalInput('${raw ?? ''}').replaceAll('٬', '');
  final suffix = unit.trim().isNotEmpty ? RegExp.escape(unit.trim()) : _units;
  final match = RegExp(
    '^($_number)\\s*(?:$suffix)?\$',
    caseSensitive: false,
  ).firstMatch(text);
  final value = match == null ? null : double.tryParse(match.group(1)!);
  return value != null && value.isFinite ? value : null;
}

/// Uses an actual upper/exact bound. A minimum-only or textual reference does
/// not supply an upper bound. Never guesses a number from malformed text.
double? analysisUpperBound(Object? reference) {
  final unit = _referenceUnit(reference);
  final raw = unwrapReferenceValue(reference);
  if (raw is Map) return _measurement(raw['max'], unit);
  if (raw is num) return _measurement(raw, unit);
  var text = '${raw ?? ''}'.trim();
  if (text.startsWith('{')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return analysisUpperBound(decoded);
    } on FormatException {
      return null;
    }
  }
  text = normalizeDecimalInput(text).replaceAll('٬', '');
  final upper = RegExp(
    r'(?:<=|≤|<|less\s+than|\bmax(?:imum)?|حد\s*أقصى|الحد\s*الأعلى)\s*[:=]?\s*(.+)$',
    caseSensitive: false,
  ).firstMatch(text);
  if (upper != null) return _measurement(upper.group(1), unit);
  if (RegExp(
    r'>|≥|\bmin(?:imum)?\b|more\s+than|حد\s*أدنى',
    caseSensitive: false,
  ).hasMatch(text)) {
    return null;
  }
  final range = RegExp(
    '^($_number)\\s*(?:-|–|—|:|to|~)\\s*($_number)(.*)\$',
    caseSensitive: false,
  ).firstMatch(text);
  if (range != null) {
    final lower = _measurement(range.group(1), '');
    final higher = _measurement('${range.group(2)}${range.group(3)}', unit);
    return lower != null && higher != null && lower <= higher ? higher : null;
  }
  return _measurement(text.replaceFirst(RegExp(r'^=\s*'), ''), unit);
}

bool exceedsDoubleAnalysisMaximum(Object? value, Object? reference) {
  final maximum = analysisUpperBound(reference);
  final measured = _measurement(value, _referenceUnit(reference));
  return maximum != null && measured != null && measured > 2 * maximum;
}

/// The selected inspection owns the relevant material/product snapshot.
/// Match its parameter names; unrelated formula input quantities have no bound.
Object? inspectionAnalysisReference(
  Map<String, dynamic> inspection,
  Iterable<String> names,
) {
  final wanted = names
      .map((name) => name.trim().toLowerCase())
      .where((name) => name.isNotEmpty)
      .toList();
  for (final name in wanted) {
    for (final column in [
      'chemical_reference',
      'chemical_reference_json',
      'physical_reference',
      'physical_reference_json',
    ]) {
      var raw = inspection[column];
      if (raw is String) {
        try {
          raw = jsonDecode(raw);
        } on FormatException {
          continue;
        }
      }
      if (raw is! Map) continue;
      for (final entry in raw.entries) {
        if ('${entry.key}'.trim().toLowerCase() == name) return entry.value;
      }
    }
  }
  return null;
}
