import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

import '../../data/dashboard_repo.dart';

/// Dashboard analytics state: summary analytics, filter options and the active
/// filter values. The four KPI cards live in [DashboardKpisState].
@immutable
class DashboardState extends Equatable {
  final bool loading;
  final String? error;
  final Map<String, dynamic>? summary;
  final DashboardFilterOptions? filterOptions;
  final String period;
  final String selectedMaterial;
  final String selectedSupplier;
  final String selectedStatus;

  const DashboardState({
    this.loading = true,
    this.error,
    this.summary,
    this.filterOptions,
    this.period = '30d',
    this.selectedMaterial = 'ALL',
    this.selectedSupplier = 'ALL',
    this.selectedStatus = 'ALL',
  });

  DashboardState copyWith({
    bool? loading,
    String? error,
    Map<String, dynamic>? summary,
    DashboardFilterOptions? filterOptions,
    String? period,
    String? selectedMaterial,
    String? selectedSupplier,
    String? selectedStatus,
  }) =>
      DashboardState(
        loading: loading ?? this.loading,
        error: error ?? this.error,
        summary: summary ?? this.summary,
        filterOptions: filterOptions ?? this.filterOptions,
        period: period ?? this.period,
        selectedMaterial: selectedMaterial ?? this.selectedMaterial,
        selectedSupplier: selectedSupplier ?? this.selectedSupplier,
        selectedStatus: selectedStatus ?? this.selectedStatus,
      );

  @override
  List<Object?> get props => [
        loading,
        error,
        summary,
        filterOptions,
        period,
        selectedMaterial,
        selectedSupplier,
        selectedStatus,
      ];
}