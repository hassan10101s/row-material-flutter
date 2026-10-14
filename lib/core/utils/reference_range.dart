import 'dart:convert' show jsonDecode;

import 'app_format.dart';

/// A human-ready reference bound: what the lab accepts for one parameter.
///
/// Raw references come in many legacy shapes (`{"min":0.5,"max":2}`,
/// `"min 0.5 max 2"`, `"0.5-2"`, `"<= 5"`, `"Ok|Good"`, plain numbers), and
/// screens used to render them verbatim — JSON dumps, english fragments like
/// `min x`, or a bare `-`. This is the single formatter every inspection
/// surface (detail table, mobile cards, form grid) uses, so a bound always
/// reads the same way:
///
/// * closed range → `0.5 – 2`
/// * exact value  → `= 7`
/// * upper bound  → `≤ 5`
/// * lower bound  → `≥ 0.5`
/// * free text    → the text itself, cleaned
/// * nothing      → `—`
///
/// [unit] is carried separately so callers can render it as a chip next to
/// the value instead of gluing it into the string.
class ReferenceRange {
  const ReferenceRange({required this.display, this.unit = ''});

  /// The bound text without the unit (`0.5 – 2`, `≤ 5`, `—`).
  final String display;

  /// The measurement unit (`%`, `ppm`, …), possibly empty.
  final String unit;

  /// Bound text with the unit appended (`0.5 – 2 %`). Empty when both are.
  String get withUnit {
    if (display.isEmpty || display == '—') return display;
    if (unit.isEmpty) return display;
    return '$display $unit';
  }

  bool get isEmpty => display.isEmpty || display == '—';
}

num? _numOf(Object? value) {
  if (value == null) return null;
  return double.tryParse('$value');
}

/// Parses any stored reference shape into a display-ready [ReferenceRange].
ReferenceRange formatReferenceRange(Object? raw) {
  final unit = referenceUnitText(raw);
  final unwrapped = unwrapReferenceValue(raw);
  if (unwrapped == null) return const ReferenceRange(display: '—');
  if (unwrapped is! Map) {
    return _fromText('$unwrapped'.trim(), unit);
  }
  final map = Map<String, dynamic>.from(unwrapped);
  final minN = _numOf(map['min']);
  final maxN = _numOf(map['max']);
  final minT = map['min'] == null ? null : '${map['min']}'.trim();
  final maxT = map['max'] == null ? null : '${map['max']}'.trim();
  if (minN != null || maxN != null) {
    return _fromBounds(minN, maxN, minT, maxT, unit);
  }
  // A map without numeric bounds (option lists, `{value: ...}` leftovers):
  // fall back to the inner value text instead of a JSON dump.
  final inner = map['value'];
  if (inner != null && inner is! Map) {
    return _fromText('$inner'.trim(), unit);
  }
  final text = referenceValueText(raw).trim();
  if (text.isEmpty || text == '{}') {
    return const ReferenceRange(display: '—');
  }
  return _fromText(text, unit);
}

ReferenceRange _fromBounds(
  num? minN,
  num? maxN,
  String? minT,
  String? maxT,
  String unit,
) {
  if (minN != null && maxN != null) {
    if (minN == maxN) {
      return ReferenceRange(display: '= ${minT ?? '$minN'}', unit: unit);
    }
    return ReferenceRange(
      display: '${minT ?? '$minN'} – ${maxT ?? '$maxN'}',
      unit: unit,
    );
  }
  if (maxN != null) {
    return ReferenceRange(display: '≤ ${maxT ?? '$maxN'}', unit: unit);
  }
  return ReferenceRange(display: '≥ ${minT ?? '$minN'}', unit: unit);
}

ReferenceRange _fromText(String text, String unit) {
  if (text.isEmpty) return ReferenceRange(display: '—', unit: unit);
  final t = text
      .replaceAll('–', '-')
      .replaceAll('—', '-')
      .replaceAll(',', '.');
  final maxM = RegExp(
    r'(?:<=|≤|less\s+than|max)\s*(-?\d+(?:\.\d+)?)',
    caseSensitive: false,
  ).firstMatch(t);
  if (maxM != null) {
    return ReferenceRange(display: '≤ ${maxM.group(1)}', unit: unit);
  }
  final minM = RegExp(
    r'(?:>=|≥|more\s+than|min)\s*(-?\d+(?:\.\d+)?)',
    caseSensitive: false,
  ).firstMatch(t);
  if (minM != null) {
    return ReferenceRange(display: '≥ ${minM.group(1)}', unit: unit);
  }
  final range = RegExp(
    r'(-?\d+(?:\.\d+)?)\s*(?:-|:|to|~|–)\s*(-?\d+(?:\.\d+)?)',
  ).firstMatch(t);
  if (range != null) {
    final a = _numOf(range.group(1));
    final b = _numOf(range.group(2));
    if (a != null && b != null) {
      if (a == b) return ReferenceRange(display: '= ${range.group(1)}', unit: unit);
      return ReferenceRange(
        display: '${range.group(1)} – ${range.group(2)}',
        unit: unit,
      );
    }
  }
  // A lone number is an exact target.
  if (_numOf(t) != null) {
    return ReferenceRange(display: '= $t', unit: unit);
  }
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map) return formatReferenceRange(decoded);
  } on Object {
    // Not JSON: fall through to plain text.
  }
  return ReferenceRange(display: text, unit: unit);
}
