/// Formats numeric laboratory results for display without changing storage.
String formatLabResult(Object? value, {int decimals = 3}) {
  final raw = '${value ?? ''}'.trim();
  if (raw.isEmpty) return '-';
  final suffix = raw.endsWith('%') ? '%' : '';
  final numeric = double.tryParse(raw.replaceAll('%', '').trim());
  if (numeric == null) return raw;
  return '${numeric.toStringAsFixed(decimals)}$suffix';
}
