import '../../../../app/auth_gate.dart';
import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/auth_repo.dart';
import 'setup_state.dart';

/// Creates the first administrator and notifies [gate] on success so the
/// router redirects to the dashboard.
class SetupCubit extends AppCubit<SetupState> {
  SetupCubit({required this.auth, required this.gate}) : super(const SetupState());

  final AuthRepo auth;
  final AuthGate gate;

  /// Returns `true` when the admin was created (caller navigates).
  Future<bool> createAdmin({
    required String username,
    required String fullName,
    required String password,
    required String role,
    String? usageExpiryDate,
  }) async {
    safeEmit(state.copyWith(busy: true, error: null));
    try {
      await auth.createAdmin(
        username: username,
        fullName: fullName,
        password: password,
        role: role,
        usageExpiryDate: usageExpiryDate,
      );
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

  /// Surfaces a client-side validation error without a busy toggle.
  void fail(String message) => safeEmit(state.copyWith(error: message));
}