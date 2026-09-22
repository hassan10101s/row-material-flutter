import 'dart:convert';

import 'package:intl/intl.dart';

import 'app_exceptions.dart';

/// JSON helpers mirroring core/utils.py json_dumps / json_loads and number
/// formatting used in reports.
String jsonDumps(Object? value) => jsonEncode(value);

Map<String, dynamic> jsonLoads(String? value, [Map<String, dynamic> fallback = const {}]) {
  if (value == null || value.trim().isEmpty) return fallback;
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } catch (_) {
    return fallback;
  }
  return fallback;
}

List<dynamic> jsonLoadsList(String? value, [List<dynamic> fallback = const []]) {
  if (value == null || value.trim().isEmpty) return fallback;
  try {
    final decoded = jsonDecode(value);
    if (decoded is List) return decoded;
  } catch (_) {
    return fallback;
  }
  return fallback;
}

/// Safe float parse matching _safe_float (core/utils.py:62-70): commas are
/// treated as thousand separators and stripped before parsing.
double? safeFloat(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  final s = value.toString().replaceAll(',', '').trim();
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

/// Round a percentage/ratio to one decimal place — port of Python
/// `round(value, 1)` used across aggregation.py and report.py (e.g. 5/6 →
/// 83.3, not 83).
double roundPct(num x) => double.parse(x.toStringAsFixed(1));

/// validate_non_negative_numeric_text port (core/utils.py:376-392):
/// digits only (`\d+(\.\d+)?`), optional max length, optional emptiness.
String validateNonNegativeNumericText(
  String value,
  String fieldLabel, {
  bool allowEmpty = true,
  int? maxLength,
}) {
  final text = value.trim();
  if (text.isEmpty) {
    if (allowEmpty) return '';
    throw ValidationError('$fieldLabel is required.');
  }
  if (maxLength != null && text.length > maxLength) {
    throw ValidationError('$fieldLabel must be at most $maxLength characters.');
  }
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(text)) {
    throw ValidationError('$fieldLabel must contain numbers only.');
  }
  return text;
}

/// format_quantity: port of core/utils.py — `{:.3f}` with thousands grouping.
final NumberFormat _qtyFormatter = NumberFormat('#,##0.000');

String formatQuantity(Object? value) {
  if (value == null) return '-';
  final s = value.toString().trim();
  final n = safeFloat(value) ?? 0.0;
  final isNumericText = value is num ||
      (value is String && s.isNotEmpty && RegExp(r'^[0-9.,]+$').hasMatch(s));
  if (n == 0 && !isNumericText) return s.isEmpty ? '-' : s;
  return _qtyFormatter.format(n);
}

/// format_label_quantity: return "-" when empty or zero.
String formatLabelQuantity(Object? value) {
  final text = '${value ?? ''}'.trim();
  if (text.isEmpty) return '-';
  final n = safeFloat(text) ?? 0.0;
  if (n == 0) return '-';
  return _qtyFormatter.format(n);
}

String sanitizeFilename(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? 'file' : cleaned;
}

// ── Enriched reference payload helpers (port of core/utils.py) ───────────

Object? unwrapReferenceValue(Object? value) {
  var current = value;
  for (var i = 0; i < 8; i++) {
    if (current is Map && current.containsKey('value')) {
      final next = current['value'];
      if (identical(next, current)) break;
      current = next;
    } else {
      break;
    }
  }
  return current;
}

String referenceUnitText(Object? value) {
  var current = value;
  var unitText = '';
  for (var i = 0; i < 8; i++) {
    if (current is! Map) break;
    final candidate = '${current['unit'] ?? ''}'.trim();
    if (candidate.isNotEmpty) unitText = candidate;
    final nested = current['value'];
    if (nested is Map) {
      current = nested;
    } else {
      break;
    }
  }
  return unitText;
}

String referenceValueText(Object? value) {
  final unwrapped = unwrapReferenceValue(value);
  if (unwrapped == null) return '';
  if (unwrapped is Map) {
    return jsonDumps(unwrapped);
  }
  return '$unwrapped'.trim();
}

/// with_reference_unit: idempotent {value, unit} enrichment.
Object? withReferenceUnit(Object? value, String unit) {
  Object? baseValue = unwrapReferenceValue(value);
  if (baseValue is Map) {
    baseValue = referenceValueText(baseValue);
  }
  final normalizedUnit = unit.trim().isNotEmpty
      ? unit.trim()
      : referenceUnitText(value);
  if (normalizedUnit.isNotEmpty) {
    return {'value': baseValue, 'unit': normalizedUnit};
  }
  return baseValue;
}