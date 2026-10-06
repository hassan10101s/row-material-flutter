import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

import '../../domain/dashboard_kpis.dart';

/// KPI card state for the dashboard hero/KPI cluster.
///
/// Each value mirrors the exact `?? 0` defaults the KPI tuple list already
/// applies, so an empty state (initial / reset) renders zeroed cards.
/// The cross-module [bundle] carries the senior-analyst KPIs (volume,
/// quality, lab, QC checks, NCR/CAPA, SOP/goals, inventory, trend) while the
/// four legacy scalars stay for backward compatibility.
@immutable
class DashboardKpisState extends Equatable {
  final int todayInspections;
  final int todayApproved;
  final int todayRejected;
  final int totalCount;
  final DashboardBundle bundle;

  const DashboardKpisState({
    this.todayInspections = 0,
    this.todayApproved = 0,
    this.todayRejected = 0,
    this.totalCount = 0,
    this.bundle = const DashboardBundle(),
  });

  DashboardKpisState copyWith({
    int? todayInspections,
    int? todayApproved,
    int? todayRejected,
    int? totalCount,
    DashboardBundle? bundle,
  }) =>
      DashboardKpisState(
        todayInspections: todayInspections ?? this.todayInspections,
        todayApproved: todayApproved ?? this.todayApproved,
        todayRejected: todayRejected ?? this.todayRejected,
        totalCount: totalCount ?? this.totalCount,
        bundle: bundle ?? this.bundle,
      );

  @override
  List<Object?> get props => [
        todayInspections,
        todayApproved,
        todayRejected,
        totalCount,
        bundle,
      ];
}
