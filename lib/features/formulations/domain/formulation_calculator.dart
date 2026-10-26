import 'dart:math' as math;

String formulationParameterKey(String name) {
  final normalized = name.trim().toLowerCase();
  const aliases = <String, String>{
    'protein': 'protein',
    'crude protein': 'protein',
    'بروتين': 'protein',
    'بروتين خام': 'protein',
    'fat': 'fat',
    'crude fat': 'fat',
    'دهون': 'fat',
    'دهن': 'fat',
    'moisture': 'moisture',
    'humidity': 'moisture',
    'رطوبة': 'moisture',
  };
  return aliases[normalized] ?? normalized;
}

class MaterialReceipt {
  const MaterialReceipt({
    required this.materialId,
    required this.code,
    required this.receivedAt,
    required this.source,
    required this.values,
    this.sources = const {},
    this.analysisAt,
    this.inspectionValues = const {},
    this.labHistory = const {},
    this.parameterDates = const {},
    this.physicalKeys = const {},
  });
  final int materialId;
  final String code;
  final DateTime receivedAt;
  final String source;
  final DateTime? analysisAt;
  final Map<String, double> values;
  final Map<String, String> sources;
  final Map<String, double> inspectionValues;
  final Map<String, List<ParameterObservation>> labHistory;
  final Map<String, DateTime> parameterDates;

  /// Parameters sourced from the receipt's *physical* results only (density,
  /// separation, visual checks…). These are not nutrition parameters: the
  /// formulation chart/metrics must never offer them as analysis series.
  final Set<String> physicalKeys;

  /// Resolve the latest test for each sample as it existed at this chart
  /// point. Later laboratory results must not rewrite an earlier period.
  MaterialReceipt at(DateTime end) {
    if (labHistory.isEmpty) return this;
    final resolved = Map<String, double>.from(inspectionValues);
    final origins = {for (final key in resolved.keys) key: 'inspection'};
    final dates = <String, DateTime>{};
    DateTime? latest;
    for (final entry in labHistory.entries) {
      final samples = <String, ParameterObservation>{};
      for (final observation in entry.value) {
        if (observation.at.isAfter(end)) continue;
        final previous = samples[observation.sample];
        if (previous == null || observation.at.isAfter(previous.at)) {
          samples[observation.sample] = observation;
        }
      }
      if (samples.isEmpty) continue;
      // A reported but non-numeric lab result supersedes the other source;
      // it cannot silently become zero or fall back to the receipt's value.
      resolved.remove(entry.key);
      origins.remove(entry.key);
      final numbers = samples.values
          .map((e) => e.value)
          .whereType<double>()
          .toList();
      if (numbers.isNotEmpty) {
        resolved[entry.key] = numbers.reduce((a, b) => a + b) / numbers.length;
        origins[entry.key] = 'lab';
      }
      for (final observation in samples.values) {
        final previousDate = dates[entry.key];
        if (previousDate == null || observation.at.isAfter(previousDate)) {
          dates[entry.key] = observation.at;
        }
        if (latest == null || observation.at.isAfter(latest)) {
          latest = observation.at;
        }
      }
    }
    return MaterialReceipt(
      materialId: materialId,
      code: code,
      receivedAt: receivedAt,
      source: source,
      values: resolved,
      sources: origins,
      analysisAt: latest,
      parameterDates: dates,
      physicalKeys: physicalKeys,
    );
  }
}

class ParameterObservation {
  const ParameterObservation({
    required this.sample,
    required this.at,
    required this.value,
  });
  final String sample;
  final DateTime at;
  final double? value;
}

class FormulationIngredient {
  const FormulationIngredient({
    required this.materialId,
    required this.name,
    required this.quantityKg,
    this.pricePerKg,
  });
  final int materialId;
  final String name;
  final double quantityKg;
  final double? pricePerKg;
}

class ParameterAverage {
  const ParameterAverage({
    required this.value,
    required this.source,
    required this.receipts,
    required this.receiptCode,
    required this.receiptDate,
    required this.usedFallback,
  });
  final double? value;
  final String source;
  final int receipts;
  final String receiptCode;
  final DateTime receiptDate;
  final bool usedFallback;
}

class IngredientResult {
  const IngredientResult({
    required this.ingredient,
    required this.share,
    required this.cost,
    required this.parameters,
  });
  final FormulationIngredient ingredient;
  final double share;
  final double? cost;
  final Map<String, ParameterAverage> parameters;
}

class FormulationResult {
  const FormulationResult({
    required this.totalKg,
    required this.totalCost,
    required this.costPerKg,
    required this.parameters,
    required this.ingredients,
  });
  final double totalKg;
  final double? totalCost;
  final double? costPerKg;
  final Map<String, double?> parameters;
  final List<IngredientResult> ingredients;
}

/// How multiple receipts of the same material combine into one parameter
/// value: the mean (current default), or the best/worst-case single value.
enum FormulationAggregation { average, minimum, maximum }

abstract final class FormulationCalculator {
  static const names = <String, String>{
    'protein': 'Protein',
    'fat': 'Fat',
    'moisture': 'Moisture',
  };

