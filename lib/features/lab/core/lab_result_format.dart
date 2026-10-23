/// Formats numeric laboratory results for display without changing storage.
String formatLabResult(Object? value, {int decimals = 3}) {
  final raw = '${value ?? ''}'.trim();
  if (raw.isEmpty) return '-';
  final suffix = raw.endsWith('%') ? '%' : '';
  final numeric = double.tryParse(raw.replaceAll('%', '').trim());
  if (numeric == null) return raw;
  return '${numeric.toStringAsFixed(decimals)}$suffix';
}

/// Rounds [value] to at most [decimals] places and trims trailing zeros, for
/// on-screen numeric previews (form runs, fixed values). Returns '' when the
/// value is missing or not numeric, so callers can fall back to a placeholder.
String labNumber(Object? value, {int decimals = 3}) {
  final raw = '${value ?? ''}'.trim();
  if (raw.isEmpty) return '';
  final numeric = double.tryParse(raw);
  if (numeric == null) return '';
  var text = numeric.toStringAsFixed(decimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

/// Canonical text for a computed formula result: exactly [decimals] decimal
/// places (`0.000`). Applied whenever a formula result is turned into
/// `result_text`, so the double's full precision (0.68000000000000002 and
/// friends) never leaks into storage — every later reader (test history,
/// inspection reports, PDFs, notifications) then shows the same three
/// decimals. Returns '' for a null input.
String labResultText(num? value, {int decimals = 3}) =>
    value == null ? '' : value.toDouble().toStringAsFixed(decimals);
