library;

/// Pure data-science helpers for the dashboard.
///
/// All functions are deterministic, side-effect free and null-safe:
/// empty inputs yield zeroed models, never NaN or throws. They operate on
/// plain Dart maps/lists so they are unit-testable without a database.
import 'dart:math' as math;

import 'dashboard_kpis.dart';

/// Rounds to 1 decimal (matches `aggregation.dart` / repo convention).
double round1(double v) => (v * 10).round() / 10.0;

double _num(Object? v) {
  if (v is num) return v.toDouble();
  return double.tryParse('$v') ?? 0.0;
}

/// Risk tier from strict approval rate.
String tierFor(double approvalRate, int total) {
  if (total <= 0) return '—';
  if (approvalRate >= 90) return 'A';
  if (approvalRate >= 75) return 'B';
  if (approvalRate >= 60) return 'C';
  return 'D';
}

/// Composite supplier score: 70% approval + 30% volume confidence.
///
/// Volume confidence is log-scaled so 1/1 never outranks 95/100:
/// `20 * ln(1 + total)`, capped at 30.
double compositeScore(double approvalRate, int total) {
  final vol = (20 * math.log(1 + total)).clamp(0.0, 30.0);
  return round1(approvalRate * 0.7 + vol);
}

/// Builds per-supplier scorecard rows from filtered inspection rows.
///
/// Expects rows with keys: `supplier`, `decision_status`, `quantity`,
/// `rejected_quantity`. Legacy `CONDITIONAL`/`PARTIAL` codes are folded.
List<SupplierScore> buildSupplierScores(List<Map<String, dynamic>> rows) {
  String norm(String? v) {
    switch (v) {
      case 'CONDITIONAL':
        return 'CONDITIONAL_APPROVAL';
      case 'PARTIAL':
        return 'PARTIAL_REJECTION';
      default:
        return v ?? '';
    }
  }

  final bySup = <String, _SupAcc>{};
  for (final r in rows) {
    var name = '${r['supplier'] ?? ''}'.trim();
    if (name.isEmpty) name = '—';
    final acc = bySup.putIfAbsent(name, () => _SupAcc());
    acc.total++;
    acc.qty += _num(r['quantity']);
    final s = norm('${r['decision_status'] ?? ''}');
    switch (s) {
      case 'APPROVED':
        acc.approved++;
        break;
      case 'CONDITIONAL_APPROVAL':
        acc.conditional++;
        break;
      case 'PARTIAL_REJECTION':
        acc.rejected++;
        acc.rejQty += _num(r['rejected_quantity']);
        break;
      case 'FULL_REJECTION':
        acc.rejected++;
        acc.rejQty += _num(r['quantity']);
        break;
      default:
        break;
    }
  }
  final out = <SupplierScore>[];
  for (final e in bySup.entries) {
    final a = e.value;
    final rate = a.total == 0 ? 0.0 : round1(a.approved / a.total * 100);
    final rejRatio =
        a.qty <= 0 ? 0.0 : round1(a.rejQty / a.qty * 100);
    out.add(SupplierScore(
      name: e.key,
      total: a.total,
      approved: a.approved,
      conditional: a.conditional,
      rejected: a.rejected,
      approvalRate: rate,
      rejectedQtyRatio: rejRatio,
      tier: tierFor(rate, a.total),
      score: compositeScore(rate, a.total),
    ));
  }
  // Rank: score desc, then volume desc — stable and explainable.
  out.sort((a, b) {
    final c = b.score.compareTo(a.score);
    if (c != 0) return c;
    return b.total.compareTo(a.total);
  });
  return out.length > 8 ? out.sublist(0, 8) : out;
}

class _SupAcc {
  int total = 0;
  int approved = 0;
  int conditional = 0;
  int rejected = 0;
  double qty = 0;
  double rejQty = 0;
}

