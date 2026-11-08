import '../../../core/utils/app_exceptions.dart';
import '../../../core/constants/app_strings.dart';

/// Inclusive calendar days, in the device's local time zone.
class ConsumptionPeriod {
  ConsumptionPeriod(DateTime from, DateTime to)
    : from = DateTime(from.year, from.month, from.day),
      to = DateTime(to.year, to.month, to.day) {
    if (this.from.isAfter(this.to)) {
      throw ValidationError(
        AppText.t(
          'تاريخ البداية يجب ألا يتجاوز تاريخ النهاية',
          'Start date must not follow end date',
        ),
      );
    }
  }

  factory ConsumptionPeriod.lastThreeMonths(DateTime today) {
    final month = DateTime(today.year, today.month - 3);
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    return ConsumptionPeriod(
      DateTime(
        month.year,
        month.month,
        today.day > lastDay ? lastDay : today.day,
      ),
      today,
    );
  }

  final DateTime from;
  final DateTime to;
  DateTime get exclusiveEnd => DateTime(to.year, to.month, to.day + 1);
  static String date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  String get label => '${date(from)} - ${date(to)}';
}

class ChemicalConsumptionRow {
  const ChemicalConsumptionRow({
    required this.inventoryId,
    required this.name,
    required this.unit,
    required this.consumed,
    required this.returned,
  });
  final int inventoryId;
  final String name;
  final String unit;
  final double consumed;
  final double returned;
  double get net {
    final difference = consumed - returned;
    // Suppress cancellation noise such as 0.1 + 0.2 - 0.3, keeping actual
    // small quantities when they are not floating-point residue.
    return difference.abs() <= (consumed.abs() + returned.abs()) * 1e-14
        ? 0
        : difference;
  }

  static String quantity(double value) {
    // Keep small genuine quantities visible rather than rounding them to zero.
    if (value != 0 && value.abs() < 0.000001) {
      return value.toStringAsPrecision(6);
    }
    return value.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');
  }
}

class ChemicalConsumptionReport {
  ChemicalConsumptionReport({
    required this.period,
    required List<ChemicalConsumptionRow> chemicals,
    this.inventoryId,
  }) : chemicals = List.unmodifiable(chemicals);
  final ConsumptionPeriod period;
  final int? inventoryId;
  final List<ChemicalConsumptionRow> chemicals;
  List<ChemicalConsumptionRow> get rows => inventoryId == null
      ? chemicals
      : chemicals
            .where((row) => row.inventoryId == inventoryId)
            .toList(growable: false);
}
