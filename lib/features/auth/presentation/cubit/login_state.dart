import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

/// Login form state: submission busy flag and error message.
@immutable
class LoginState extends Equatable {
  final bool busy;
  final String? error;

  const LoginState({this.busy = false, this.error});

  LoginState copyWith({bool? busy, String? error}) => LoginState(
        busy: busy ?? this.busy,
        error: error ?? this.error,
      );

  @override
  List<Object?> get props => [busy, error];
}