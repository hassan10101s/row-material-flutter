import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/formulations/domain/formulation_calculator.dart';

void main() {
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

  test(
    'missing material uses only the last earlier receipt, never a future one',
    () {
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
      expect(result.parameters['protein'], isNull);
      expect(result.totalCost, isNull);
    },
  );

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
      expect(value(6), 25);
      expect(value(15), 35);
    },
  );

  test(
    'non-numeric laboratory result does not silently restore inspection value',
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
        row.at(DateTime(2026, 1, 3)).values.containsKey('protein'),
        isFalse,
      );
    },
  );
}
