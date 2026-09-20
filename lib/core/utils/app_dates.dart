/// Date/time helpers mirroring core/utils.py (now_iso, today_iso, parse).
library;

String nowIso() {
  final now = DateTime.now();
  return '${_pad2(now.year)}-${_pad2(now.month)}-${_pad2(now.day)} '
      '${_pad2(now.hour)}:${_pad2(now.minute)}:${_pad2(now.second)}';
}

String todayIso() {
  final now = DateTime.now();
  return '${_pad2(now.year)}-${_pad2(now.month)}-${_pad2(now.day)}';
}

/// Compact timestamp mirroring `datetime.now().strftime('%Y%m%d_%H%M%S')`
/// used in backup/label file names.
String fileTimestamp([DateTime? when]) {
  final now = when ?? DateTime.now();
  return '${now.year}${_pad2(now.month)}${_pad2(now.day)}_'
      '${_pad2(now.hour)}${_pad2(now.minute)}${_pad2(now.second)}';
}

String _pad2(int n) => n.toString().padLeft(2, '0');

/// Parse a Python-style ISO datetime like "2026-09-20T14:30:00" or with
/// fractional seconds, or a bare date "2026-09-20".
DateTime? parseIsoDate(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final t = value.trim();
  try {
    if (t.length >= 10) {
      final datePart = t.substring(0, 10);
      final parts = datePart.split('-');
      final year = int.parse(parts[0]);
      final month = int.parse(parts[1]);
      final day = int.parse(parts[2]);
      if (t.length > 10) {
        final timeRaw = t.substring(11);
        final timePart = timeRaw.split(' ').first;
        final tf = timePart.split(':');
        final hour = int.parse(tf[0]);
        final minute = tf.length > 1 ? int.parse(tf[1]) : 0;
        final secRaw = tf.length > 2 ? tf[2] : '0';
        final sec = int.parse(secRaw.split('.')[0]);
        return DateTime(year, month, day, hour, minute, sec);
      }
      return DateTime(year, month, day);
    }
  } catch (_) {
    return null;
  }
  return null;
}

String? parseIsoToDisplay(String? value) {
  final d = parseIsoDate(value);
  if (d == null) return value;
  return '${_pad2(d.day)}/${_pad2(d.month)}/${d.year}';
}

/// Shift window for daily reports: 8:00 today -> 8:00 next day.
DateTime dailyShiftStart(DateTime date) =>
    DateTime(date.year, date.month, date.day, 8, 0);

DateTime dailyShiftEnd(DateTime date) =>
    dailyShiftStart(date).add(const Duration(hours: 24));

/// Is [dateTime] inside the daily shift window starting at [shiftDate]?
bool inDailyShift(DateTime dateTime, DateTime shiftDate) {
  final start = dailyShiftStart(shiftDate);
  final end = dailyShiftEnd(shiftDate);
  return !dateTime.isBefore(start) && dateTime.isBefore(end);
}