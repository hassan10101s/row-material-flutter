enum FormulationChartInterval { automatic, day, week, month }

class FormulationChartBucket {
  const FormulationChartBucket(this.from, this.to);
  final DateTime from;
  final DateTime to;
}

/// Business weeks run Saturday through Friday. Partial edge weeks are clipped
/// to the selected period. Calendar constructors avoid DST duration drift.
List<FormulationChartBucket> formulationChartBuckets({
  required DateTime from,
  required DateTime to,
  FormulationChartInterval interval = FormulationChartInterval.automatic,
  bool monthlyPeriod = false,
}) {
  final first = DateTime(from.year, from.month, from.day);
  final last = DateTime(to.year, to.month, to.day);
  if (last.isBefore(first)) return const [];
  final step = interval == FormulationChartInterval.automatic
      ? monthlyPeriod || last.difference(first).inDays < 31
            ? FormulationChartInterval.day
            : FormulationChartInterval.month
      : interval;
  final result = <FormulationChartBucket>[];
  var cursor = first;
  while (!cursor.isAfter(last)) {
    final boundary = switch (step) {
      FormulationChartInterval.week => DateTime(
        cursor.year,
        cursor.month,
        cursor.day + (DateTime.friday - cursor.weekday + 7) % 7,
      ),
      FormulationChartInterval.month => DateTime(
        cursor.year,
        cursor.month + 1,
        0,
      ),
      _ => cursor,
    };
    final end = boundary.isAfter(last) ? last : boundary;
    result.add(FormulationChartBucket(cursor, end));
    cursor = DateTime(end.year, end.month, end.day + 1);
  }
  return result;
}
