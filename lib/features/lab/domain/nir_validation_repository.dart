/// NIR فلديشن (validation): models + repository contract.
///
/// Every analysis recorded on a محضر فحص (raw material inspection or product
/// batch report) is treated as a **NIR reading**; the paired laboratory
/// reference result (سجل الفحوصات, linked by entry code) is the benchmark for
/// the device. Per (material/product × parameter) the pairs yield the average
/// deviation, a proposed slope/intercept and accuracy metrics.
library;

import 'dart:convert';

/// The validation horizon: one row per reset (تصفير). The active horizon is
/// the newest row; history (previous zero points) is preserved.
///
/// A reset is either **global** (empty [scope] — the whole NIR calibration
/// restarts) or **per-item**, scoped to one parameter inside one
/// خامة/منتج ([scope] + [entityId]/[entityName] + [parameter]). A scoped
/// horizon only overrides the groups it targets; every other group keeps
/// counting (from its own or the global horizon).
class NirValidationSettings {
  final int id;
  final String startDate;
  final String resetNote;
  final String resetByName;
  final String createdAt;

  /// `''` (global), `'raw_material'` or `'product'`.
  final String scope;
  final int? entityId;

  /// Typed local projections of server-validated global parent references.
  /// [entityId] alone is legacy origin metadata and must never identify a row.
  final int? materialId;
  final int? productId;
  final int? referenceVersion;
  final NirCalibrationSnapshot? calibrationSnapshot;
  final String entityName;
  final String parameter;

  const NirValidationSettings({
    required this.id,
    required this.startDate,
    this.resetNote = '',
    this.resetByName = '',
    this.createdAt = '',
    this.scope = '',
    this.entityId,
    this.materialId,
    this.productId,
    this.referenceVersion,
    this.calibrationSnapshot,
    this.entityName = '',
    this.parameter = '',
  });

  factory NirValidationSettings.fromMap(Map<String, dynamic> m) =>
      NirValidationSettings(
        id: (m['id'] as num).toInt(),
        startDate: '${m['start_date'] ?? ''}',
        resetNote: '${m['reset_note'] ?? ''}',
        resetByName: '${m['reset_by_name'] ?? ''}',
        createdAt: '${m['created_at'] ?? ''}',
        scope: '${m['scope'] ?? ''}'.trim(),
        entityId: (m['entity_id'] as num?)?.toInt(),
        materialId: (m['material_id'] as num?)?.toInt(),
        productId: (m['product_id'] as num?)?.toInt(),
        referenceVersion: (m['reference_version'] as num?)?.toInt(),
        calibrationSnapshot: NirCalibrationSnapshot.decode(
          m['calibration_snapshot_json'],
        ),
        entityName: '${m['entity_name'] ?? ''}',
        parameter: '${m['parameter'] ?? ''}',
      );

  /// A whole-calibration reset (no scope); legacy rows are global.
  bool get isGlobal => scope.trim().isEmpty;

  NirScope? get scopeEnum => switch (scope.trim()) {
    'raw_material' => NirScope.rawMaterial,
    'product' => NirScope.product,
    _ => null,
  };

  /// Stored `scope` value for a [NirScope].
  static String scopeValue(NirScope scope) =>
      scope == NirScope.rawMaterial ? 'raw_material' : 'product';
}

/// Scope of a stats row: a raw-material inspection reading (خامة) or a
/// product batch reading (منتج).
enum NirScope { rawMaterial, product }

/// The calibration adjustment the operator chooses for an item: apply the
/// fitted slope only (raw device reading × a₀, line forced through the
/// origin — no offset) or the full linear correction (slope + intercept).
enum NirAdjustmentMode { slopeOnly, slopeAndIntercept }

/// A device adjustment explicitly reported by the operator, independently of
/// the software recommendation. It is never applied to stored measurements.
class NirAppliedCorrection {
  const NirAppliedCorrection({required this.slope, required this.intercept});
  final double slope;
  final double intercept;
  Map<String, Object?> toMap() => {'slope': slope, 'intercept': intercept};
}

