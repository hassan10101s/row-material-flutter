import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

/// KPI card state for the dashboard hero/KPI cluster.
///
/// Each value mirrors the exact `?? 0` defaults the KPI tuple list already
/// applies, so an empty state (initial / reset) renders zeroed cards.
@immutable
class DashboardKpisState extends Equatable {
  final int todayInspections;
  final int todayApproved;
  final int todayRejected;
  final int totalCount;

  const DashboardKpisState({
    this.todayInspections = 0,
    this.todayApproved = 0,
    this.todayRejected = 0,
    this.totalCount = 0,
  });

  DashboardKpisState copyWith({
    int? todayInspections,
    int? todayApproved,
    int? todayRejected,
    int? totalCount,
  }) =>
      DashboardKpisState(
        todayInspections: todayInspections ?? this.todayInspections,
        todayApproved: todayApproved ?? this.todayApproved,
        todayRejected: todayRejected ?? this.todayRejected,
        totalCount: totalCount ?? this.totalCount,
      );

  @override
  List<Object?> get props => [
        todayInspections,
        todayApproved,
        todayRejected,
        totalCount,
      ];
}
