import 'formulation_calculator.dart';
import 'formulation_timeline.dart';

/// Contains only calculation data: safe to send to a background isolate.
class FormulationTrackingRequest {
  const FormulationTrackingRequest({
    required this.ingredients,
    required this.receipts,
    required this.from,
    required this.to,
    required this.buckets,
    required this.parameters,
    required this.aggregation,
    required this.dataSource,
  });

  final List<FormulationIngredient> ingredients;
  final List<MaterialReceipt> receipts;
  final DateTime from;
  final DateTime to;
  final List<FormulationChartBucket> buckets;
  final Set<String> parameters;
  final FormulationAggregation aggregation;
  final FormulationDataSource dataSource;

  // Small previews avoid isolate startup overhead. History lengths count too:
  // a single receipt can contain years of repeated laboratory observations.
  bool get needsIsolate {
    var work = receipts.length;
    for (final receipt in receipts) {
      work += receipt.values.length + receipt.inspectionValues.length;
      for (final history in receipt.labHistory.values) {
        work += history.length;
      }
    }
    return work * (buckets.length + 1) >= 20000;
  }
}

class FormulationTrackingResult {
  const FormulationTrackingResult(this.current, this.series);
  final FormulationResult current;
  final Map<String, List<double?>> series;
}

FormulationTrackingResult calculateFormulationTracking(
  FormulationTrackingRequest request,
) {
  final ids = request.ingredients.map((row) => row.materialId).toSet();
  final index = FormulationReceiptIndex(
    receipts: request.receipts,
    materialIds: ids,
    dataSource: request.dataSource,
  );
  FormulationResult calculate(DateTime from, DateTime to) =>
      FormulationCalculator.calculate(
        ingredients: request.ingredients,
        averages: FormulationCalculator.averages(
          materialIds: ids,
          receipts: request.receipts,
          from: from,
          to: to,
          aggregation: request.aggregation,
          dataSource: request.dataSource,
          prepared: index,
        ),
      );

  final current = calculate(request.from, request.to);
  final physical = {for (final row in request.receipts) ...row.physicalKeys};
  final series = {
    for (final key in request.parameters)
      if (!physical.contains(key)) key: <double?>[],
  };
  for (final bucket in request.buckets) {
    final result = calculate(bucket.from, bucket.to);
    for (final entry in series.entries) {
      entry.value.add(result.parameters[entry.key]);
    }
  }
  return FormulationTrackingResult(current, series);
}