/// Immutable evidence captured while preparing the reset request. Legacy
/// resets have no snapshot; their historical statistics must not be invented
/// by recalculating today's mutable source rows.
class NirCalibrationSnapshot {
  const NirCalibrationSnapshot({
    required this.capturedAt,
    required this.summaries,
    this.appliedCorrection,
  });
  final String capturedAt;
  final List<Map<String, dynamic>> summaries;
  final NirAppliedCorrection? appliedCorrection;
  Map<String, Object?> toMap() => {
    'version': 1,
    'capturedAt': capturedAt,
    'referencePolicy': 'latest_valid_per_sample_parameter',
    'summaries': summaries,
    if (appliedCorrection != null)
      'appliedCorrection': appliedCorrection!.toMap(),
  };
  static NirCalibrationSnapshot? decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map ||
          data['version'] != 1 ||
          data['capturedAt'] is! String ||
          data['summaries'] is! List) {
        return null;
      }
      final applied = data['appliedCorrection'];
      return NirCalibrationSnapshot(
        capturedAt: data['capturedAt'] as String,
        summaries: List.unmodifiable(
          (data['summaries'] as List).whereType<Map>().map(
            (row) => Map<String, dynamic>.unmodifiable(
              Map<String, dynamic>.from(row),
            ),
          ),
        ),
        appliedCorrection:
            applied is Map &&
                applied['slope'] is num &&
                applied['intercept'] is num
            ? NirAppliedCorrection(
                slope: (applied['slope'] as num).toDouble(),
                intercept: (applied['intercept'] as num).toDouble(),
              )
            : null,
      );
    } on FormatException {
      return null;
    }
  }
}

/// One bilingual line of evidence behind [NirAdjustmentAdvice.recommended].
class NirAdviceReason {
  final String ar;
  final String en;

  const NirAdviceReason(this.ar, this.en);
}

/// The auto-recommendation ("deep thinking") between the two adjustment
/// modes. The decision weighs three signals: how far the slope sits from 1,
/// whether the intercept is statistically meaningful (|t| test against ~2)
/// and how much RMSE the intercept actually buys.
class NirAdjustmentAdvice {
  final NirAdjustmentMode recommended;
  final List<NirAdviceReason> reasons;

  /// |t| statistic of the full-fit intercept (≈0 → it cannot be tested).
  final double interceptT;

  const NirAdjustmentAdvice({
    required this.recommended,
    required this.reasons,
    required this.interceptT,
  });
}

/// One matched pair: a NIR value read on a محضر against the laboratory
/// reference value for the same محضر/parameter/sample.
class NirValidationPoint {
  /// Selection is bound to a specific source reading and lab reference using
  /// global identities, never a device's SQLite row number.
  final String selectionKey;
  final int referenceId;
  final String referenceRemoteId;
  final int referenceVersion;
  final bool included;
  final int inspectionId;
  final String entryCode;
  final String inspectionDate;
  final String sampleName;
  final double nirValue;
  final double labValue;

  const NirValidationPoint({
    this.selectionKey = '',
    this.referenceId = 0,
    this.referenceRemoteId = '',
    this.referenceVersion = 0,
    this.included = true,
    required this.inspectionId,
    required this.entryCode,
    required this.inspectionDate,
    required this.sampleName,
    required this.nirValue,
    required this.labValue,
  });

  /// NIR − reference (positive = the device reads high).
  double get deviation => nirValue - labValue;

  /// Relative deviation against the reference magnitude.
  double get relativeDeviation =>
      labValue.abs() < 1e-9 ? 0 : (nirValue - labValue) / labValue.abs();
}

/// Accuracy badge for a stats row.
enum NirReliability { trusted, needsReview, insufficientData }

/// Aggregated validation outcome for one (entity × parameter) combination.
class NirParameterStats {
  final NirScope scope;
  final int entityId;
  final String entityRemoteId;
  final String entityName;
  final String parameter;
  final String unit;

  /// The horizon that was applied to this row — its own scoped reset date, the
  /// global reset date, or `''` when nothing has been reset yet.
  final String horizonStart;

  /// True when [horizonStart] came from a per-item reset targeting exactly
  /// this (خامة/منتج × parameter) rather than the global horizon.
  final bool scopedHorizon;

  /// All pairs stay available for review and re-inclusion. Every calculation
  /// below uses only [points], so No cannot leak into any fitted metric.
  final List<NirValidationPoint> allPoints;
  List<NirValidationPoint> get points =>
      allPoints.where((point) => point.included).toList(growable: false);
  int get excludedCount => allPoints.length - count;

