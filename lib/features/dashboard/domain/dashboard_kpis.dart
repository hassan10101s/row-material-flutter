import 'package:equatable/equatable.dart';

/// Typed KPI bundle for the dashboard (senior-analyst upgrade).
///
/// Every field defaults to zero so an empty database renders "0" cards rather
/// than nulls. Rates are 1-decimal doubles to match `aggregation.dart`.
class VolumeKpis extends Equatable {
  const VolumeKpis({
    this.today = 0,
    this.todayApproved = 0,
    this.todayRejected = 0,
    this.total = 0,
    this.pending = 0,
    this.openFollowUps = 0,
    this.weekAvg = 0.0,
  });

  final int today;
  final int todayApproved;
  final int todayRejected;
  final int total;
  final int pending;
  final int openFollowUps;
  final double weekAvg;

  double get vsWeekAvg => today - weekAvg;

  @override
  List<Object?> get props =>
      [today, todayApproved, todayRejected, total, pending, openFollowUps, weekAvg];
}

class QualityKpis extends Equatable {
  const QualityKpis({
    this.total = 0,
    this.approved = 0,
    this.conditional = 0,
    this.partial = 0,
    this.rejected = 0,
    this.acceptanceRate = 0.0,
    this.strictRate = 0.0,
    this.conditionalShare = 0.0,
    this.partialRate = 0.0,
    this.fullRate = 0.0,
    this.rejectionRate = 0.0,
    this.totalQty = 0.0,
    this.rejectedQty = 0.0,
    this.rejectedQtyRatio = 0.0,
    this.avgRejectedPerPartial = 0.0,
    this.churnAvg = 0.0,
    this.reopened = 0,
    this.expiryRisk = 0,
    this.expired = 0,
  });

  final int total;
  final int approved;
  final int conditional;
  final int partial;
  final int rejected;
  final double acceptanceRate;
  final double strictRate;
  final double conditionalShare;
  final double partialRate;
  final double fullRate;
  final double rejectionRate;
  final double totalQty;
  final double rejectedQty;
  final double rejectedQtyRatio;
  final double avgRejectedPerPartial;
  final double churnAvg;
  final int reopened;
  final int expiryRisk;
  final int expired;

  @override
  List<Object?> get props => [
        total, approved, conditional, partial, rejected, acceptanceRate,
        strictRate, conditionalShare, partialRate, fullRate, rejectionRate,
        totalQty, rejectedQty, rejectedQtyRatio, avgRejectedPerPartial,
        churnAvg, reopened, expiryRisk, expired,
      ];
}

class LabKpis extends Equatable {
  const LabKpis({
    this.totalTests = 0,
    this.evaluated = 0,
    this.inRange = 0,
    this.outOfRange = 0,
    this.passRate = 0.0,
    this.lowStockCount = 0,
  });

  final int totalTests;
  final int evaluated;
  final int inRange;
  final int outOfRange;
  final double passRate;
  final int lowStockCount;

  @override
  List<Object?> get props =>
      [totalTests, evaluated, inRange, outOfRange, passRate, lowStockCount];
}

class QcCheckKpis extends Equatable {
  const QcCheckKpis({
    this.total = 0,
    this.pass = 0,
    this.conditional = 0,
    this.fail = 0,
    this.pending = 0,
    this.avgScore = 0.0,
    this.hasNc = 0,
    this.ncRate = 0.0,
    this.critical = 0,
    this.major = 0,
    this.minor = 0,
  });

  final int total;
  final int pass;
  final int conditional;
  final int fail;
  final int pending;
  final double avgScore;
  final int hasNc;
  final double ncRate;
  final int critical;
  final int major;
  final int minor;

  @override
  List<Object?> get props => [
        total, pass, conditional, fail, pending, avgScore, hasNc, ncRate,
        critical, major, minor,
      ];
}

