import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/formulations/domain/formulation_calculator.dart';
import 'package:material_lab/features/formulations/domain/formulation_timeline.dart';

void main() {
  test(
    'All combines source means; Lab and NIR only never borrow across sources or future dates',
    () {
      final row = MaterialReceipt(
        materialId: 1,
        code: 'R',
        receivedAt: DateTime(2026, 1, 1),
        source: 'inspection',
        values: const {'protein': 22},
        inspectionValues: const {'protein': 20},
        labHistory: {
          'protein': [
            ParameterObservation(
              sample: 'A',
              at: DateTime(2026, 1, 2),
              value: 22,
            ),
            ParameterObservation(
              sample: 'A',
              at: DateTime(2026, 1, 10),
              value: 80,
            ),
          ],
        },
      );
      final end = DateTime(2026, 1, 5);
      expect(row.at(end).values['protein'], 21);
      expect(row.at(end).sources['protein'], 'mixed');
      expect(
        row.at(end, dataSource: FormulationDataSource.lab).values['protein'],
        22,
      );
      expect(
        row.at(end, dataSource: FormulationDataSource.nir).values['protein'],
        20,
      );
      expect(
        row
            .at(DateTime(2026, 1, 1), dataSource: FormulationDataSource.lab)
            .values,
        isEmpty,
      );
      for (final source in FormulationDataSource.values) {
        final result = FormulationCalculator.averages(
          materialIds: [1],
          receipts: [row],
          from: DateTime(2026, 1, 1),
          to: end,
          dataSource: source,
        );
        expect(
          result[1]!['protein']!.value,
          {
            FormulationDataSource.all: 21,
            FormulationDataSource.lab: 22,
            FormulationDataSource.nir: 20,
          }[source],
        );
      }
    },
  );
  List<MaterialReceipt> receipts(List<double> numbers) => [
    for (var i = 0; i < numbers.length; i++)
      MaterialReceipt(
        materialId: 1,
        code: 'R-$i',
        receivedAt: DateTime(2026, 1, i + 1),
        source: 'inspection',
        values: {'protein': numbers[i]},
      ),
  ];
  test(
    'Mode chooses highest equally frequent value and preserves its latest provenance',
    () {
      final result = FormulationCalculator.averages(
        materialIds: [1],
        receipts: receipts([10, 10, 12, 12, 8]),
        from: DateTime(2026, 1),
        to: DateTime(2026, 1, 31),
        aggregation: FormulationAggregation.mode,
      )[1]!['protein']!;
      expect(result.value, 12);
      expect(result.receiptCode, 'R-3');
      expect(result.usedFallback, isFalse);
    },
  );
  test(
    'Mode is frequency first, not maximum; same rule holds on historical fallback',
    () {
      for (final month in [1, 2]) {
        final result = FormulationCalculator.averages(
          materialIds: [1],
          receipts: receipts([10, 10, 10, 50, 50]),
          from: DateTime(2026, month),
          to: DateTime(2026, month + 1, 0),
          aggregation: FormulationAggregation.mode,
        )[1]!['protein']!;
        expect(result.value, 10);
        expect(result.usedFallback, month == 2);
      }
    },
  );
  test(
    'weekly points are Saturday to Friday, clipped to period with no gaps or overlap',
    () {
      final rows = formulationChartBuckets(
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 1, 31),
        interval: FormulationChartInterval.week,
      );
      expect(rows, hasLength(6));
      expect(rows.first.from, DateTime(2026, 1, 1));
      expect(rows.first.to, DateTime(2026, 1, 2));
      expect(rows[1].from, DateTime(2026, 1, 3));
      expect(rows[1].to, DateTime(2026, 1, 9));
      expect(rows.last.to, DateTime(2026, 1, 31));
      for (var i = 1; i < rows.length; i++) {
        expect(rows[i].from.weekday, DateTime.saturday);
        expect(
          rows[i].from,
          DateTime(
            rows[i - 1].to.year,
            rows[i - 1].to.month,
            rows[i - 1].to.day + 1,
          ),
        );
      }
    },
  );
  test(
    'calendar grouping crosses year and leap day without losing edge days',
    () {
      final weeks = formulationChartBuckets(
        from: DateTime(2025, 12, 31),
        to: DateTime(2026, 1, 10),
        interval: FormulationChartInterval.week,
      );
      expect(weeks.first.to, DateTime(2026, 1, 2));
      expect(weeks[1].from, DateTime(2026, 1, 3));
      final days = formulationChartBuckets(
        from: DateTime(2024, 2, 28),
        to: DateTime(2024, 3, 1),
        interval: FormulationChartInterval.day,
      );
      expect(days, hasLength(3));
      expect(days[1].from, DateTime(2024, 2, 29));
    },
  );
}
