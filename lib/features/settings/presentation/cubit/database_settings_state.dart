import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;

@immutable
class DatabaseSettingsState extends Equatable {
  final bool busy;
  final String? error;
  final String? lastPath;

  const DatabaseSettingsState({this.busy = false, this.error, this.lastPath});

  DatabaseSettingsState copyWith({
    bool? busy,
    String? error,
    String? lastPath,
  }) =>
      DatabaseSettingsState(
        busy: busy ?? this.busy,
        error: error ?? this.error,
        lastPath: lastPath ?? this.lastPath,
      );

  @override
  List<Object?> get props => [busy, error, lastPath];
}