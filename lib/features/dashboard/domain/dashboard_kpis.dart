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
  });

  final VolumeKpis volume;
  final QualityKpis quality;
  final LabKpis lab;
  final QcCheckKpis qc;
  final NcrKpisSummary ncr;
  final SopGoalKpis sopGoals;
  final InventoryKpis inventory;
  final List<TrendPoint> trend;

  @override
  List<Object?> get props =>
      [volume, quality, lab, qc, ncr, sopGoals, inventory, trend];
}
