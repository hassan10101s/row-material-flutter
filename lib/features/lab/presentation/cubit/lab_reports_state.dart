import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class LabReportsState extends Equatable {
  final String busy;
  final String? error;
  final String? lastExport;

  const LabReportsState({
    this.busy = '',
    this.error,
    this.lastExport,
  });

  LabReportsState copyWith({
    String? busy,
    String? error,
    String? lastExport,
  }) =>
      LabReportsState(
        busy: busy ?? this.busy,
        error: error ?? this.error,
        lastExport: lastExport ?? this.lastExport,
      );

  @override
  List<Object?> get props => [busy, error, lastExport];
}