class NcrKpisSummary extends Equatable {
  const NcrKpisSummary({
    this.total = 0,
    this.open = 0,
    this.overdue = 0,
    this.overduePct = 0.0,
    this.critical = 0,
    this.major = 0,
    this.minor = 0,
    this.closed = 0,
    this.closedOnTime = 0,
    this.onTimePct,
    this.mttcDays,
    this.mttvDays,
    this.capaLinked = 0,
    this.capaCoveragePct = 0.0,
    this.capaOverdue = 0,
    this.aging = const [0, 0, 0, 0, 0],
    this.topDefects = const [],
  });

  final int total;
  final int open;
  final int overdue;
  final double overduePct;
  final int critical;
  final int major;
  final int minor;
  final int closed;
  final int closedOnTime;
  final double? onTimePct;
  final double? mttcDays;
  final double? mttvDays;
  final int capaLinked;
  final double capaCoveragePct;
  final int capaOverdue;
  final List<int> aging;
  final List<Map<String, dynamic>> topDefects;

  @override
  List<Object?> get props => [
        total, open, overdue, overduePct, critical, major, minor, closed,
        closedOnTime, onTimePct, mttcDays, mttvDays, capaLinked,
        capaCoveragePct, capaOverdue, aging, topDefects,
      ];
}

class SopGoalKpis extends Equatable {
  const SopGoalKpis({
    this.sopTotal = 0,
    this.sopPublished = 0,
    this.sopExpired = 0,
    this.sopExpiring = 0,
    this.sopPending = 0,
    this.goalTotal = 0,
    this.goalActive = 0,
    this.goalOverdue = 0,
    this.goalCompleted = 0,
    this.goalAvgProgress = 0.0,
    this.goalKpiMetRate = 0.0,
    this.goalOverdueActions = 0,
  });

  final int sopTotal;
  final int sopPublished;
  final int sopExpired;
  final int sopExpiring;
  final int sopPending;
  final int goalTotal;
  final int goalActive;
  final int goalOverdue;
  final int goalCompleted;
  final double goalAvgProgress;
  final double goalKpiMetRate;
  final int goalOverdueActions;

  @override
  List<Object?> get props => [
        sopTotal, sopPublished, sopExpired, sopExpiring, sopPending, goalTotal,
        goalActive, goalOverdue, goalCompleted, goalAvgProgress, goalKpiMetRate,
        goalOverdueActions,
      ];
}

class InventoryKpis extends Equatable {
  const InventoryKpis({
    this.skus = 0,
    this.low = 0,
    this.empty = 0,
    this.ok = 0,
    this.lowItems = const [],
  });

  final int skus;
  final int low;
  final int empty;
  final int ok;
  final List<Map<String, dynamic>> lowItems;

  @override
  List<Object?> get props => [skus, low, empty, ok, lowItems];
}

class TrendPoint extends Equatable {
  const TrendPoint({
    required this.label,
    required this.total,
    required this.approvalRate,
    required this.passRate,
  });

  final String label;
  final int total;
  final double approvalRate;
  final double passRate;

  @override
  List<Object?> get props => [label, total, approvalRate, passRate];
}

/// Supplier scorecard row (data-scientist upgrade).
///
/// [tier] is A (>=90%), B (75–90%), C (60–75%), D (<60%) or '—' when
/// [total] is 0. [score] is a 0–100 composite: 70% approval + 30% volume
/// confidence, so a 1/1 supplier never outranks a 95/100 one.
class SupplierScore extends Equatable {
  const SupplierScore({
    required this.name,
    this.total = 0,
    this.approved = 0,
    this.conditional = 0,
    this.rejected = 0,
    this.approvalRate = 0.0,
    this.rejectedQtyRatio = 0.0,
    this.tier = '—',
    this.score = 0.0,
  });

  final String name;
  final int total;
  final int approved;
  final int conditional;
  final int rejected;
  final double approvalRate;
  final double rejectedQtyRatio;
  final String tier;
  final double score;

  @override
  List<Object?> get props => [
        name, total, approved, conditional, rejected, approvalRate,
        rejectedQtyRatio, tier, score,
      ];
}