  const NirParameterStats({
    required this.scope,
    required this.entityId,
    this.entityRemoteId = '',
    required this.entityName,
    required this.parameter,
    required this.unit,
    required List<NirValidationPoint> points,
    this.horizonStart = '',
    this.scopedHorizon = false,
  }) : allPoints = points;

  int get count => points.length;

  double get meanNir => points.isEmpty
      ? 0
      : points.map((p) => p.nirValue).reduce((a, b) => a + b) / count;

  double get meanLab => points.isEmpty
      ? 0
      : points.map((p) => p.labValue).reduce((a, b) => a + b) / count;

  /// Average signed deviation (انحراف): mean(NIR − lab). Positive means the
  /// device reads high.
  double get bias => points.isEmpty
      ? 0
      : points.map((p) => p.deviation).reduce((a, b) => a + b) / count;

  /// Proposed slope (a) for `lab = a·nir + b` (least squares). Recalibrating
  /// a raw device reading x as `a·x + b` should land on the reference.
  double get slope {
    if (count < 2) return count == 1 ? 1 : 0;
    final mx = meanNir;
    final my = meanLab;
    final sx2 = points.fold<double>(
      0,
      (s, p) => s + (p.nirValue - mx) * (p.nirValue - mx),
    );
    if (sx2.abs() < 1e-12) return 1;
    double sxy = 0;
    for (final p in points) {
      sxy += (p.nirValue - mx) * (p.labValue - my);
    }
    return sxy / sx2;
  }

  /// Proposed intercept (b) of `lab = a·nir + b`.
  double get intercept => meanLab - slope * meanNir;

  /// Coefficient of determination of the fitted line.
  double get r2 {
    if (count < 2) return 0;
    final a = slope;
    final b = intercept;
    final my = meanLab;
    double ssRes = 0;
    double ssTot = 0;
    for (final p in points) {
      final fitted = a * p.nirValue + b;
      ssRes += (p.labValue - fitted) * (p.labValue - fitted);
      ssTot += (p.labValue - my) * (p.labValue - my);
    }
    if (ssTot.abs() < 1e-12) return 0;
    return 1 - ssRes / ssTot;
  }

  /// Root-mean-square error of the fitted line (SEP-like dispersion).
  double get rmse {
    if (count < 2) return 0;
    final a = slope;
    final b = intercept;
    double ssRes = 0;
    for (final p in points) {
      final fitted = a * p.nirValue + b;
      ssRes += (p.labValue - fitted) * (p.labValue - fitted);
    }
    return count == 0 ? 0 : _sqrt(ssRes / count);
  }

  static double _sqrt(double x) {
    if (x <= 0) return 0;
    var guess = x < 1 ? 1.0 : x;
    for (var i = 0; i < 40; i++) {
      final next = 0.5 * (guess + x / guess);
      if ((next - guess).abs() < 1e-12) return next;
      guess = next;
    }
    return guess;
  }

  /// Largest absolute single-pair deviation.
  double get maxDeviation =>
      points.map((p) => p.deviation.abs()).fold(0.0, (m, d) => d > m ? d : m);

  /// Trust badge: needs ≥5 points and R² ≥ 0.9 to be considered trusted.
  NirReliability get reliability {
    if (count < 5) return NirReliability.insufficientData;
    if (r2 >= 0.9) return NirReliability.trusted;
    return NirReliability.needsReview;
  }

  /// Slope of the through-origin fit `lab = a₀·nir` (least squares with the
  /// intercept forced to zero): a₀ = Σ(x·y) / Σ(x²). Valid from a single
  /// pair; degenerate (zero-variance) input falls back to 1.
  double get slopeOnly {
    if (count == 0) return 1;
    double sxy = 0;
    double sx2 = 0;
    for (final p in points) {
      sxy += p.nirValue * p.labValue;
      sx2 += p.nirValue * p.nirValue;
    }
    if (sx2.abs() < 1e-12) return 1;
    return sxy / sx2;
  }

  /// The lab-equivalent value of a raw NIR reading under [mode].
  double adjustedOf(NirValidationPoint p, NirAdjustmentMode mode) =>
      mode == NirAdjustmentMode.slopeOnly
      ? slopeOnly * p.nirValue
      : slope * p.nirValue + intercept;

