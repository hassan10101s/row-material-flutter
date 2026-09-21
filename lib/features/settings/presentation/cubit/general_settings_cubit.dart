import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../data/settings_repo.dart';
import 'general_settings_state.dart';

/// Loads/saves the department label shown on reports (General panel).
class GeneralSettingsCubit extends AppCubit<GeneralSettingsState> {
  GeneralSettingsCubit({required this.repo}) : super(const GeneralSettingsState());

  final SettingsRepo repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true));
    try {
      final label = await repo.getSettingValue('department_label');
      safeEmit(state.copyWith(
        loading: false,
        departmentLabel: label?.trim().isNotEmpty == true
            ? label!
            : 'Quality Assurance Department',
      ));
    } catch (e) {
      safeEmit(state.copyWith(
        loading: false,
        departmentLabel: 'Quality Assurance Department',
      ));
    }
  }

  Future<void> save(String departmentLabel) async {
    safeEmit(state.copyWith(saving: true));
    try {
      await repo.updateSettings({'department_label': departmentLabel});
      safeEmit(state.copyWith(saving: false, departmentLabel: departmentLabel));
    } on AppError {
      safeEmit(state.copyWith(saving: false));
      rethrow;
    } catch (_) {
      safeEmit(state.copyWith(saving: false));
      rethrow;
    }
  }
}