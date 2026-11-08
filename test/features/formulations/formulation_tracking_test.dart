import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_lab/features/formulations/domain/formulation_calculator.dart';
import 'package:material_lab/features/formulations/domain/formulation_timeline.dart';
import 'package:material_lab/features/formulations/domain/formulation_tracking.dart';

class _CountingReceipt extends MaterialReceipt {
  _CountingReceipt()
    : super(
        materialId: 1,
        code: 'HISTORY',
        receivedAt: DateTime(2025),
        source: 'inspection',
        values: const {'protein': 10},
        inspectionValues: const {'protein': 10},
        labHistory: {
          'protein': [
            ParameterObservation(sample: 'A', at: DateTime(2026, 2), value: 20),
            ParameterObservation(sample: 'A', at: DateTime(2026, 8), value: 40),
          ],
        },
      );

  int resolutions = 0;
  @override
  MaterialReceipt at(
    DateTime end, {
    FormulationDataSource dataSource = FormulationDataSource.all,
  }) {
    resolutions++;
    return super.at(end, dataSource: dataSource);
  }
}

void main() {
  const ingredients = [
    FormulationIngredient(materialId: 1, name: 'Maize', quantityKg: 75),
    FormulationIngredient(materialId: 2, name: 'Soy', quantityKg: 25),
  ];
  final from = DateTime(2026);
  final to = DateTime(2026, 12, 31);
  final buckets = formulationChartBuckets(
    from: from,
    to: to,
    interval: FormulationChartInterval.day,
  );

  test('daily history resolves each distinct observation state only once', () {
    final receipt = _CountingReceipt();
    final result = calculateFormulationTracking(
      FormulationTrackingRequest(
        ingredients: const [
          FormulationIngredient(materialId: 1, name: 'Maize', quantityKg: 100),
        ],
        receipts: [receipt],
        from: from,
        to: to,
        buckets: buckets,
        parameters: const {'protein'},
        aggregation: FormulationAggregation.minimum,
        dataSource: FormulationDataSource.all,
      ),
    );
    expect(result.series['protein'], hasLength(365));
    expect(result.series['protein']!.first, 10);
    expect(result.series['protein']![31], 15);
    expect(result.series['protein']!.last, 25);
    // Summary + 365 daily buckets used to replay the entire lab history
    // several times each. There are only three actual temporal states.
    expect(receipt.resolutions, 3);
  });

  test('daily tracking preserves every aggregation, source and fallback', () {
    final receipts = <MaterialReceipt>[
      _CountingReceipt(),
      MaterialReceipt(
        materialId: 1,
        code: 'SECOND',
        receivedAt: DateTime(2026, 4),
        source: 'inspection',
        values: const {'protein': 30, 'density': 1},
        physicalKeys: const {'density'},
      ),
      MaterialReceipt(
        materialId: 2,
        code: 'FUTURE',
        receivedAt: DateTime(2026, 6),
        source: 'lab',
        values: const {'protein': 60},
      ),
    ];
    for (final source in FormulationDataSource.values) {
      for (final aggregation in FormulationAggregation.values) {
        final result = calculateFormulationTracking(
          FormulationTrackingRequest(
            ingredients: ingredients,
            receipts: receipts,
            from: from,
            to: to,
            buckets: buckets,
            parameters: const {'protein', 'density'},
            aggregation: aggregation,
            dataSource: source,
          ),
        );
        expect(result.series.containsKey('density'), false);
        for (var i = 0; i < buckets.length; i++) {
          final expected = FormulationCalculator.calculate(
            ingredients: ingredients,
            averages: FormulationCalculator.averages(
              materialIds: [1, 2],
              receipts: receipts,
              from: buckets[i].from,
              to: buckets[i].to,
              aggregation: aggregation,
              dataSource: source,
            ),
          );
          expect(
            result.series['protein']![i],
            expected.parameters['protein'],
            reason: '${source.name}/${aggregation.name}/$i',
          );
        }
      }
    }
  });

  test(
    'large daily Min/Max work runs in an isolate while UI events continue',
    () async {
      final receipts = [
        for (var i = 0; i < 600; i++)
          MaterialReceipt(
            materialId: i.isEven ? 1 : 2,
            code: 'R$i',
            receivedAt: DateTime(2025, 1, i + 1),
            source: 'inspection',
            values: {'protein': 10 + (i % 30).toDouble()},
            inspectionValues: {'protein': 10 + (i % 30).toDouble()},
            labHistory: {
              'protein': [
                for (var month = 1; month <= 12; month++)
                  ParameterObservation(
                    sample: 'A',
                    at: DateTime(2026, month),
                    value: 20 + (i % 30).toDouble(),
                  ),
              ],
            },
          ),
      ];
      for (final aggregation in [
        FormulationAggregation.minimum,
        FormulationAggregation.maximum,
      ]) {
        final request = FormulationTrackingRequest(
          ingredients: ingredients,
          receipts: receipts,
          from: from,
          to: to,
          buckets: buckets,
          parameters: const {'protein'},
          aggregation: aggregation,
          dataSource: FormulationDataSource.all,
        );
        expect(request.needsIsolate, true);
        var heartbeats = 0;
        final timer = Timer.periodic(
          const Duration(milliseconds: 1),
          (_) => heartbeats++,
        );
        final watch = Stopwatch()..start();
        late FormulationTrackingResult result;
        try {
          result = await compute(calculateFormulationTracking, request);
        } finally {
          timer.cancel();
        }
        expect(heartbeats, greaterThan(0));
        expect(result.series['protein'], hasLength(365));
        expect(
          result.series['protein']!.every(
            (value) => value != null && value.isFinite,
          ),
          true,
        );
        // Recorded for diagnosis; no machine-dependent timing assertion.
        // ignore: avoid_print
        print(
          '${aggregation.name}: 600 receipts / 7200 observations / 365 points in ${watch.elapsedMilliseconds}ms; $heartbeats event-loop ticks',
        );
      }
    },
  );
}