/// Pareto entry: share of total rejections + running cumulative share.
///
/// Sorted descending by [count]. [cumulativePct] lets the UI draw the
/// 80/20 cutoff line without recomputing.
class ParetoEntry extends Equatable {
  const ParetoEntry({
    required this.label,
    this.count = 0,
    this.pct = 0.0,
    this.cumulativePct = 0.0,
  });

  final String label;
  final int count;
  final double pct;
  final double cumulativePct;

  @override
  List<Object?> get props => [label, count, pct, cumulativePct];
}

/// Forecast point: actual approval rate + 3-month moving average +
/// optional next-month linear forecast (only set on the last point).
class ForecastPoint extends Equatable {
  const ForecastPoint({
    required this.label,
    this.actual = 0.0,
    this.movingAvg,
    this.forecast,
    this.hasData = false,
  });

  final String label;
  final double actual;
  final double? movingAvg;
  final double? forecast;
  final bool hasData;

  @override
  List<Object?> get props => [label, actual, movingAvg, forecast, hasData];
}

/// Stability of monthly approval rates (SPC-lite).
///
/// Computed over months with data only. [volatility] is 'low' (stdDev ≤ 5),
/// 'medium' (≤ 12) or 'high' (> 12). Null [stdDev] means fewer than
/// 2 months of data — unknown, not zero.
class StabilityKpis extends Equatable {
  const StabilityKpis({
    this.stdDev,
    this.range = 0.0,
    this.minRate = 0.0,
    this.maxRate = 0.0,
    this.volatility = 'unknown',
    this.sampleN = 0,
  });

  final double? stdDev;
  final double range;
  final double minRate;
  final double maxRate;
  final String volatility;
  final int sampleN;

  @override
  List<Object?> get props =>
      [stdDev, range, minRate, maxRate, volatility, sampleN];
}

/// Data-completeness audit for the filtered inspection set.
///
/// Missing supplier/expiry and pending decisions silently bias every rate
/// on the dashboard, so they are surfaced as first-class KPIs.
class DataQualityKpis extends Equatable {
  const DataQualityKpis({
    this.total = 0,
    this.missingSupplier = 0,
    this.missingExpiry = 0,
    this.pending = 0,
    this.completenessPct = 100.0,
    this.pendingPct = 0.0,
  });

  final int total;
  final int missingSupplier;
  final int missingExpiry;
  final int pending;
  final double completenessPct;
  final double pendingPct;

  @override
  List<Object?> get props => [
        total, missingSupplier, missingExpiry, pending, completenessPct,
        pendingPct,
      ];
}

/// One-shot aggregate for the whole dashboard.
class DashboardBundle extends Equatable {
  const DashboardBundle({
    this.volume = const VolumeKpis(),
    this.quality = const QualityKpis(),
    this.lab = const LabKpis(),
    this.qc = const QcCheckKpis(),
    this.ncr = const NcrKpisSummary(),
    this.sopGoals = const SopGoalKpis(),
    this.inventory = const InventoryKpis(),
    this.trend = const [],
    this.supplierScores = const [],
    this.materialPareto = const [],
    this.supplierPareto = const [],
    this.forecast = const [],
    this.stability = const StabilityKpis(),
    this.dataQuality = const DataQualityKpis(),
  });

  final VolumeKpis volume;
  final QualityKpis quality;
  final LabKpis lab;
  final QcCheckKpis qc;
  final NcrKpisSummary ncr;
  final SopGoalKpis sopGoals;
  final InventoryKpis inventory;
  final List<TrendPoint> trend;
  final List<SupplierScore> supplierScores;
  final List<ParetoEntry> materialPareto;
  final List<ParetoEntry> supplierPareto;
  final List<ForecastPoint> forecast;
  final StabilityKpis stability;
  final DataQualityKpis dataQuality;

  @override
  List<Object?> get props => [
        volume, quality, lab, qc, ncr, sopGoals, inventory, trend,
        supplierScores, materialPareto, supplierPareto, forecast,
        stability, dataQuality,
      ];
}
