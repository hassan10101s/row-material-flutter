import '../../../../core/state/app_cubit.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../backup/data/backup_manager.dart';
import 'database_settings_state.dart';

/// Database backup/export/restore actions (Database panel).
class DatabaseSettingsCubit extends AppCubit<DatabaseSettingsState> {
  DatabaseSettingsCubit({required this.backup}) : super(const DatabaseSettingsState());

  final BackupManager backup;

  Future<void> exportBackup() async {
    safeEmit(state.copyWith(busy: true, error: null, lastPath: null));
    try {
      final result = await backup.exportDatabaseBackup();
      safeEmit(state.copyWith(busy: false, lastPath: result['path'] as String? ?? ''));
    } on AppError catch (e) {
      safeEmit(state.copyWith(busy: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(busy: false, error: '$e'));
    }
  }

  Future<void> restoreBackup(String path) async {
    safeEmit(state.copyWith(busy: true, error: null));
    try {
      await backup.restoreDatabaseBackup(path);
      safeEmit(state.copyWith(busy: false));
    } on AppError catch (e) {
      safeEmit(state.copyWith(busy: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(busy: false, error: '$e'));
    }
  }
}