/// Pareto of rejections by [keyOf] (e.g. material or supplier).
///
/// Only rows with PARTIAL/FULL rejection contribute. Returns entries
/// sorted desc with running cumulative share of total rejections.
List<ParetoEntry> buildPareto(
  List<Map<String, dynamic>> rows,
  String Function(Map<String, dynamic>) keyOf, {
  int limit = 6,
}) {
  String norm(String? v) {
    switch (v) {
      case 'PARTIAL':
        return 'PARTIAL_REJECTION';
      default:
        return v ?? '';
    }
  }

  final counts = <String, int>{};
  var totalRej = 0;
  for (final r in rows) {
    final s = norm('${r['decision_status'] ?? ''}');
    if (s == 'PARTIAL_REJECTION' || s == 'FULL_REJECTION') {
      totalRej++;
      final k = keyOf(r).trim().isEmpty ? '—' : keyOf(r).trim();
      counts[k] = (counts[k] ?? 0) + 1;
    }
  }
  if (totalRej == 0) return const [];
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final out = <ParetoEntry>[];
  var cum = 0;
  for (final e in sorted.take(limit)) {
    cum += e.value;
    out.add(ParetoEntry(
      label: e.key,
      count: e.value,
      pct: round1(e.value / totalRej * 100),
      cumulativePct: round1(cum / totalRej * 100),
    ));
  }
  return out;
}

/// 3-month moving average + next-month linear forecast.
///
/// [rates] are monthly approval rates, [labels] their display labels,
/// [hasData] marks months with inspections. Forecast uses ordinary least
/// squares over months with data (needs ≥2); result clamped to 0–100.
/// Returns one [ForecastPoint] per input month.
List<ForecastPoint> buildForecast({
  required List<String> labels,
  required List<double> rates,
  required List<bool> hasData,
}) {
  assert(labels.length == rates.length && rates.length == hasData.length);
  final n = rates.length;
  final ma = List<double?>.filled(n, null);
  for (var i = 0; i < n; i++) {
    if (!hasData[i]) continue;
    // Trailing 3-month window over months with data.
    final window = <double>[];
    for (var j = i; j >= 0 && window.length < 3; j--) {
      if (hasData[j]) window.add(rates[j]);
    }
    if (window.length == 3) {
      ma[i] = round1(window.reduce((a, b) => a + b) / 3);
    }
  }
  double? forecast;
  final xs = <double>[];
  final ys = <double>[];
  for (var i = 0; i < n; i++) {
    if (hasData[i]) {
      xs.add(i.toDouble());
      ys.add(rates[i]);
    }
  }
  if (xs.length >= 2) {
    final mx = xs.reduce((a, b) => a + b) / xs.length;
    final my = ys.reduce((a, b) => a + b) / ys.length;
    var denom = 0.0, numer = 0.0;
    for (var i = 0; i < xs.length; i++) {
      numer += (xs[i] - mx) * (ys[i] - my);
      denom += (xs[i] - mx) * (xs[i] - mx);
    }
    if (denom != 0) {
      final slope = numer / denom;
      final intercept = my - slope * mx;
      forecast = (intercept + slope * n).clamp(0.0, 100.0);
      forecast = round1(forecast);
    }
  }
  return [
    for (var i = 0; i < n; i++)
      ForecastPoint(
        label: labels[i],
        actual: round1(rates[i]),
        movingAvg: ma[i],
        forecast: i == n - 1 ? forecast : null,
        hasData: hasData[i],
      ),
  ];
}

/// Stability (mean-free): sample std-dev + range over months with data.
StabilityKpis buildStability(List<double> rates, List<bool> hasData) {
  final vals = <double>[];
  for (var i = 0; i < rates.length; i++) {
    if (i < hasData.length && hasData[i]) vals.add(rates[i]);
  }
  if (vals.length < 2) {
    return StabilityKpis(
      stdDev: null,
      volatility: 'unknown',
      sampleN: vals.length,
      minRate: vals.isEmpty ? 0.0 : round1(vals.first),
      maxRate: vals.isEmpty ? 0.0 : round1(vals.first),
    );
  }
  final mean = vals.reduce((a, b) => a + b) / vals.length;
  var sumSq = 0.0;
  for (final v in vals) {
    sumSq += (v - mean) * (v - mean);
  }
  final sd = math.sqrt(sumSq / (vals.length - 1));
  final mn = vals.reduce(math.min);
  final mx = vals.reduce(math.max);
  final sd1 = round1(sd);
  final volatility = sd1 <= 5
      ? 'low'
      : sd1 <= 12
          ? 'medium'
          : 'high';
  return StabilityKpis(
    stdDev: sd1,
    range: round1(mx - mn),
    minRate: round1(mn),
    maxRate: round1(mx),
    volatility: volatility,
    sampleN: vals.length,
  );
}

