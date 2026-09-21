import '../../../../core/state/app_cubit.dart';
import '../../data/settings_repo.dart';
import 'users_state.dart';

/// User management (Users panel): load/create/delete accounts.
class UsersCubit extends AppCubit<UsersState> {
  UsersCubit({required this.repo}) : super(const UsersState());

  final SettingsRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true, error: null));
    try {
      final users = await repo.listUsers();
      safeEmit(state.copyWith(loading: false, users: users));
    } catch (e) {
      safeEmit(state.copyWith(loading: false, error: '$e'));
    }
  }

  Future<bool> createUser({
    required String username,
    required String fullName,
    required String password,
    required String role,
  }) async {
    safeEmit(state.copyWith(busy: true, error: null));
    try {
      await repo.createUser(
        username: username,
        fullName: fullName,
        password: password,
        role: role,
      );
      await load();
      safeEmit(state.copyWith(busy: false));
      return true;
    } catch (e) {
      safeEmit(state.copyWith(busy: false, error: '$e'));
      return false;
    }
  }

  Future<bool> deleteUser(int id) async {
    safeEmit(state.copyWith(busy: true, error: null));
    try {
      await repo.deleteUser(id);
      await load();
      safeEmit(state.copyWith(busy: false));
      return true;
    } catch (e) {
      safeEmit(state.copyWith(busy: false, error: '$e'));
      return false;
    }
  }
}