  static double? number(Object? raw) {
    if (raw is num) return raw.isFinite ? raw.toDouble() : null;
    if (raw == null) return null;
    var text = '$raw'.trim().replaceAll('٫', '.').replaceAll('٬', '');
    if (text.isEmpty ||
        text == '-' ||
        text.contains('<') ||
        text.contains('>')) {
      return null;
    }
    const ar = '٠١٢٣٤٥٦٧٨٩';
    for (var i = 0; i < ar.length; i++) {
      text = text.replaceAll(ar[i], '$i');
    }
    final parsed = double.tryParse(text.replaceAll(',', '.'));
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  /// Each receipt contributes one value, regardless of its delivered weight.
  /// The caller supplies only the preferred source for each receipt/parameter.
  static Map<int, Map<String, ParameterAverage>> averages({
    required Iterable<int> materialIds,
    required List<MaterialReceipt> receipts,
    required DateTime from,
    required DateTime to,
    bool fallback = true,
    FormulationAggregation aggregation = FormulationAggregation.average,
  }) {
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day, 23, 59, 59, 999);
    final out = <int, Map<String, ParameterAverage>>{};
    for (final id in materialIds.toSet()) {
      final rows = receipts
          .where((e) => e.materialId == id)
          .map((e) => e.at(end))
          .toList();
      final keys = <String>{for (final row in rows) ...row.values.keys};
      final values = <String, ParameterAverage>{};
      for (final key in keys) {
        final current =
            rows
                .where(
                  (row) =>
                      !row.receivedAt.isBefore(start) &&
                      !row.receivedAt.isAfter(end) &&
                      row.values[key] != null,
                )
                .toList()
              ..sort((a, b) => a.receivedAt.compareTo(b.receivedAt));
        if (current.isNotEmpty) {
          // Min/max modes answer "what is the lowest/highest blended analysis
          // this formulation could ever give": each material contributes its
          // extreme observed value instead of the mean.
          final chosen = switch (aggregation) {
            FormulationAggregation.average => null,
            FormulationAggregation.minimum => current.reduce(
              (a, b) => a.values[key]! <= b.values[key]! ? a : b,
            ),
            FormulationAggregation.maximum => current.reduce(
              (a, b) => a.values[key]! >= b.values[key]! ? a : b,
            ),
          };
          final value = chosen != null
              ? chosen.values[key]
              : current.fold<double>(0, (sum, row) => sum + row.values[key]!) /
                    current.length;
          final sources = current
              .map((row) => row.sources[key] ?? row.source)
              .toSet();
          values[key] = ParameterAverage(
            value: value,
            source: sources.length == 1 ? sources.single : 'mixed',
            receipts: current.length,
            receiptCode: chosen?.code ?? current.last.code,
            receiptDate:
                chosen?.parameterDates[key] ??
                chosen?.receivedAt ??
                current.last.parameterDates[key] ??
                current.last.receivedAt,
            usedFallback: false,
          );
          continue;
        }
        if (!fallback) continue;
        final previous =
            rows
                .where(
                  (row) =>
                      !row.receivedAt.isAfter(end) && row.values[key] != null,
                )
                .toList()
              ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
        if (previous.isNotEmpty) {
          // Min/max keep that promise even on fallback: the extreme previous
          // value, not merely the most recent one.
          final row = switch (aggregation) {
            FormulationAggregation.average => previous.first,
            FormulationAggregation.minimum => previous.reduce(
              (a, b) => a.values[key]! <= b.values[key]! ? a : b,
            ),
            FormulationAggregation.maximum => previous.reduce(
              (a, b) => a.values[key]! >= b.values[key]! ? a : b,
            ),
          };
          values[key] = ParameterAverage(
            value: row.values[key],
            source: row.sources[key] ?? row.source,
            receipts: 1,
            receiptCode: row.code,
            receiptDate: row.parameterDates[key] ?? row.receivedAt,
            usedFallback: true,
          );
        }
      }
      out[id] = values;
    }
    return out;
  }

  static FormulationResult calculate({
    required List<FormulationIngredient> ingredients,
    required Map<int, Map<String, ParameterAverage>> averages,
  }) {
    final total = ingredients.fold<double>(
      0,
      (sum, row) => sum + math.max(0, row.quantityKg),
    );
    final validQuantities =
        ingredients.isNotEmpty &&
        ingredients.every(
          (row) => row.quantityKg.isFinite && row.quantityKg > 0,
        );
    final completeCost =
        validQuantities &&
        ingredients.every(
          (row) =>
              row.pricePerKg != null &&
              row.pricePerKg!.isFinite &&
              row.pricePerKg! >= 0,
        );
    final cost = completeCost
        ? ingredients.fold<double>(
            0,
            (sum, row) => sum + row.quantityKg * row.pricePerKg!,
          )
        : null;
    final keys = <String>{for (final row in averages.values) ...row.keys};
    final parameters = <String, double?>{};
    for (final key in keys) {
      final values = <(double, double)>[];
      for (final row in ingredients) {
        final value = averages[row.materialId]?[key]?.value;
        if (value == null) {
          values.clear();
          break;
        }
        values.add((row.quantityKg, value));
      }
      parameters[key] =
          validQuantities && total > 0 && values.length == ingredients.length
          ? values.fold<double>(0, (sum, pair) => sum + pair.$1 * pair.$2) /
                total
          : null;
    }
    return FormulationResult(
      totalKg: total,
      totalCost: cost,
      costPerKg: cost == null || total <= 0 ? null : cost / total,
      parameters: parameters,
      ingredients: [
        for (final row in ingredients)
          IngredientResult(
            ingredient: row,
            share: total > 0 ? row.quantityKg * 100 / total : 0,
            cost: row.pricePerKg == null
                ? null
                : row.quantityKg * row.pricePerKg!,
            parameters: averages[row.materialId] ?? const {},
          ),
      ],
    );
  }
}
