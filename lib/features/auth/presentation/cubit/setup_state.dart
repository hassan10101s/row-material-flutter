import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

/// First-run setup form state: submission busy flag and error message.
@immutable
class SetupState extends Equatable {
  final bool busy;
  final String? error;

  const SetupState({this.busy = false, this.error});

  SetupState copyWith({bool? busy, String? error}) => SetupState(
        busy: busy ?? this.busy,
        error: error ?? this.error,
      );

  @override
  List<Object?> get props => [busy, error];
}