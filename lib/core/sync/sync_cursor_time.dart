/// Firestore orders timestamps at nanosecond precision. DateTime drops the
/// last three digits, so it cannot round-trip a pagination anchor by itself.
class SyncCursorTime {
  const SyncCursorTime(this.seconds, this.nanoseconds);

  final int seconds;
  final int nanoseconds;

  factory SyncCursorTime.parse(String value) {
    final zoned = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(value)
        ? value
        : '${value}Z';
    final date = DateTime.parse(zoned).toUtc();
    final fraction =
        RegExp(r'\.(\d+)(?:Z|[+-]\d{2}:?\d{2})$').firstMatch(zoned)?.group(1) ??
        '';
    if (fraction.length > 9) {
      throw FormatException('Invalid cursor precision', value);
    }
    final secondStart =
        date.microsecondsSinceEpoch -
        date.millisecond * 1000 -
        date.microsecond;
    return SyncCursorTime(
      secondStart ~/ 1000000,
      int.parse(fraction.padRight(9, '0')),
    );
  }

  String get iso {
    final date = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    );
    return '${date.toIso8601String().substring(0, 19)}.${nanoseconds.toString().padLeft(9, '0')}Z';
  }

  static int compare(String a, String b) {
    if (a.isEmpty || b.isEmpty) return a.compareTo(b);
    final left = SyncCursorTime.parse(a);
    final right = SyncCursorTime.parse(b);
    final seconds = left.seconds.compareTo(right.seconds);
    return seconds != 0
        ? seconds
        : left.nanoseconds.compareTo(right.nanoseconds);
  }
}
