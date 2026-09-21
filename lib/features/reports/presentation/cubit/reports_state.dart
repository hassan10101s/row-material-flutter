import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class ReportsState extends Equatable {
  final String busy;
  final String? error;
  final String? lastExport;
  final String? lastExportTitle;

  const ReportsState({
    this.busy = '',
    this.error,
    this.lastExport,
    this.lastExportTitle,
  });

  ReportsState copyWith({
    String? busy,
    String? error,
    String? lastExport,
    String? lastExportTitle,
  }) =>
      ReportsState(
        busy: busy ?? this.busy,
        error: error ?? this.error,
        lastExport: lastExport ?? this.lastExport,
        lastExportTitle: lastExportTitle ?? this.lastExportTitle,
      );

  @override
  List<Object?> get props => [busy, error, lastExport, lastExportTitle];
}