  /// Mean residual (bias) after applying [mode] to the raw readings.
  double biasOf(NirAdjustmentMode mode) {
    if (count == 0) return 0;
    var sum = 0.0;
    for (final p in points) {
      sum += p.labValue - adjustedOf(p, mode);
    }
    return sum / count;
  }

  /// RMSE of [mode] applied to the raw readings.
  double rmseOf(NirAdjustmentMode mode) {
    if (count < 2) return 0;
    double ssRes = 0;
    for (final p in points) {
      final r = p.labValue - adjustedOf(p, mode);
      ssRes += r * r;
    }
    return _sqrt(ssRes / count);
  }

  /// R² of [mode] — 1 − SSres/SStot around the lab mean.
  double r2Of(NirAdjustmentMode mode) {
    if (count < 2) return 0;
    final my = meanLab;
    double ssRes = 0;
    double ssTot = 0;
    for (final p in points) {
      final fitted = adjustedOf(p, mode);
      ssRes += (p.labValue - fitted) * (p.labValue - fitted);
      ssTot += (p.labValue - my) * (p.labValue - my);
    }
    if (ssTot.abs() < 1e-12) return 0;
    return 1 - ssRes / ssTot;
  }

  /// |t| statistic of the full-fit intercept: |b| / SE(b) where
  /// SE² = σ̂res² · (1/n + x̄²/Σ(x−x̄)²). |t| ≥ 2 ≈ p < 0.05 — the intercept
  /// is a real offset, not noise. Untestable below 3 points (returns 0).
  double get interceptTestT {
    if (count < 3) return 0;
    final mx = meanNir;
    double sx2 = 0;
    for (final p in points) {
      sx2 += (p.nirValue - mx) * (p.nirValue - mx);
    }
    if (sx2.abs() < 1e-12) return 0;
    final a = slope;
    final b = intercept;
    double ssRes = 0;
    for (final p in points) {
      final r = p.labValue - (a * p.nirValue + b);
      ssRes += r * r;
    }
    final sigma2 = ssRes / (count - 2);
    final se = _sqrt(sigma2 * (1 / count + mx * mx / sx2));
    if (se.abs() < 1e-12) {
      // Degenerate case: the full fit has zero residual variance, so SE(b)
      // vanishes too. A non-zero intercept under a perfect fit is still
      // exactly determined — treat it as maximally significant (capped for
      // display); a zero intercept needs no correction at all.
      return b.abs() < 1e-9 ? 0 : 99;
    }
    return b.abs() / se;
  }

