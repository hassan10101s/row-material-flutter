import '../../../../app/auth_gate.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/auth_repo.dart';
import 'login_state.dart';

/// Authenticates a user against [auth] and notifies [gate] on success so the
/// router can re-evaluate its guards.
class LoginCubit extends AppCubit<LoginState> {
  LoginCubit({required this.auth, required this.gate}) : super(const LoginState());

  final AuthRepo auth;
  final AuthGate gate;

  /// Returns `true` when login succeeded (caller navigates to the dashboard).
  Future<bool> submit({required String username, required String password}) async {
    safeEmit(state.copyWith(busy: true, error: null));
    try {
      await auth.login(username: username, password: password);
      gate.updated();
      return true;
    } on AppError catch (e) {
      safeEmit(state.copyWith(error: e.message));
      return false;
    } catch (e) {
      safeEmit(state.copyWith(error: '$e'));
      return false;
    } finally {
      safeEmit(state.copyWith(busy: false));
    }
  }
}