import 'package:flutter/foundation.dart' show debugPrint;

import '../../../../app/auth_gate.dart';
import '../../../../core/constants/app_strings.dart';
import '../../../../core/state/app_cubit.dart';
import '../../domain/auth_repository.dart';
import 'login_state.dart';

/// Drives the single Google button. The router reacts to [AuthGate], so the
/// cubit only has to report failures (plan §8.1).
class LoginCubit extends AppCubit<LoginState> {
  LoginCubit({required this.auth, required this.gate}) : super(const LoginState());

  final AuthRepository auth;
  final AuthGate gate;

  /// Reflects an unconfigured Firebase into the UI instead of failing on tap.
  void applyBootstrap() {
    final missing = auth.missingConfiguration;
    if (missing.isEmpty) return;
    safeEmit(LoginState(
      status: LoginStatus.firebaseUnavailable,
      missingConfiguration: missing,
    ));
  }

  /// Returns `true` when the app reached [AuthState.ready].
  Future<bool> signIn() async {
    safeEmit(LoginState(status: LoginStatus.signingIn));
    try {
      await auth.signInWithGoogle();
      gate.updated();
      safeEmit(const LoginState());
      return auth.state == AuthState.ready;
    } on AuthFailure catch (e) {
      safeEmit(LoginState(
        status: e.isConfiguration ? LoginStatus.firebaseUnavailable : LoginStatus.error,
        error: e.message,
        missingConfiguration: e.isConfiguration ? auth.missingConfiguration : const [],
      ));
      return false;
    } catch (e) {
      debugPrint('[auth] unexpected sign-in error: $e');
      safeEmit(LoginState(
        status: LoginStatus.error,
        error: AppText.t(
          'حدث خطأ غير متوقع. حاول مرة أخرى.',
          'An unexpected error occurred. Please try again.',
        ),
      ));
      return false;
    }
  }
}
