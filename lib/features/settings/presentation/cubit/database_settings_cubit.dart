import '../../../../core/state/app_cubit.dart';
import '../../../../core/sync/sync_engine.dart';
import '../../../../core/utils/app_exceptions.dart';
import '../../../backup/domain/backup_service.dart';
import 'database_settings_state.dart';

/// Database backup/export/restore actions (Database panel).
class DatabaseSettingsCubit extends AppCubit<DatabaseSettingsState> {
  DatabaseSettingsCubit({required this.backup, this.engine})
    : super(const DatabaseSettingsState());

  final BackupService backup;

  /// Optional: after a restore the sync state has to be reconciled before the
  /// next cycle (plan §14-P11.2). Absent in tests and on a degraded bootstrap.
  final SyncEngine? engine;

  Future<void> exportBackup() async {
    safeEmit(state.copyWith(busy: true, error: null, lastPath: null));
    try {
      final result = await backup.exportDatabaseBackup();
      safeEmit(
        state.copyWith(busy: false, lastPath: result['path'] as String? ?? ''),
      );
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
      final report = await engine?.reconcileAfterRestore();
      // The restored file is the truth from now on: tell the user what had to
      // be flagged instead of letting a change vanish quietly.
      safeEmit(
        state.copyWith(
          busy: false,
          restored: true,
          restoreConflicts: report?.orphanedEntries ?? 0,
          restoreRequeued: report?.requeuedRows ?? 0,
        ),
      );
    } on AppError catch (e) {
      safeEmit(state.copyWith(busy: false, error: e.message));
    } catch (e) {
      safeEmit(state.copyWith(busy: false, error: '$e'));
    }
  }
}
