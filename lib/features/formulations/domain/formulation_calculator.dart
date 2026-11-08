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

enum FormulationDataSource { all, lab, nir }

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
  MaterialReceipt at(
    DateTime end, {
    FormulationDataSource dataSource = FormulationDataSource.all,
  }) {
    if (labHistory.isEmpty) {
      if (dataSource == FormulationDataSource.all) return this;
      final selected = <String, double>{};
      if (dataSource == FormulationDataSource.nir) {
        selected.addAll(inspectionValues);
      }
      for (final entry in values.entries) {
        final origin = sources[entry.key] ?? source;
        if ((dataSource == FormulationDataSource.lab && origin == 'lab') ||
            (dataSource == FormulationDataSource.nir &&
                origin == 'inspection')) {
          selected.putIfAbsent(entry.key, () => entry.value);
        }
      }
      return MaterialReceipt(
        materialId: materialId,
        code: code,
        receivedAt: receivedAt,
        source: source,
        values: selected,
        sources: {
          for (final key in selected.keys)
            key: dataSource == FormulationDataSource.lab ? 'lab' : 'inspection',
        },
        physicalKeys: physicalKeys,
        parameterDates: parameterDates,
      );
    }
    final resolved = dataSource == FormulationDataSource.lab
        ? <String, double>{}
        : Map<String, double>.from(inspectionValues);
    final origins = {for (final key in resolved.keys) key: 'inspection'};
    final dates = <String, DateTime>{};
    DateTime? latest;
    for (final entry in labHistory.entries) {
      if (dataSource == FormulationDataSource.nir) continue;
      final samples = <String, ParameterObservation>{};
      for (final observation in entry.value) {
        if (observation.at.isAfter(end)) continue;
        final previous = samples[observation.sample];
        if (previous == null || observation.at.isAfter(previous.at)) {
          samples[observation.sample] = observation;
        }
      }
      if (samples.isEmpty) continue;
      // Each source contributes one per-receipt mean. Missing laboratory
      // numbers never become zero or borrow NIR values in laboratory-only mode.
      final numbers = samples.values
          .map((e) => e.value)
          .whereType<double>()
          .toList();
      if (numbers.isNotEmpty) {
        final labMean = numbers.reduce((a, b) => a + b) / numbers.length;
        final nir = inspectionValues[entry.key];
        final combine = dataSource == FormulationDataSource.all && nir != null;
        resolved[entry.key] = combine ? (nir + labMean) / 2 : labMean;
        origins[entry.key] = combine ? 'mixed' : 'lab';
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
    this.usedFutureFallback = false,
  });
  final double? value;
  final String source;
  final int receipts;
  final String receiptCode;
  final DateTime receiptDate;
  final bool usedFallback;
  final bool usedFutureFallback;
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
enum FormulationAggregation { average, minimum, maximum, mode }

/// Reused within one tracking calculation. A receipt only changes when a lab
/// observation becomes available, not at every daily chart boundary.
class FormulationReceiptIndex {
  FormulationReceiptIndex({
    required this.receipts,
    required Iterable<int> materialIds,
    required this.dataSource,
  }) : materialIds = materialIds.toSet() {
    for (final receipt in receipts) {
      if (!this.materialIds.contains(receipt.materialId)) continue;
      byMaterial.putIfAbsent(receipt.materialId, () => []).add(receipt);
      availableKeys.addAll(receipt.values.keys);
      availableKeys.addAll(receipt.inspectionValues.keys);
      availableKeys.addAll(receipt.labHistory.keys);
    }
  }

  final List<MaterialReceipt> receipts;
  final Set<int> materialIds;
  final FormulationDataSource dataSource;
  final byMaterial = <int, List<MaterialReceipt>>{};
  final availableKeys = <String>{};
  final _dates = <MaterialReceipt, List<DateTime>>{};
  final _resolved = <MaterialReceipt, Map<int, MaterialReceipt>>{};

  MaterialReceipt resolve(MaterialReceipt receipt, DateTime end) {
    final dates = _dates.putIfAbsent(receipt, () {
      return {
        if (dataSource != FormulationDataSource.nir)
          for (final history in receipt.labHistory.values)
            for (final observation in history) observation.at,
      }.toList()..sort();
    });
    var low = 0;
    var high = dates.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (dates[middle].isAfter(end)) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    return _resolved
        .putIfAbsent(receipt, () => {})
        .putIfAbsent(low, () => receipt.at(end, dataSource: dataSource));
  }
}

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
    FormulationDataSource dataSource = FormulationDataSource.all,
    FormulationReceiptIndex? prepared,
  }) {
    final start = DateTime(from.year, from.month, from.day);
    final end = DateTime(to.year, to.month, to.day, 23, 59, 59, 999);
    final ids = materialIds.toSet();
    final index =
        prepared ??
        FormulationReceiptIndex(
          receipts: receipts,
          materialIds: ids,
          dataSource: dataSource,
        );
    if (!identical(index.receipts, receipts) ||
        index.dataSource != dataSource ||
        index.materialIds.length != ids.length ||
        !index.materialIds.containsAll(ids)) {
      throw ArgumentError('Receipt index does not match the calculation');
    }
    final availableKeys = index.availableKeys;
    final out = <int, Map<String, ParameterAverage>>{};
    for (final id in ids) {
      final originals = index.byMaterial[id] ?? const <MaterialReceipt>[];
      final rows = originals.map((e) => index.resolve(e, end)).toList();
      final keys = <String>{
        ...availableKeys,
        for (final row in rows) ...row.values.keys,
        for (final row in originals) ...row.values.keys,
        for (final row in originals) ...row.inspectionValues.keys,
        for (final row in originals) ...row.labHistory.keys,
      };
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
            FormulationAggregation.mode => _modeReceipt(current, key),
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
        final previous = <MaterialReceipt>[];
        for (var i = 0; i < originals.length; i++) {
          if (originals[i].receivedAt.isAfter(end)) continue;
          var resolved = rows[i];
          if (resolved.values[key] == null) {
            // A newer missing lab number must not hide an older valid one.
            final dates =
                (originals[i].labHistory[key] ?? const [])
                    .where((o) => o.value != null && !o.at.isAfter(end))
                    .map((o) => o.at)
                    .toSet()
                    .toList()
                  ..sort((a, b) => b.compareTo(a));
            for (final date in dates) {
              final candidate = index.resolve(originals[i], date);
              if (candidate.values[key] != null) {
                resolved = candidate;
                break;
              }
            }
          }
          if (resolved.values[key] != null) previous.add(resolved);
        }
        previous.sort(
          (a, b) => (b.parameterDates[key] ?? b.receivedAt).compareTo(
            a.parameterDates[key] ?? a.receivedAt,
          ),
        );
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
            FormulationAggregation.mode => _modeReceipt(previous, key),
          };
          values[key] = ParameterAverage(
            value: row.values[key],
            source: row.sources[key] ?? row.source,
            receipts: aggregation == FormulationAggregation.mode
                ? previous.length
                : 1,
            receiptCode: row.code,
            receiptDate: row.parameterDates[key] ?? row.receivedAt,
            usedFallback: true,
          );
          continue;
        }
        // Previous data always wins, even if a later value is closer. Only
        // when this material/parameter has no usable past do we look ahead.
        MaterialReceipt? next;
        DateTime? nextAvailable;
        for (final original in originals) {
          final dates = <DateTime>{
            if (original.receivedAt.isAfter(end)) original.receivedAt,
            for (final observation in original.labHistory[key] ?? const [])
              if (observation.at.isAfter(end) && observation.value != null)
                observation.at.isBefore(original.receivedAt)
                    ? original.receivedAt
                    : observation.at,
          }.toList()..sort();
          for (final date in dates) {
            final candidate = index.resolve(original, date);
            if (candidate.values[key] == null) continue;
            if (nextAvailable == null ||
                date.isBefore(nextAvailable) ||
                (date.isAtSameMomentAs(nextAvailable) &&
                    original.code.compareTo(next!.code) < 0)) {
              next = candidate;
              nextAvailable = date;
            }
            break;
          }
        }
        if (next != null) {
          values[key] = ParameterAverage(
            value: next.values[key],
            source: next.sources[key] ?? next.source,
            receipts: 1,
            receiptCode: next.code,
            receiptDate: next.parameterDates[key] ?? next.receivedAt,
            usedFallback: true,
            usedFutureFallback: true,
          );
        } else {
          // No usable value for this material/parameter exists in the chosen
          // source, before or after this period. Its blend contribution is zero;
          // keep the full formulation weight in the denominator.
          values[key] = ParameterAverage(
            value: 0,
            source: 'missing',
            receipts: 0,
            receiptCode: '',
            receiptDate: end,
            usedFallback: false,
          );
        }
      }
      out[id] = values;
    }
    return out;
  }

  /// Most frequent observed value, with the greater value winning a tie.
  /// Provenance comes from its latest matching receipt.
  static MaterialReceipt _modeReceipt(List<MaterialReceipt> rows, String key) {
    final counts = <double, int>{};
    for (final row in rows) {
      final value = row.values[key]!;
      counts[value] = (counts[value] ?? 0) + 1;
    }
    final mode = counts.keys.reduce(
      (a, b) =>
          counts[a]! > counts[b]! || (counts[a] == counts[b] && a > b) ? a : b,
    );
    return rows
        .where((row) => row.values[key] == mode)
        .reduce((a, b) => a.receivedAt.isAfter(b.receivedAt) ? a : b);
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