  /// The recommendation with its evidence: significant intercept (|t| ≥ 2)
  /// **and** a real RMSE gain (≥2%) → slope + intercept; otherwise slope
  /// only (a zero-ish or noisy intercept adds complexity without benefit).
  NirAdjustmentAdvice get adjustmentAdvice {
    final t = interceptTestT.abs();
    final rFull = rmseOf(NirAdjustmentMode.slopeAndIntercept);
    final rOnly = rmseOf(NirAdjustmentMode.slopeOnly);
    final gain = rOnly.abs() < 1e-12 ? 0.0 : (rOnly - rFull) / rOnly.abs();
    final reasons = <NirAdviceReason>[];

    if (count < 3) {
      reasons.add(
        NirAdviceReason(
          'نقاط غير كافية ($count) لاختبار معنوية القاطع — يفضَّل الميل + القاطع مؤقتاً مع جمع نقاط أكثر',
          'Not enough points ($count) to test intercept significance — slope + intercept preferred for now, collect more pairs',
        ),
      );
      return NirAdjustmentAdvice(
        recommended: NirAdjustmentMode.slopeAndIntercept,
        reasons: reasons,
        interceptT: t,
      );
    }

    final a = slope;
    if ((a - 1).abs() <= 0.02) {
      reasons.add(
        NirAdviceReason(
          'الميل قريب من 1 (${a.toStringAsFixed(3)}) — مقياس الجهاز متوافق مع المعمل',
          'Slope close to 1 (${a.toStringAsFixed(3)}) — device scale matches the lab',
        ),
      );
    } else {
      final pct = ((a - 1).abs() * 100).toStringAsFixed(1);
      reasons.add(
        NirAdviceReason(
          'الميل = ${a.toStringAsFixed(3)} — الجهاز يقرأ ${a > 1 ? 'أقل' : 'أعلى'} من المعمل بنحو $pct%، فيلزم تصحيح الميل',
          'Slope = ${a.toStringAsFixed(3)} — the device reads about ${a > 1 ? 'lower' : 'higher'} than the lab by ~$pct%, slope correction is needed',
        ),
      );
    }

    final significant = t >= 2;
    if (significant) {
      reasons.add(
        NirAdviceReason(
          'القاطع (${intercept.toStringAsFixed(3)}) معنوي إحصائياً (t = ${t.toStringAsFixed(2)} ≥ 2) — تجاهله يترك انزياحاً ثابتاً غير مصحح',
          'Intercept (${intercept.toStringAsFixed(3)}) is statistically significant (t = ${t.toStringAsFixed(2)} ≥ 2) — ignoring it leaves an uncorrected constant offset',
        ),
      );
    } else {
      reasons.add(
        NirAdviceReason(
          'القاطع غير معنوي إحصائياً (t = ${t.toStringAsFixed(2)} < 2) — يطمس في ضجيج النقاط، ويكفي الميل لوحده',
          'Intercept is not statistically significant (t = ${t.toStringAsFixed(2)} < 2) — it drowns in the points noise; slope alone suffices',
        ),
      );
    }

    reasons.add(
      NirAdviceReason(
        'إضافة القاطع تخفض RMSE من ${rOnly.toStringAsFixed(3)} إلى ${rFull.toStringAsFixed(3)} (${(gain * 100).toStringAsFixed(1)}%)',
        'Adding the intercept lowers RMSE from ${rOnly.toStringAsFixed(3)} to ${rFull.toStringAsFixed(3)} (${(gain * 100).toStringAsFixed(1)}%)',
      ),
    );
    if (significant && gain < 0.02) {
      reasons.add(
        NirAdviceReason(
          'التحسن أقل من 2% — القاطع يضيف تعقيداً بلا فائدة عملية على هذه النقاط',
          'The gain is under 2% — the intercept adds complexity with little practical benefit on these points',
        ),
      );
    }

    return NirAdjustmentAdvice(
      recommended: significant && gain >= 0.02
          ? NirAdjustmentMode.slopeAndIntercept
          : NirAdjustmentMode.slopeOnly,
      reasons: reasons,
      interceptT: t,
    );
  }
}

/// The full computation result: horizon + stats sorted by entity/parameter.
class NirValidationReport {
  final NirValidationSettings? settings;
  final List<NirParameterStats> stats;

  const NirValidationReport({required this.settings, required this.stats});
}

/// Contract for reading + resetting the validation horizon and computing the
/// NIR vs laboratory-reference validation report.
abstract interface class NirValidationRepository {
  /// Explicit, server-confirmed change to calibration-only metadata. Source
  /// measurements and other pairs sharing the reference are preserved.
  Future<void> setPointIncluded(NirValidationPoint point, bool included);

  /// The active **global** validation horizon (newest unscoped reset), or null
  /// when no whole-calibration reset has been recorded yet — in that case every
  /// recorded pair is considered unless a per-item horizon overrides it.
  Future<NirValidationSettings?> getSettings();

  /// Records a new horizon: from [startDate] ISO (`yyyy-MM-dd`) a fresh count
  /// begins; previous resets stay in history.
  ///
  /// Pass [scope] (+ [entityId]/[entityName] and [parameter]) to reset a single
  /// item inside one خامة/منتج — the horizon then applies only to that group.
  /// Leave [scope] null for a whole-calibration reset (legacy behaviour).
  Future<NirValidationSettings> resetValidation(
    String startDate, {
    String note = '',
    NirScope? scope,
    int? entityId,
    String entityName = '',
    String parameter = '',
    NirAppliedCorrection? appliedCorrection,
  });

  /// Lists the reset history (newest first), both global and per-item.
  Future<List<NirValidationSettings>> listResetHistory({int limit = 50});

  /// Builds the validation report. Each (خامة/منتج × parameter) group counts
  /// only محاضر on or after its effective horizon: its own per-item reset when
  /// one exists, otherwise the global horizon.
  Future<NirValidationReport> compute({String? startDate});
}
