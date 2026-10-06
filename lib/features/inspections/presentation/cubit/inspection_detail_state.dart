import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

/// Inspection detail state: the inspection record, its status history and the
/// currently-running export kind (`''` when idle).
@immutable
class InspectionDetailState extends Equatable {
  final Map<String, dynamic>? inspection;
  final List<Map<String, dynamic>> history;
  final List<Map<String, dynamic>> chemicalAnalyses;
  final bool loading;
  final String? error;
  final String busy;

  const InspectionDetailState({
    this.inspection,
    this.history = const [],
    this.chemicalAnalyses = const [],
    this.loading = true,
    this.error,
    this.busy = '',
  });

  InspectionDetailState copyWith({
    Map<String, dynamic>? inspection,
    List<Map<String, dynamic>>? history,
    List<Map<String, dynamic>>? chemicalAnalyses,
    bool? loading,
    String? error,
    String? busy,
  }) =>
      InspectionDetailState(
        inspection: inspection ?? this.inspection,
        history: history ?? this.history,
        chemicalAnalyses: chemicalAnalyses ?? this.chemicalAnalyses,
        loading: loading ?? this.loading,
        error: error ?? this.error,
        busy: busy ?? this.busy,
      );

  @override
  List<Object?> get props => [
    inspection,
    history,
    chemicalAnalyses,
    loading,
    error,
    busy,
  ];
}