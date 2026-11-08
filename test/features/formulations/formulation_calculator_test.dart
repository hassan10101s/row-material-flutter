import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/formulations/domain/formulation_calculator.dart';

void main() {
  test(
    'moisture-only material keeps protein across the wider history, with zero contribution',
    () {
      final receipts = [
        MaterialReceipt(
          materialId: 1,
          code: 'FULL',
          receivedAt: DateTime(2026, 1, 1),
          source: 'inspection',
          values: const {'protein': 40, 'fat': 8},
        ),
        MaterialReceipt(
          materialId: 2,
          code: 'WATER',
          receivedAt: DateTime(2026, 6, 1),
          source: 'inspection',
          values: const {'moisture': 10},
        ),
      ];
      for (final month in [1, 6, 11]) {
        final averages = FormulationCalculator.averages(
          materialIds: [1, 2],
          receipts: receipts,
          from: DateTime(2026, month),
          to: DateTime(2026, month + 1, 0),
        );
        final result = FormulationCalculator.calculate(
          ingredients: const [
            FormulationIngredient(materialId: 1, name: 'Full', quantityKg: 75),
            FormulationIngredient(
              materialId: 2,
              name: 'Moisture only',
              quantityKg: 25,
            ),
          ],
          averages: averages,
        );
        expect(result.parameters, {'protein': 30, 'fat': 6, 'moisture': 2.5});
        expect(averages[2]!['protein']!.source, 'missing');
        expect(averages[2]!['protein']!.receipts, 0);
      }
    },
  );

  MaterialReceipt receipt(int id, int day, double protein) => MaterialReceipt(
    materialId: id,
    code: 'R$id-$day',
    receivedAt: DateTime(2026, 1, day),
    source: 'inspection',
    values: {'protein': protein},
  );
  test(
    'receipts have equal weight; ingredient quantities weight the formula',
    () {
      final averages = FormulationCalculator.averages(
        materialIds: [1, 2],
        receipts: [receipt(1, 1, 10), receipt(1, 3, 30), receipt(2, 2, 40)],
        from: DateTime(2026, 1),
        to: DateTime(2026, 1, 31),
      );
      final result = FormulationCalculator.calculate(
        ingredients: const [
          FormulationIngredient(
            materialId: 1,
            name: 'A',
            quantityKg: 75,
            pricePerKg: 2,
          ),
          FormulationIngredient(
            materialId: 2,
            name: 'B',
            quantityKg: 25,
            pricePerKg: 4,
          ),
        ],
        averages: averages,
      );
      expect(averages[1]!['protein']!.value, 20);
      expect(result.parameters['protein'], 25);
      expect(result.totalKg, 100);
      expect(result.totalCost, 250);
      expect(result.costPerKg, 2.5);
    },
  );

  test('missing material prefers the last earlier receipt over later data', () {
    final averages = FormulationCalculator.averages(
      materialIds: [1, 2],
      receipts: [receipt(1, 1, 10), receipt(1, 8, 20), receipt(1, 22, 80)],
      from: DateTime(2026, 1, 10),
      to: DateTime(2026, 1, 20),
    );
    expect(averages[1]!['protein']!.value, 20);
    expect(averages[1]!['protein']!.usedFallback, isTrue);
    final result = FormulationCalculator.calculate(
      ingredients: const [
        FormulationIngredient(materialId: 1, name: 'A', quantityKg: 50),
        FormulationIngredient(materialId: 2, name: 'B', quantityKg: 50),
      ],
      averages: averages,
    );
    expect(result.parameters['protein'], 10);
    expect(result.totalCost, isNull);
  });

  test('an earlier value always wins over a much closer later value', () {
    final result = FormulationCalculator.averages(
      materialIds: [1],
      receipts: [receipt(1, 1, 10), receipt(1, 21, 90)],
      from: DateTime(2026, 1, 19),
      to: DateTime(2026, 1, 20),
    )[1]!['protein']!;
    expect(result.value, 10);
    expect(result.receiptCode, 'R1-1');
    expect(result.usedFallback, isTrue);
    expect(result.usedFutureFallback, isFalse);
  });

  test(
    'missing parameters borrow independently from the nearest later receipt only when no past exists',
    () {
      final result = FormulationCalculator.averages(
        materialIds: [1],
        receipts: [
          receipt(1, 21, 20),
          receipt(1, 25, 80),
          MaterialReceipt(
            materialId: 1,
            code: 'FAT',
            receivedAt: DateTime(2026, 1, 23),
            source: 'inspection',
            values: const {'fat': 5},
          ),
        ],
        from: DateTime(2026, 1, 1),
        to: DateTime(2026, 1, 10),
      )[1]!;
      expect(result['protein']!.value, 20);
      expect(result['protein']!.receiptDate, DateTime(2026, 1, 21));
      expect(result['protein']!.usedFutureFallback, isTrue);
      expect(result['fat']!.value, 5);
      expect(result['fat']!.receiptCode, 'FAT');
      expect(result['fat']!.usedFutureFallback, isTrue);
    },
  );

  test(
    'nearest later lab observation fills a missing lab value without borrowing NIR',
    () {
      final row = MaterialReceipt(
        materialId: 1,
        code: 'LAB',
        receivedAt: DateTime(2026, 1, 1),
        source: 'inspection',
        values: const {},
        inspectionValues: const {'protein': 10},
        labHistory: {
          'protein': [
            ParameterObservation(
              sample: 'A',
              at: DateTime(2026, 1, 12),
              value: 22,
            ),
            ParameterObservation(
              sample: 'A',
              at: DateTime(2026, 1, 20),
              value: 90,
            ),
          ],
        },
      );
      final lab = FormulationCalculator.averages(
        materialIds: [1],
        receipts: [row],
        from: DateTime(2026, 1, 5),
        to: DateTime(2026, 1, 6),
        dataSource: FormulationDataSource.lab,
      )[1]!['protein']!;
      expect(lab.value, 22);
      expect(lab.receiptDate, DateTime(2026, 1, 12));
      expect(lab.usedFutureFallback, isTrue);
      final all = FormulationCalculator.averages(
        materialIds: [1],
        receipts: [row],
        from: DateTime(2026, 1, 5),
        to: DateTime(2026, 1, 6),
      )[1]!['protein']!;
      expect(all.value, 10);
      expect(all.usedFutureFallback, isFalse);
    },
  );

  test('an older valid lab value wins when the latest lab cell is missing', () {
    final row = MaterialReceipt(
      materialId: 1,
      code: 'LAB',
      receivedAt: DateTime(2026, 1, 1),
      source: 'inspection',
      values: const {},
      inspectionValues: const {'protein': 10},
      labHistory: {
        'protein': [
          ParameterObservation(
            sample: 'A',
            at: DateTime(2026, 1, 2),
            value: 22,
          ),
          ParameterObservation(
            sample: 'A',
            at: DateTime(2026, 1, 5),
            value: null,
          ),
          ParameterObservation(
            sample: 'A',
            at: DateTime(2026, 1, 12),
            value: 90,
          ),
        ],
      },
    );
    final value = FormulationCalculator.averages(
      materialIds: [1],
      receipts: [row],
      from: DateTime(2026, 1, 6),
      to: DateTime(2026, 1, 6),
      dataSource: FormulationDataSource.lab,
    )[1]!['protein']!;
    expect(value.value, 22);
    expect(value.receiptDate, DateTime(2026, 1, 2));
    expect(value.usedFutureFallback, isFalse);
    expect(
      FormulationCalculator.averages(
        materialIds: [1],
        receipts: [row],
        from: DateTime(2026, 1, 6),
        to: DateTime(2026, 1, 6),
        fallback: false,
        dataSource: FormulationDataSource.lab,
      )[1],
      isEmpty,
    );
  });

  test(
    'later lab results override the other source only from their test date',
    () {
      final row = MaterialReceipt(
        materialId: 1,
        code: 'R',
        receivedAt: DateTime(2026, 1, 1),
        source: 'inspection',
        values: const {'protein': 40},
        inspectionValues: const {'protein': 10},
        labHistory: {
          'protein': [
            ParameterObservation(
              sample: 'A',
              at: DateTime(2026, 1, 12),
              value: 40,
            ),
            ParameterObservation(
              sample: 'A',
              at: DateTime(2026, 1, 5),
              value: 20,
            ),
            ParameterObservation(
              sample: 'B',
              at: DateTime(2026, 1, 5),
              value: 30,
            ),
          ],
        },
      );
      double? value(int day) => FormulationCalculator.averages(
        materialIds: [1],
        receipts: [row],
        from: DateTime(2026, 1, day),
        to: DateTime(2026, 1, day),
      )[1]!['protein']?.value;
      expect(value(2), 10);
      expect(value(6), 17.5); // NIR 10 and the then-current lab mean 25.
      expect(value(15), 22.5); // NIR 10 and the later lab mean 35.
    },
  );

  test(
    'lab-only missing number never borrows NIR; all can still use valid NIR',
    () {
      final row = MaterialReceipt(
        materialId: 1,
        code: 'R',
        receivedAt: DateTime(2026, 1, 1),
        source: 'inspection',
        values: const {},
        inspectionValues: const {'protein': 10},
        labHistory: {
          'protein': [
            ParameterObservation(
              sample: 'A',
              at: DateTime(2026, 1, 2),
              value: null,
            ),
          ],
        },
      );
      expect(
        row
            .at(DateTime(2026, 1, 3), dataSource: FormulationDataSource.lab)
            .values
            .containsKey('protein'),
        isFalse,
      );
      expect(row.at(DateTime(2026, 1, 3)).values['protein'], 10);
    },
  );
}