/// Data-completeness audit over filtered rows.
DataQualityKpis buildDataQuality(List<Map<String, dynamic>> rows) {
  var missingSup = 0, missingExp = 0, pending = 0;
  for (final r in rows) {
    final sup = '${r['supplier'] ?? ''}'.trim();
    if (sup.isEmpty) missingSup++;
    final exp = '${r['expiry_date'] ?? ''}'.trim();
    if (exp.isEmpty) missingExp++;
    final s = '${r['decision_status'] ?? ''}'.trim();
    if (s.isEmpty || s == 'PENDING' || s == 'UNKNOWN') pending++;
  }
  final n = rows.length;
  // Completeness = rows with supplier AND expiry AND decided.
  var complete = 0;
  for (final r in rows) {
    final sup = '${r['supplier'] ?? ''}'.trim().isNotEmpty;
    final exp = '${r['expiry_date'] ?? ''}'.trim().isNotEmpty;
    final s = '${r['decision_status'] ?? ''}'.trim();
    final decided = s.isNotEmpty && s != 'PENDING' && s != 'UNKNOWN';
    if (sup && exp && decided) complete++;
  }
  return DataQualityKpis(
    total: n,
    missingSupplier: missingSup,
    missingExpiry: missingExp,
    pending: pending,
    completenessPct: n == 0 ? 100.0 : round1(complete / n * 100),
    pendingPct: n == 0 ? 0.0 : round1(pending / n * 100),
  );
}

/// Executive narrative codes (UI renders bilingual text from these).
///
/// Returns a map with keys: `direction` (up/down/flat/none), `deltaPp`,
/// `topRiskSupplier`, `topRiskMaterial`, `concentrationPct`,
/// `confidence` (high/medium/low from data-quality + sample size).
Map<String, dynamic> buildExecutiveSignals({
  required List<TrendPoint> trend,
  required List<SupplierScore> suppliers,
  required List<ParetoEntry> materialPareto,
  required DataQualityKpis quality,
  required int totalInspections,
}) {
  final withData = trend.where((t) => t.total > 0).toList();
  String direction = 'none';
  double deltaPp = 0.0;
  if (withData.length >= 2) {
    final last = withData[withData.length - 1].approvalRate;
    final prev = withData[withData.length - 2].approvalRate;
    deltaPp = round1(last - prev);
    if (deltaPp > 0.5) {
      direction = 'up';
    } else if (deltaPp < -0.5) {
      direction = 'down';
    } else {
      direction = 'flat';
    }
  }
  String topRiskSupplier = '—';
  for (final s in suppliers.reversed) {
    // Lowest tier with volume ≥ 3 is the actionable risk.
    if (s.total >= 3 && (s.tier == 'D' || s.tier == 'C')) {
      topRiskSupplier = s.name;
      break;
    }
  }
  if (topRiskSupplier == '—' && suppliers.isNotEmpty) {
    topRiskSupplier = suppliers.last.name;
  }
  final topRiskMaterial =
      materialPareto.isEmpty ? '—' : materialPareto.first.label;
  final concentrationPct =
      materialPareto.isEmpty ? 0.0 : materialPareto.first.cumulativePct;
  String confidence = 'low';
  if (totalInspections >= 30 && quality.completenessPct >= 80) {
    confidence = 'high';
  } else if (totalInspections >= 10 && quality.completenessPct >= 60) {
    confidence = 'medium';
  }
  return {
    'direction': direction,
    'deltaPp': deltaPp,
    'topRiskSupplier': topRiskSupplier,
    'topRiskMaterial': topRiskMaterial,
    'concentrationPct': concentrationPct,
    'confidence': confidence,
  };
}
