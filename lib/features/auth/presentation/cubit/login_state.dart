import 'package:flutter/foundation.dart' show immutable;
import 'package:equatable/equatable.dart';

/// The four display cases of the login screen (plan §8.1 / P2.4):
/// idle · signing-in · error · firebase-unavailable.
enum LoginStatus { idle, signingIn, firebaseUnavailable, error }

@immutable
class LoginState extends Equatable {
  const LoginState({
    this.status = LoginStatus.idle,
    this.error,
    this.missingConfiguration = const [],
  });

  final LoginStatus status;
  final String? error;

  /// Non-empty when Firebase could not be initialized (dart-define missing).
  final List<String> missingConfiguration;

  bool get busy => status == LoginStatus.signingIn;

  bool get needsConfiguration => status == LoginStatus.firebaseUnavailable;

  LoginState copyWith({
    LoginStatus? status,
    String? error,
    List<String>? missingConfiguration,
  }) =>
      LoginState(
        status: status ?? this.status,
        error: error,
        missingConfiguration: missingConfiguration ?? this.missingConfiguration,
      );

  @override
  List<Object?> get props => [status, error, missingConfiguration];
}
