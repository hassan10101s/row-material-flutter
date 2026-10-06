import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../domain/settings_repository.dart';
import 'general_settings_state.dart';

/// Loads/saves the department label shown on reports (General panel).
class GeneralSettingsCubit extends AppCubit<GeneralSettingsState> {
  GeneralSettingsCubit({required this.repo})
    : super(const GeneralSettingsState());

  final SettingsRepository repo;

  Future<void> load() async {
    safeEmit(state.copyWith(loading: true));
    try {
      final label = await repo.getSettingValue('department_label');
      final logoPath = await repo.getReportLogoPath();
      final logoDataUri = await repo.getReportLogoDataUri();
      final exportRootPath = await repo.getSettingValue('export_root_path');
      safeEmit(
        state.copyWith(
          loading: false,
          departmentLabel: label?.trim().isNotEmpty == true
              ? label!
              : 'Quality Assurance Department',
          logoPath: logoPath ?? '',
          logoDataUri: logoDataUri ?? '',
          exportRootPath: exportRootPath?.trim() ?? '',
        ),
      );
    } catch (e) {
      safeEmit(
        state.copyWith(
          loading: false,
          departmentLabel: 'Quality Assurance Department',
        ),
      );
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

  Future<void> saveLogo({required String path, required String dataUri}) async {
    safeEmit(state.copyWith(saving: true));
    try {
      await repo.setReportLogo(path, dataUri);
      safeEmit(
        state.copyWith(saving: false, logoPath: path, logoDataUri: dataUri),
      );
    } on AppError {
      safeEmit(state.copyWith(saving: false));
      rethrow;
    } catch (_) {
      safeEmit(state.copyWith(saving: false));
      rethrow;
    }
  }

  Future<void> clearLogo() async {
    safeEmit(state.copyWith(saving: true));
    try {
      await repo.clearReportLogo();
      safeEmit(state.copyWith(saving: false, logoPath: '', logoDataUri: ''));
    } on AppError {
      safeEmit(state.copyWith(saving: false));
      rethrow;
    } catch (_) {
      safeEmit(state.copyWith(saving: false));
      rethrow;
    }
  }

  /// Save the export root folder for report PDFs; an empty string makes the
  /// reports use the app's default exports folder again.
  Future<void> saveExportRootPath(String path) async {
    safeEmit(state.copyWith(saving: true));
    try {
      await repo.updateSettings({'export_root_path': path.trim()});
      safeEmit(state.copyWith(saving: false, exportRootPath: path.trim()));
    } on AppError {
      safeEmit(state.copyWith(saving: false));
      rethrow;
    } catch (_) {
      safeEmit(state.copyWith(saving: false));
      rethrow;
    }
  }
}
